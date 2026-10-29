# ClevoHelper.ps1 - G-Helper style control centre for Clevo X370SN
#
# MONITORING is read-only. MODE SWITCHING writes through the factory InsydeDCHU ->
# AcpiBridge (ACPI\CLV0001) channel - the same path Control Center uses. No kernel
# driver, no inpoutx64/NTPort/WinRing0, no admin required.
#
# Threading: one background runspace owns the DCHU device. It samples telemetry and
# executes queued write requests, so the UI thread never touches the hardware and the
# device is never accessed from two threads at once.
#
# Every write is: queue -> set -> read back -> verify -> report. The state present when
# the panel opened is remembered so the [恢复] button can put everything back.
#
# Run: powershell -STA -NoProfile -ExecutionPolicy Bypass -File ClevoHelper.ps1
#      -SelfTest  drives the mode buttons itself (queue -> write -> verify -> restore)
#                 and logs the outcome, so the UI wiring can be verified headlessly.

[CmdletBinding()]
param([switch]$SelfTest, [string]$HostExe, [switch]$StartHidden, [switch]$SizeProbe)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ------------------------------------------------- 任务栏图标 / 单实例 ------
# 1) AppUserModelID：面板跑在 powershell.exe 里，进程默认的 AUMID 是
#    Microsoft.Windows.PowerShell —— 于是**任务栏**按 PowerShell 的身份显示图标、并和其它
#    PowerShell 窗口分在一组，完全无视我们给窗口设的图标（这就是"任务栏图标和托盘不一样"）。
#    显式声明一个自己的 AUMID，任务栏才会把窗口当成"ClevoHelper 这个程序"。
#    必须在创建任何窗口之前调用，所以放在脚本最前面。
if (-not ('ClevoHelper.Shell32' -as [type])) {
    Add-Type -Namespace ClevoHelper -Name Shell32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetCurrentProcessExplicitAppUserModelID(out System.IntPtr appId);
'@
}
$script:Aumid = 'Yeguang.ClevoHelper'
try {
    [void][ClevoHelper.Shell32]::SetCurrentProcessExplicitAppUserModelID($script:Aumid)
    # 读回来确认（进程内的读法；窗口的 System.AppUserModel.ID 属性本来就是空的，
    # 任务栏在没有窗口属性时用的就是进程 AUMID）
    $p = [IntPtr]::Zero
    if ([ClevoHelper.Shell32]::GetCurrentProcessExplicitAppUserModelID([ref]$p) -eq 0 -and $p -ne [IntPtr]::Zero) {
        $script:AumidActual = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
    }
    else { $script:AumidActual = '(读不回来)' }
}
catch { $script:AumidActual = '(设置失败: ' + $_.Exception.Message + ')' }

# 2) 光有 AUMID 还不够：任务栏的**名字和图标**来自该 AUMID 的注册项。
#    没有注册项时 Windows 回落到进程映像（powershell.exe）—— 这就是任务栏右键写着
#    "Windows PowerShell"、还挂着 PowerShell 图标的原因。按微软给"未打包应用"的做法，
#    在 HKCU\SOFTWARE\Classes\AppUserModelId\<AUMID> 下登记显示名、图标，以及"固定到任务栏"
#    之后用来重启程序的命令。写 HKCU 不需要管理员；每次启动重写一遍（幂等）。
try {
    $iconForTaskbar = $(if ($HostExe -and (Test-Path -LiteralPath $HostExe)) { $HostExe }
                        else { Join-Path $PSScriptRoot 'app.ico' })
    $relaunch = $(if ($HostExe -and (Test-Path -LiteralPath $HostExe)) { '"' + $HostExe + '"' }
                  else { 'powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'ClevoHelper.ps1') + '"' })
    $aumidKey = 'HKCU:\SOFTWARE\Classes\AppUserModelId\' + $script:Aumid
    if (-not (Test-Path -LiteralPath $aumidKey)) { New-Item -Path $aumidKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $aumidKey -Name 'DisplayName' -Value 'ClevoHelper' -Force
    Set-ItemProperty -LiteralPath $aumidKey -Name 'IconUri' -Value $iconForTaskbar -Force
    Set-ItemProperty -LiteralPath $aumidKey -Name 'RelaunchCommand' -Value $relaunch -Force
    Set-ItemProperty -LiteralPath $aumidKey -Name 'RelaunchDisplayNameResource' -Value 'ClevoHelper' -Force
    $script:AumidRegistered = $true
}
catch { $script:AumidRegistered = $false; $script:AumidRegErr = $_.Exception.Message }

# 3) **窗口自己**的 AppUserModelID 属性 —— 这一层才是任务栏分组真正看的东西。
#    实测教训：只设进程 AUMID + 注册项，任务栏**仍然**把窗口算成 Windows PowerShell
#    （右键菜单里还是 PowerShell 的"任务"：Run as Administrator / ISE…）。原因是
#    SetCurrentProcessExplicitAppUserModelID 必须在进程创建任何窗口之前调用，而
#    powershell.exe 启动时就已经建过一个隐藏控制台窗口了 —— 我们调得太晚。
#    可靠做法是给窗口本身设属性（SHGetPropertyStoreForWindow + PKEY_AppUserModelID），
#    在窗口句柄刚建好、还没显示时设（SourceInitialized）。
if (-not ('ClevoHelper.ShellAumid' -as [type])) {
    Add-Type -Namespace ClevoHelper -Name ShellAumid -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
static extern int SHGetPropertyStoreForWindow(System.IntPtr hwnd, ref System.Guid iid, out IPropertyStore store);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
static extern int PSGetPropertyKeyFromName(string name, out PROPERTYKEY k);
[System.Runtime.InteropServices.DllImport("ole32.dll")] static extern void PropVariantClear(ref PROPVARIANT v);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack=4)]
public struct PROPERTYKEY { public System.Guid fmtid; public int pid; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct PROPVARIANT {
    [System.Runtime.InteropServices.FieldOffset(0)] public ushort vt;
    [System.Runtime.InteropServices.FieldOffset(8)] public System.IntPtr p;
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    int GetCount(out uint c);
    int GetAt(uint i, out PROPERTYKEY k);
    int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    int Commit();
}

static IPropertyStore StoreOf(System.IntPtr hwnd) {
    System.Guid iid = new System.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore store;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0) return null;
    return store;
}

/// 给窗口设 AppUserModelID（任务栏据此分组、取名、取图标）
public static int SetWindowAumid(System.IntPtr hwnd, string aumid) {
    PROPERTYKEY key;
    if (PSGetPropertyKeyFromName("System.AppUserModel.ID", out key) != 0) return -1;
    IPropertyStore store = StoreOf(hwnd);
    if (store == null) return -2;
    PROPVARIANT pv = new PROPVARIANT();
    pv.vt = 31;                                              // VT_LPWSTR
    pv.p = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUni(aumid);
    try {
        int hr = store.SetValue(ref key, ref pv);
        if (hr != 0) return hr;
        return store.Commit();
    } finally { PropVariantClear(ref pv); }                   // 这行会把字符串内存一并释放
}

/// 读回来确认（验证用）
public static string GetWindowAumid(System.IntPtr hwnd) {
    PROPERTYKEY key;
    if (PSGetPropertyKeyFromName("System.AppUserModel.ID", out key) != 0) return null;
    IPropertyStore store = StoreOf(hwnd);
    if (store == null) return null;
    PROPVARIANT pv;
    if (store.GetValue(ref key, out pv) != 0) return null;
    try {
        if (pv.vt == 31 && pv.p != System.IntPtr.Zero)
            return System.Runtime.InteropServices.Marshal.PtrToStringUni(pv.p);
        return null;
    } finally { PropVariantClear(ref pv); }
}
'@
}

# 2) 单实例：用命名互斥体，而不是靠"命令行里出现某个路径"。命令行匹配漏过一次 ——
#    开发模式下跑 src\ClevoHelper.ps1 的实例路径不同，启动器认不出来，于是又开了一个窗口。
#    互斥体不关心你是怎么起来的：已经有一个在跑时，这个实例只负责把那个窗口叫出来，然后退出。
$script:MutexName = 'Local\ClevoHelper.Panel'
$script:PanelMutex = $null
$script:AlreadyRunning = $false
try {
    $script:PanelMutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    try { $script:AlreadyRunning = -not $script:PanelMutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $script:AlreadyRunning = $false }   # 上一个进程异常退出
}
catch { }
if ($script:AlreadyRunning) {
    try {
        $flag = Join-Path (Split-Path $PSScriptRoot -Parent) 'show.request'
        Set-Content -LiteralPath $flag -Value (Get-Date).ToString('o') -Encoding ASCII
    }
    catch { }
    exit 0
}

$script:DchuPath = Join-Path $PSScriptRoot 'dchu.ps1'
# set by ClevoHelper.exe (-HostExe <path>) so the autostart entry can point at the exe
$script:HostExe = $HostExe

# ---------------------------------------------------------------- 设置 ------
# 一个很小的设置文件（放在数据目录，不在注册表）：目前只有一项 —— 启动时是否直接收进托盘。
# 默认"开"：这是个常驻托盘的监控工具，开机自启时弹一个窗口出来是打扰。
# 第一次双击启动也收进托盘，用户从托盘图标把它叫出来即可（托盘菜单/双击）。
$script:SettingsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'settings.json'
$script:Settings = @{ StartToTray = $true; FanCurve = $null; Led = $null; Saved = $null; SceneAuto = $false }
try {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        $j = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $j.StartToTray) { $script:Settings.StartToTray = [bool]$j.StartToTray }
        # 风扇曲线：**用户自己配的那份**（不是 EC 现在跑的那份）。四个数都在才算数。
        # 为什么单独处理：上面那些键都是布尔，不能一股脑 [bool] 转换。
        if ($null -ne $j.FanCurve) {
            $fc = $j.FanCurve
            if ($null -ne $fc.T2 -and $null -ne $fc.D2 -and $null -ne $fc.T3 -and $null -ne $fc.D3) {
                $script:Settings.FanCurve = @{
                    T2 = [int]$fc.T2; D2 = [int]$fc.D2; T3 = [int]$fc.T3; D3 = [int]$fc.D3
                }
            }
        }
        # 键盘灯：你最后调的那套（模式/颜色/亮度/速度）。开机时会被注入回键盘（见下面 LedRestored）。
        if ($null -ne $j.Led -and $null -ne $j.Led.Mode) {
            $l = $j.Led
            $script:Settings.Led = @{
                Mode = [string]$l.Mode; Bright = [int]$l.Bright; Speed = [int]$l.Speed
                Rainbow = [bool]$l.Rainbow; UseCustom = [bool]$l.UseCustom
                R = [int]$l.R; G = [int]$l.G; B = [int]$l.B
                Color = $(if ($null -ne $l.Color) { [int]$l.Color } else { $null })
            }
        }
        # "我的配置"：你在面板里点过的电源模式 / 风扇模式 / 充电窗口。开机时会被注入回去
        # （用户要求："每次我更改后保存，下次开机时自动注入我上次保存的东西"）。
        if ($null -ne $j.Saved) {
            $sv = @{}
            foreach ($k in 'PowerMode', 'FanMode', 'ChargerEnabled', 'ChargerStart', 'ChargerStop') {
                if ($null -ne $j.Saved.$k) { $sv[$k] = [int]$j.Saved.$k }
            }
            if ($sv.Count) { $script:Settings.Saved = $sv }
        }
        # 一键场景的自动切换（插电/电池时自动套用）。默认关：不打招呼就改电源模式和风扇
        # 是很讨厌的行为，必须用户自己勾。两档映射也一起存，方便以后加界面。
        if ($null -ne $j.SceneAuto) { $script:Settings.SceneAuto = [bool]$j.SceneAuto }
        if ($null -ne $j.SceneOnAc) { $script:Settings.SceneOnAc = [int]$j.SceneOnAc }
        if ($null -ne $j.SceneOnBat) { $script:Settings.SceneOnBat = [int]$j.SceneOnBat }
    }
}
catch { }
# -StartHidden 只在启动器要求时生效；设置里的开关决定"双击启动"要不要也收进托盘。
# 例外：-SelfTest 时必须让窗口真的显示出来 —— 自检里有几处是"真点按钮"（Invoke-Click 走
# RaiseEvent），而控件不在**已显示**的可视树里时 RaiseEvent 不会触发处理器（实测见
# src\diag-wire6.ps1），否则自检会报一堆假失败。
$script:StartToTray = ($StartHidden -or [bool]$script:Settings.StartToTray) -and (-not $SelfTest) -and (-not $SizeProbe)

$script:LogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\monitor-debug.log'

# ---- 分模块：按功能拆到 panel-*.ps1 ------------------------------------------
# 这些文件不是"模块"，是**同一份脚本的续页**：dot-source 进来以后共享同一个
# 作用域（$script: 变量、$n 控件表、函数互相可见）。所以拆分只改变"在哪个文件里
# 找代码"，不改变"代码怎么跑"——要改哪个功能，就开对应的那个文件。
# 函数在**调用时**才解析，所以这些文件的先后顺序不影响功能；新增文件记得加进
# build-exe.ps1 的 $scripts 清单（否则打包时不会被带进 exe）。
$script:PanelModules = @(
    'panel-core.ps1',
    'panel-fan.ps1',
    'panel-led.ps1',
    'panel-mode.ps1',
    'panel-scene.ps1',
    'panel-about.ps1',
    'panel-paint.ps1',
    'panel-sampler.ps1',
    'panel-tray.ps1',
    'panel-reboot.ps1',
    'panel-selftest.ps1'
)
foreach ($m in $script:PanelModules) { . (Join-Path $PSScriptRoot $m) }

# ---------------------------------------------------------------- 关于页 ----
# 头像和署名沿用用户另一个工具（SICAU-AutoLogin 校园网自动认证）里的"我的信息"：同一张头像、
# 同一个署名、同样的"名片 + 信息行 + 原理说明"结构，这样两个工具看起来是一个人做的。
# 头像是嵌进 EXE 的资源（build-exe.ps1 里 img.avatar.png），运行时解包到程序目录，
# 不依赖任何外部文件 —— 和那个工具一样，"程序只有一个 EXE"这个约定不破。
# 版本号的单一来源：这里改一处，标题栏和关于页都跟着变。
$script:AppName = 'ClevoHelper'
# 面板起来的时刻：系统页「已运行」用它算，不另建定时器。
$script:PanelStartAt = Get-Date
# ⚠️ 改这里要同步两处，否则"用户报的版本号"和"关于页显示的版本号"会打架：
#   1) README 里写的当前版本
#   2) GitHub Release 的 tag（发布脚本用 tools\Publish-Release.ps1）
# build-exe.ps1 会**从这个文件里正则读出版本号**，写进 exe 的文件版本属性 ——
# 所以这个字符串就是全项目唯一的版本来源（运行时显示 + exe 属性页都来自它）。
$script:AppVersion = '1.3'
$script:AuthorName = '极夜光'
$script:AuthorMail = 'yeguang225@outlook.com'

# 检查更新用的仓库（owner/repo）。换仓库只改这一行 —— README 的下载链接、发布脚本、
# 关于页的"检查更新"都以它为准。**只在用户点按钮时发一次请求**：这是个控制风扇/EC 的
# 工具，装完就该安静待在托盘里；启动时联网既拖慢冷启动，也让"离线也能用"变成空话。
$script:UpdateRepo = 'jiyeguang25/Clevo-X370-Control-Center'

# 关于页的信息行。**只放别处看不到的东西**（用户要求）：机型在标题栏、开机自启在杂项页、
# 显卡在状态/性能页、内存和处理器在状态页、EC 通道在底部状态栏 —— 这些这里都不再重复，
# 关于页只留"程序是谁、什么版本、装在哪"和两个别处确实没有的硬件号。
# 分成两套：软件自己的几行进「系统」页，硬件身份进「设备」页。
# 一页塞八行会挤成一片（用户反馈「系统页挤在一起」），分开放每页都正好。
$script:AboutRows = @(
    @{ Key = 'Version';  Label = '版本' }
    @{ Key = 'Built';    Label = '构建' }
    @{ Key = 'Mode';     Label = '运行方式' }
    @{ Key = 'ExePath';  Label = '程序位置' }
    @{ Key = 'DataDir';  Label = '数据目录' }
)
# 硬件身份：判断"这台机器是什么"只用看这四行，归设备页。
$script:DevRows = @(
    @{ Key = 'Model';    Label = '机型' }
    @{ Key = 'Serial';   Label = '序列号' }
    @{ Key = 'Bios';     Label = 'BIOS' }
    @{ Key = 'Windows';  Label = '系统' }
)

# 机器信息（只查一次：这些值在运行期不会变，每帧都查一遍 CIM 纯属浪费）
$script:SysInfo = [ordered]@{}
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $csx = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $script:SysInfo.Model = "$($cs.Model)"
    $script:SysInfo.Serial = "$($csx.IdentifyingNumber)"
    $script:SysInfo.Bios = "$($bios.SMBIOSBIOSVersion)"
    $script:SysInfo.Windows = ('{0} {1} (内部版本 {2})' -f $os.Caption, $os.Version, $os.BuildNumber)
    $script:SysInfo.Cpu = "$($cpu.Name)"
    $script:SysInfo.RamGB = [Math]::Round([int]($cs.TotalPhysicalMemory / 1MB) / 1024, 1)
}
catch { Write-Dbg ('sysinfo probe failed: ' + $_.Exception.Message) }

# 电池健康 / 输入设备：都是只读、都慢（DCOM 与 PnP 枚举各数百毫秒），所以只在这里读一次，
# 电池页与设备页直接取用。读不到就是读不到，界面上显示「—」，不假装有值。
# misc.ps1 平时只在采样 runspace 里被 dot-source（$script:Sync.MiscPath），主线程作用域里没有
# 它的函数，所以这里显式引一次——否则会报「Get-BatteryHealth 不是 cmdlet」（自检抓到的）。
. (Join-Path $PSScriptRoot 'misc.ps1')
$script:BattHealth = [pscustomobject]@{ Supported = $false }
try { $script:BattHealth = Get-BatteryHealth } catch { Write-Dbg ('battery health probe failed: ' + $_.Exception.Message) }
$script:InputInfo = [pscustomobject]@{ Keyboard = '--'; Touchpad = '--' }
try { $script:InputInfo = Get-InputDevices } catch { Write-Dbg ('input device probe failed: ' + $_.Exception.Message) }

# Power / "situational" modes. Labels, order and wording come from the factory language
# file (ControlCenter30\mtlanguage.ini), not from invention:
#   _Quiet         "Limits the system performance and fan noise for quiet places."
#   _PowerSaving   "Enables the maximum battery life."
#   _Entertainment "Balances among the system performance, surface temperature and fan noise."
#   _Performance   "Enables the maximum system performance."
# Two things were wrong before: the order was arbitrary, and 娱乐 gave no clue that it is
# the BALANCED mode. Now the row runs from least to most performance and every pill carries
# the factory description as a tooltip, with measured numbers where we actually have them.
#   (id 0=Quiet 1=PowerSaving 2=Performance 3=Entertainment - see dchu.ps1 PowerModeName)
$script:PowerPills = @(
    @{ Id = 1; Label = '省电'; Tip = '原厂说明：最大化电池续航（电池供电时最激进；官方提示此模式下用独显的程序会被关闭）' },
    @{ Id = 0; Label = '安静'; Tip = '原厂说明：限制性能与风扇噪音，适合安静环境。本机实测 CPU 封装功耗约 30 W / 2.6 GHz' },
    @{ Id = 3; Label = '均衡'; Tip = '原厂名称 Entertainment（娱乐）：在性能、表面温度和风扇噪音之间取平衡。' },
    @{ Id = 2; Label = '性能'; Tip = '原厂说明：释放最大性能。本机实测 CPU 封装功耗 122-137 W / ~4.95 GHz' }
)
# Fan-curve presets - NAMED fields, duties in PERCENT (the frame builder converts to raw
# with the vendor's own round(pct/100*255), see fancurve.ps1).
#
# The EC's percent table has FOUR nodes: T1/D1 = 40C/28% and T4/D4 = 100C/100% are fixed by
# the firmware, only T2/D2 and T3/D3 are ours to set. Verified three ways: the vendor's
# FAN.Write_WMI14 only writes buf[2..5]; its FanArgs carries exactly T2/D2/T3/D3; and the
# 10-node table belongs to the RPM editor whose read (command 4 sub 0x28) returns all zeros
# on this machine.
#
# The first preset is NOT factory. It is the curve the user had already dialled in with the
# factory Control Center - which is why its numbers (61C / 88C / 41% / 59%) are not multiples
# of 5. Per the user's request the presets are now snapped to 5s, rounding the TEMPERATURES
# DOWN and the DUTIES UP so the result never cools less than the original:
#   original 40/61/88C at 28/41/59%  ->  40/60/85C at 28/45/60%
# The three quantised curves this project measured are kept ONLY as documentation of what
# the values used to be - the UI no longer shows them (user request: 自动/最大/自定义 only).
# 原有 = the curve dialled in with the factory Control Center (61C/41%, 88C/59%).
$script:LegacyCurves = @(
    @{ Label = '原有'; T2 = 60; D2 = 45; T3 = 85; D3 = 60 },
    @{ Label = '均衡'; T2 = 60; D2 = 55; T3 = 85; D3 = 75 },
    @{ Label = '强冷'; T2 = 55; D2 = 70; T3 = 80; D3 = 95 }
)
# Custom curve: same four nodes, edited in the UI.
#
# **取值顺序变了（用户要求）**：先看 settings.json 里用户自己配的那份（FanCurve），有就用它；
# 没有才去读 EC 的当前表。原因：EC 那份可能是原厂/别的工具写的，里面是 60/38、86/59 这种
# **非 5 倍数**的值（界面上只能按 5 调，点都点不出来），用户每次重启面板看到的都是它，
# 感觉"我配的曲线丢了"。现在自己配的那份会存下来，重启也在。
$script:FanCustom = @{ T2 = 60; D2 = 45; T3 = 85; D3 = 60 }
$script:FanSeeded = $false
$script:FanLimits = @{ TMin = 45; TMax = 95; DMin = 30; DMax = 100; Step = 5 }
$script:FixedFirstDuty = 28   # the EC's T1/D1 point, 71 raw - not writable through this path
$script:FanCurveSource = 'default'   # settings / ec / default —— 只用于界面提示与日志
$script:FanAppliedOnStart = $false   # 启动时"按我的配置写回 EC"只做一次
$script:StartupConfigRestored = $false   # 电源/风扇模式注入只做一次
$script:StartupChargerChecked = $false    # 充电窗口比对只做一次
# 请求槽只有一份（见 Test-ReqSlotFree），所以每**条**启动注入都得单独记住"发过没有"：
$script:StartupPowerIssued = $false       # 电源模式那条已定下来（发过，或 EC 本来就是你要的）
$script:StartupFanModeIssued = $false     # 风扇模式那条已定下来（发过，或 EC 本来就是你要的）
$script:StartupMiscWanted = $false        # 为了比对充电窗口而点亮"读一次杂项"，只点一次

# 启动时就用"我的配置"（如果有），并把它标记成已就绪，免得第一次采样又把 EC 的当前值搬进来
if ($script:Settings.FanCurve) {
    [void](Set-FanCustomSafe $script:Settings.FanCurve)
    $script:FanSeeded = $true
    $script:FanCurveSource = 'settings'
    Write-Dbg ('fan curve from settings.json（不再读 EC 当前表）: T2={0} D2={1} T3={2} D3={3}' -f `
        $script:FanCustom.T2, $script:FanCustom.D2, $script:FanCustom.T3, $script:FanCustom.D3)
}

# ONE fan row. There used to be two ("风扇" and "风扇曲线"), and "自定义" was a pill that
# only selected EC mode 6 without writing any table - so it looked like a switch that did
# nothing. That is exactly the complaint, and the fix is not better wording: every pill
# here performs a COMPLETE, verified action, and the row is ordered from quietest to
# loudest:
#   自动   = hand the fans back to the EC's own logic (mode 0)
#   原厂/均衡/强冷 = write that curve table to block 14 + mirror page 4 + select mode 6
#   最大   = mode 1 (100%)
# The active pill is derived from the EC's RUNTIME table (block 13), not from what we
# last clicked, so "which curve is actually running" is visible instead of implied.
# Fan row: THREE choices only (user request - the presets were one row too many).
#   自动 = hand the fans back to the EC, 最大 = 100%, 自定义 = the two editable nodes below.
# The node values start from whatever curve the EC is already running (copied on the first
# sample), so 自定义 begins from the real current curve instead of a made-up default.
$script:FanPills = @(
    @{ Label = '自动'; Mode = 0;  Tip = '交回 EC 原生温控（最保守）' },
    @{ Label = '最大'; Mode = 1;  Tip = '风扇 100%' },
    @{ Label = '自定义'; Curve = $true; Tip = '用下面两个节点自己编曲线：温度 / 转速都是 5 的倍数' }
)

# ---------------------------------------------------------------- 一键场景 ----
# 把「电源模式 + 风扇模式 + 键盘灯 + 屏幕亮度」四件事打包成一颗按钮，一次点完全部改。
# 为什么敢做：这四条写路径都已经各自单独验证过 —— 电源/风扇走 Write-WmiMode（写完立刻回读
# 比对）、键盘灯走 kbled 的 HID 帧、亮度走 WMI。场景**不引入任何新协议**，它只是把这四条
# 排进同一个请求里按顺序执行，所以最坏情况是"某一项没写进去"，而不是"把机器搞坏"。
# 为什么只有三档、且不给编辑：场景的全部价值是"一次点完"。做成可编辑就变成又一组滑杆，
# 反而比现在更麻烦。要精细控制下面那几行本来就在。
# 风扇 2 = EC 自己的「静音」档（sampler 里的 $names 表写明 2 = 静音），不是我们编的曲线；
# 用 6（自定义曲线）会和"我的曲线"抢，所以刻意不用。
$script:ScenePills = @(
    @{ Label = '游戏'; Power = 2; Fan = 1; Kb = 'static'; R = 255; G = 70;  B = 70;  Bright = 100; Tip = '电源=性能 · 风扇=最大 · 键盘灯=静态红 · 亮度=100%' },
    @{ Label = '安静'; Power = 0; Fan = 2; Kb = 'static'; R = 120; G = 170; B = 255; Bright = 55;  Tip = '电源=安静 · 风扇=静音 · 键盘灯=静态蓝 · 亮度=55%' },
    @{ Label = '省电'; Power = 1; Fan = 0; Kb = 'off'; R = 0; G = 0; B = 0; Bright = 35; Tip = '电源=省电 · 风扇=自动 · 键盘灯=关 · 亮度=35%' }
)
$script:SceneSel = -1        # 高亮哪一档；-1 = 没有（刚启动，或套用后又被手动改过）
$script:SceneAuto = [bool]$script:Settings.SceneAuto   # 插电/电池变化时自动套用

# Graphics-mode pills. The list is NOT hard-coded: it comes from the EC's own supported-mode
# bitmask (res[1] of the 0x15 read), which is exactly how ControlCenter30 decides which
# entries to put in its combo box. On this machine that is iGPU / dGPU / Dynamic - MSHybrid
# (bit2) reads 0, so it is not offered. If the probe fails the row hides itself and the
# panel stays monitoring-only, rather than showing buttons that cannot work.
$script:GpuPillLabel = @{ 1 = '核显'; 2 = '独显'; 3 = '混合'; 4 = '动态' }
$script:GpuPills = @()
$script:GpuInfo = $null
try {
    . (Join-Path $PSScriptRoot 'dchu.ps1')
    $script:GpuInfo = Get-GpuMode
    foreach ($m in $script:GpuInfo.Supported) {
        if ($script:GpuPillLabel.ContainsKey($m)) { $script:GpuPills += @{ Id = $m; Label = $script:GpuPillLabel[$m] } }
    }
    Write-Dbg ('gpu mode probe: active={0} mask=0x{1:X2} offered=[{2}]' -f `
        $script:GpuInfo.Mode, $script:GpuInfo.Mask, (($script:GpuInfo.Supported) -join ','))
}
catch {
    $script:GpuPills = @()
    Write-Dbg ('gpu mode probe failed: ' + $_.Exception.Message)
}

# Keyboard LED swatches. Writes go through kbled.ps1 (ITE 829x, HID feature reports).
# NOTE the firmware requires ClearColor before a per-key repaint, which Set-LedAllColor
# does for us; a full 115-key repaint is ~115 reports at 1 ms pacing (~0.3 s).
#
# 彩虹 is NOT a colour: it asks for the multi-colour variant of whatever mode is active
# (d0 = 0x00 "pick your own colours" for the animated modes; a per-key rainbow sweep for
# 静态). It used to live in its own 渐变 row that only did anything in 静态 mode, which is
# exactly why colour handling felt rigid.
$script:RainbowSwatch = 'RAINBOW'
$script:RgbPills = @(
    @{ Label = '彩虹'; Rainbow = $true; Swatch = $script:RainbowSwatch },
    @{ Label = '关'; R = 0; G = 0; B = 0; Swatch = '#FF3A3F4A' },
    @{ Label = '红'; R = 255; G = 0; B = 0; Swatch = '#FFFF4444' },
    @{ Label = '橙'; R = 255; G = 120; B = 0; Swatch = '#FFFF8833' },
    @{ Label = '黄'; R = 255; G = 220; B = 0; Swatch = '#FFFFDD33' },
    @{ Label = '绿'; R = 0; G = 255; B = 0; Swatch = '#FF44DD66' },
    @{ Label = '青'; R = 0; G = 220; B = 255; Swatch = '#FF44DDEE' },
    @{ Label = '蓝'; R = 0; G = 80; B = 255; Swatch = '#FF4488FF' },
    @{ Label = '紫'; R = 170; G = 0; B = 255; Swatch = '#FFAA55FF' },
    @{ Label = '白'; R = 255; G = 255; B = 255; Swatch = '#FFEDF0F5' }
)
$script:RgbBrightness = @(
    @{ Label = '暗'; Level = 2 },
    @{ Label = '中'; Level = 6 },
    @{ Label = '亮'; Level = 10 }
)

# Keyboard mode row - FOUR modes only (user request: 关闭 / 静态 / 循环 / 呼吸).
# kbled.ps1 still carries the verified frame for every vendor mode (波浪/闪烁/随机/扫描/涟漪/
# 蛇形); those are simply not offered here, so there is no direction row and no second-colour
# row any more (both existed only for 波浪/蛇形 and 扫描).
# Keys must match kbled.ps1 $script:LedModes; the write runs in the sampler runspace, which
# validates them and fails loudly on a mismatch rather than guessing.
# Each mode declares what colour input it actually takes, so the UI can show the colour row
# ONLY when it means something:
#   Colors = 0  no colour at all (循环 picks its own, 关闭 has none)
#   Colors = 1  one colour (plus 彩虹 when Rainbow = $true)
# Rainbow = the firmware/vendor has a multi-colour variant for this mode.
$script:LedModePills = @(
    @{ Key = 'off';    Label = '关闭'; Colors = 0; Rainbow = $false },
    @{ Key = 'static'; Label = '静态'; Colors = 1; Rainbow = $true },
    @{ Key = 'wave';   Label = '波动'; Colors = 1; Rainbow = $true },
    @{ Key = 'breath'; Label = '呼吸'; Colors = 1; Rainbow = $true },
    @{ Key = 'cycle';  Label = '循环'; Colors = 0; Rainbow = $false }
)
$script:LedModeLabelAll = @{
    off = '关闭'; static = '静态'; wave = '波动'; breath = '呼吸'; cycle = '循环'
    blink = '闪烁'; random = '随机'; scan = '扫描'; ripple = '涟漪'; snake = '蛇形'
}
# 波动（以及被收敛掉的蛇形）是原厂唯一带方向的两个模式：帧里的 d0 = 0xA1 + 方向（单色），
# 或 0x71 + 方向（固件配色）。方向行因此**只在选中「波动」时出现**（和颜色行同一个做法：
# 控件只在真的有用的时候出现），其它模式下面没有这一行。
$script:LedDirPills = @(
    @{ Idx = 0; Label = '右' },
    @{ Idx = 1; Label = '左' },
    @{ Idx = 2; Label = '上' },
    @{ Idx = 3; Label = '下' }
)
# Footer note on the keyboard tab; kept here so the paint pass can prefix it with the
# "EC holds a mode this panel does not offer" sentence when that is the case.
$script:KbHintBase = '模式/颜色取自原厂逐键模块；灯色无软件读回，用 AppSettings 副本核对。'
$script:LedSpeedPills = @(
    @{ Level = 1;  Label = '慢' },
    @{ Level = 5;  Label = '中' },
    @{ Level = 10; Label = '快' }
)
# Autostart switch. Two pills rather than a checkbox so it matches the rest of the UI.
$script:AutostartPills = @(
    @{ On = $false; Label = '关' },
    @{ On = $true;  Label = '开' }
)
$script:LedSel = @{
    Mode    = 'static'
    ModeIdx = 1      # index into $script:LedModePills (1 = 静态)
    Dir     = 0
    Color   = (Get-RgbIndex '白')
    Color2  = (Get-RgbIndex '蓝')
    Bright  = 1      # index into $script:RgbBrightness (1 = 中/6)
    Speed   = 1      # index into $script:LedSpeedPills (1 = 中/5)
    Rainbow = $false # 彩虹（多色）而不是固定单色
    Custom  = @{ R = 255; G = 255; B = 255 }   # 色盘取到的颜色（UseCustom 时才用它）
    UseCustom = $false  # 用户是否用色盘挑了一个任意纯色
    Tab     = 'state'   # 状态 / 性能与散热 / 键盘灯 / 杂项
}
$script:LedConfigSource = 'default'   # settings / ec / default —— 只用于提示与日志
$script:LedRestored = $false          # 启动时"把上次的灯注入回去"只做一次

# 启动时就先把"我的灯"装进 LedSel，并标记已同步 —— 免得第一次采样又被 EC 镜像覆盖掉
if ($script:Settings.Led -and $script:Settings.Led.Mode) {
    Set-LedSelFromConfig $script:Settings.Led
    $script:LedSynced = $true
    $script:LedConfigSource = 'settings'
    Write-Dbg ('led config from settings.json: mode={0} color={1} rainbow={2} custom={3} bright={4} speed={5}' -f `
        $script:LedSel.Mode, $script:LedSel.Color, $script:LedSel.Rainbow, $script:LedSel.UseCustom, $script:LedSel.Bright, $script:LedSel.Speed)
}

# ------------------------------------------------------------ 杂项 tab state --
# 电池充电：三个选项就是原厂自己的三个（mtlanguage.ini 的 _MaximumBatteryCharge /
# _RecommendedBatteryCharge / _CustomBatteryCharge）：
#   最大电量 = FlexiCharger 关闭（原厂说明 "Constantly charge the battery to 100%"）
#   推荐     = 原厂出厂值 70% 起 / 80% 停（本机 EC 现在就是这一组）
#   自定义   = 用户自己挑起止阈值，可选项由 EC 在 0x1E 读里给（不自己编数字）
$script:ChargerPills = @(
    @{ Key = 'max';    Label = '最大电量'; Tip = '原厂“最大电池电量”：不限制充电，一直充到 100%' },
    @{ Key = 'rec';    Label = '推荐';     Tip = '原厂“推荐电池充电”：低于 70% 开始，充到 80% 停（出厂值）' },
    @{ Key = 'custom'; Label = '自定义';   Tip = '自己选起止阈值；可选项由 EC 提供，停机温度之外的组合会被拒绝' }
)
$script:ChargerRecommended = @{ Start = 70; Stop = 80 }
# 通用开关按钮：开/关、启用/禁用、常规/交换。都用同一套 pill 渲染，和面板其它地方一致。
$script:OnOffPills = @(@{ On = $true; Label = '开' }, @{ On = $false; Label = '关' })
$script:EnablePills = @(@{ On = $true; Label = '启用' }, @{ On = $false; Label = '禁用' })
$script:SwapPills = @(@{ On = $false; Label = '常规' }, @{ On = $true; Label = '交换' })
$script:MiscSel = @{
    Charger = 'rec'      # max / rec / custom
    Start   = 70         # 自定义阈值（同步自 EC 读回，不从默认值猜）
    Stop    = 80
    CustomOpen = $false  # 用户是否点开了「自定义」的阈值行（见 paint 里的优先级注释）
}

# 阈值可选项：启动时向 EC 问一次（0x1E），用它的答案生成按钮行，和显卡模式那一行同一个思路。
# 这样 XAML 里不会出现任何本文件编出来的温度/电量数字。
$script:ChargerInfo = $null
$script:ChargerStartPills = @()
$script:ChargerStopPills = @()
try {
    $script:ChargerInfo = Get-FlexiCharger
    foreach ($v in $script:ChargerInfo.StartOptions) { $script:ChargerStartPills += @{ Id = $v; Label = "$v" } }
    foreach ($v in $script:ChargerInfo.StopOptions) { $script:ChargerStopPills += @{ Id = $v; Label = "$v" } }
    $script:MiscSel.Start = [int]$script:ChargerInfo.Start
    $script:MiscSel.Stop = [int]$script:ChargerInfo.Stop
    Write-Dbg ('flexicharger probe: enabled={0} start={1} stop={2} startOpt=[{3}] stopOpt=[{4}]' -f `
        $script:ChargerInfo.Enabled, $script:ChargerInfo.Start, $script:ChargerInfo.Stop, `
        ($script:ChargerInfo.StartOptions -join ','), ($script:ChargerInfo.StopOptions -join ','))
}
catch { Write-Dbg ('flexicharger probe failed: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- 色盘 -------
# A real colour wheel for the keyboard page: angle = hue, radius = saturation, V fixed at 1
# (LED brightness is a separate setting - see 亮度 - so a dark corner on this wheel would only
# confuse). WPF has no conic gradient, so the pixels are generated once and cached.
# The generation is C#, not a PowerShell loop: 150x150 is 22,500 pixels and a PS loop costs
# over a second at startup, while this costs about a millisecond.
# Pick() uses the exact same formula as Pixels(), which is what makes "click here, get this
# colour" true rather than approximately true.
if (-not ('ClevoHelper.ColorWheel' -as [type])) {
    Add-Type -Namespace ClevoHelper -Name ColorWheel -MemberDefinition @'
public static void Hsv(double h, double s, double v, out int r, out int g, out int b) {
    double c = v * s;
    double hp = h / 60.0;
    double xx = c * (1 - System.Math.Abs(hp % 2 - 1));
    double m = v - c;
    double r1 = 0, g1 = 0, b1 = 0;
    int seg = (int)System.Math.Floor(hp) % 6;
    if (seg < 0) seg += 6;
    switch (seg) {
        case 0: r1 = c;  g1 = xx; break;
        case 1: r1 = xx; g1 = c;  break;
        case 2: g1 = c;  b1 = xx; break;
        case 3: g1 = xx; b1 = c;  break;
        case 4: r1 = xx; b1 = c;  break;
        default: r1 = c; b1 = xx; break;
    }
    r = (int)System.Math.Round((r1 + m) * 255.0);
    g = (int)System.Math.Round((g1 + m) * 255.0);
    b = (int)System.Math.Round((b1 + m) * 255.0);
}
// BGRA pixels, alpha 0 outside the circle so the wheel does not sit in a coloured square
public static byte[] Pixels(int size) {
    byte[] px = new byte[size * size * 4];
    double r0 = size / 2.0;
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            double dx = x + 0.5 - r0, dy = y + 0.5 - r0;
            double d = System.Math.Sqrt(dx * dx + dy * dy);
            int i = (y * size + x) * 4;
            if (d > r0) { px[i + 3] = 0; continue; }
            double h = (System.Math.Atan2(dy, dx) * 180.0 / System.Math.PI + 360.0) % 360.0;
            double s = System.Math.Min(1.0, d / r0);
            int r, g, b;
            Hsv(h, s, 1.0, out r, out g, out b);
            px[i] = (byte)b; px[i + 1] = (byte)g; px[i + 2] = (byte)r; px[i + 3] = 255;
        }
    }
    return px;
}
// { R, G, B, hue, satPercent } for a point inside the wheel; null outside it
public static int[] Pick(double x, double y, int size) {
    double r0 = size / 2.0;
    double dx = x - r0, dy = y - r0;
    double d = System.Math.Sqrt(dx * dx + dy * dy);
    if (d > r0) return null;
    double h = (System.Math.Atan2(dy, dx) * 180.0 / System.Math.PI + 360.0) % 360.0;
    double s = System.Math.Min(1.0, d / r0);
    int r, g, b;
    Hsv(h, s, 1.0, out r, out g, out b);
    return new int[] { r, g, b, (int)System.Math.Round(h), (int)System.Math.Round(s * 100.0) };
}
'@
}

$script:WheelSize = 170

# Volume rows are generated so the storage panel adapts to however many drives exist.
# The 内存 row above them uses the SAME four column widths, so the two bars start at the
# same x and the detail / percent columns line up down the whole card.
# These widths are for the PORTRAIT window (468px): the 800px version had a 132px bar and
# room for '已用 414 GB / 954 GB · 可用 540 GB' in one line. At 468 the detail column
# wrapped onto two lines and the numbers stopped lining up, so the bar is 96px and the text
# is the short '已用/总量' form - with the full sentence kept in the tooltip.
$script:MaxVolumes = 6
$script:MaxPhysDisks = 4
$script:BarWidth = 96          # shared by the memory row and the volume rows

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClevoHelper" Width="468" SizeToContent="Height" MaxHeight="920"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display">
  <!-- 滚动条：默认 WPF 滚动条是浅灰的，贴在深色页面上很扎眼。这里换成 8px 深色滑块。 -->
  <Window.Resources>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Width="8">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#FF3A4150" CornerRadius="4" Margin="1,2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#FF141619" CornerRadius="14" BorderBrush="#FF2B303B" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="52"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" Margin="22,0,0,0" VerticalAlignment="Center">
          <Image x:Name="TitleIcon" Width="18" Height="18" Margin="0,0,9,0" VerticalAlignment="Center"/>
          <TextBlock Text="ClevoHelper" Foreground="#FFEDF0F5" FontSize="16" FontWeight="SemiBold"/>
          <TextBlock x:Name="SubTitle" Text="  Clevo X370SN" Foreground="#FF98A1B3" FontSize="12" Margin="8,2,0,0" MaxWidth="86" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <!-- 温度放标题栏：每页都能看见，又不占页面高度（原来那条常驻概览条就是这么下线的）。 -->
        <TextBlock x:Name="TitleTemps" Text="" Foreground="#FF8A93A6" FontSize="11" FontFamily="Consolas"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,80,0"/>
        <TextBlock x:Name="MinBtn" Text="&#x2013;" Foreground="#FF8A93A6" FontSize="16"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,48,6" Cursor="Hand"/>
        <TextBlock x:Name="CloseBtn" Text="&#x2715;" Foreground="#FF8A93A6" FontSize="14"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,22,0" Cursor="Hand"/>
      </Grid>

      <StackPanel Grid.Row="1" Margin="16,0,16,0">
        <!-- Eight pages, eight equal columns, two-character labels so the row stays one line.
             The strip that used to sit above this row (the always-on CPU/GPU/mode readout)
             is gone: it duplicated 概览 on every page. The one number that is worth seeing
             from anywhere - CPU/GPU temperature - moved into the title bar instead. -->
        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" x:Name="TabBtnState" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnStateT" Text="概览" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="1" x:Name="TabBtnPerf" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnPerfT" Text="性能·散热" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="2" x:Name="TabBtnKb" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnKbT" Text="灯效" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="3" x:Name="TabBtnBatt" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnBattT" Text="电池" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="4" x:Name="TabBtnMisc" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnMiscT" Text="设备" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="5" x:Name="TabBtnSys" Background="#FF272C36" CornerRadius="12" Margin="0,0,3,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnSysT" Text="系统" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="6" x:Name="TabBtnAbout" Background="#FF272C36" CornerRadius="12" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnAboutT" Text="关于" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
          </Border>
        </Grid>

        <!-- ============ 状态 ============ -->
        <!-- Same box as the other three tabs: same background/radius/padding and the SAME
             fixed height, so switching tabs never changes the window size (user request:
             四个界面的长宽一样). The CPU/GPU cards are stacked instead of side by side -
             two cards cannot both fit across a portrait window. -->
        <Border x:Name="StatePanel" Background="#FF17191F" CornerRadius="12" Padding="20,14,20,12" Height="480">
        <ScrollViewer x:Name="TabState" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
          <StackPanel>
          <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Margin="0,0,0,8" Padding="18,14,18,12">
            <StackPanel>
              <TextBlock x:Name="CpuHeader" Text="CPU · i9-13900HX" Foreground="#FF8A93A6" FontSize="11" TextTrimming="CharacterEllipsis"/>
              <!-- three equal metric columns; every value sits in a 34px box and is
                   bottom-aligned, so the 30px temperature and the 18px numbers share a
                   baseline and all three captions sit on one line -->
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <Grid Height="34">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                      <TextBlock x:Name="CpuTemp" Text="--" Foreground="#FF57B0FF" FontSize="30" FontWeight="Bold"/>
                      <TextBlock x:Name="CpuTempUnit" Text="&#176;C" Foreground="#FF57B0FF" FontSize="12" VerticalAlignment="Bottom" Margin="3,0,0,4"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock Text="温度" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <Grid Height="34">
                    <TextBlock x:Name="CpuFreq" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="有效频率" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <Grid Height="34">
                    <TextBlock x:Name="CpuPower" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="封装功耗" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="#FF272C36" Margin="0,10,0,9"/>
              <!-- identical geometry to the GPU card: 负载 | 风扇转速 | 风扇占空比 -->
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="112"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="负载 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="CpuUtil" Text="--" Foreground="#FFD7DCE6" FontSize="13" FontFamily="Consolas"
                             Width="34" TextAlignment="Left"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="风扇 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="CpuRpm" Text="--" Foreground="#FFEDF0F5" FontSize="13" FontFamily="Consolas"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock x:Name="CpuDutyText" Text="--" Foreground="#FF98A1B3" FontSize="11" Margin="0,0,8,0" MinWidth="30" TextAlignment="Right"/>
                  <Border Background="#FF272C36" CornerRadius="3" Height="6" Width="104">
                    <Border x:Name="CpuBar" Background="#FF57B0FF" CornerRadius="3" Height="6" Width="0" HorizontalAlignment="Left"/>
                  </Border>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

          <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Margin="0,0,0,8" Padding="18,14,18,12">
            <StackPanel>
              <TextBlock x:Name="GpuHeader" Text="GPU · RTX 4080 Laptop" Foreground="#FF8A93A6" FontSize="11" TextTrimming="CharacterEllipsis"/>
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <Grid Height="34">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                      <TextBlock x:Name="GpuTemp" Text="--" Foreground="#FF6FE38A" FontSize="30" FontWeight="Bold"/>
                      <TextBlock x:Name="GpuTempUnit" Text="&#176;C" Foreground="#FF6FE38A" FontSize="12" VerticalAlignment="Bottom" Margin="3,0,0,4"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock Text="温度" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <Grid Height="34">
                    <TextBlock x:Name="GpuFreq" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="核心频率" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <Grid Height="34">
                    <TextBlock x:Name="GpuPower" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="功耗" Foreground="#FF8A93A6" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="#FF272C36" Margin="0,10,0,9"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="112"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="负载 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="GpuUtil" Text="--" Foreground="#FFD7DCE6" FontSize="13" FontFamily="Consolas"
                             Width="34" TextAlignment="Left"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="风扇 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="GpuRpm" Text="--" Foreground="#FFEDF0F5" FontSize="13" FontFamily="Consolas"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock x:Name="GpuDutyText" Text="--" Foreground="#FF98A1B3" FontSize="11" Margin="0,0,8,0" MinWidth="30" TextAlignment="Right"/>
                  <Border Background="#FF272C36" CornerRadius="3" Height="6" Width="104">
                    <Border x:Name="GpuBar" Background="#FF6FE38A" CornerRadius="3" Height="6" Width="0" HorizontalAlignment="Left"/>
                  </Border>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

        <!-- 内存 -->
        <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Margin="0,0,0,8" Padding="18,12,18,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="76"/>
              <ColumnDefinition Width="96"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="内存" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center"/>
            <Border Grid.Column="1" Background="#FF272C36" CornerRadius="3" Height="7" VerticalAlignment="Center">
              <Border x:Name="MemBar" Background="#FFB98BFF" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
            </Border>
            <TextBlock Grid.Column="2" x:Name="MemText" Text="--" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" Margin="10,0,10,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Grid.Column="3" x:Name="MemPct" Text="" Foreground="#FFB98BFF" FontSize="11" VerticalAlignment="Center" MinWidth="46" TextAlignment="Right"/>
          </Grid>
        </Border>


        <!-- 存储：从设备页搬来（概览太空、设备太挤；CPU/GPU/内存/存储本来就是一组） -->
        <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Margin="0,8,0,0" Padding="18,9,18,9">
          <StackPanel>
            <Grid>
              <TextBlock Text="存储" Foreground="#FF8A93A6" FontSize="11"/>
              <TextBlock x:Name="PhysDiskText" HorizontalAlignment="Right" Foreground="#FF8A93A6" FontSize="11"/>
            </Grid>
$(for ($i = 0; $i -lt $script:MaxVolumes; $i++) { New-VolumeRowXaml $i })
          </StackPanel>
        </Border>
        <!-- 屏幕亮度：从杂项页搬到这里（用户要求）—— 调亮度是"看屏幕时随手就做"的事，
             放在监控页比放在杂项页顺路。 -->
        <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Margin="0,8,0,0" Padding="18,9,18,9">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="76"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="屏幕亮度" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center"/>
            <Slider Grid.Column="1" x:Name="BrightSlider" Minimum="0" Maximum="100" TickFrequency="5"
                    IsSnapToTickEnabled="False" IsMoveToPointEnabled="True" VerticalAlignment="Center"
                    Foreground="#FF57B0FF" Background="#FF272C36" Margin="0,0,10,0"/>
            <TextBlock Grid.Column="2" x:Name="BrightVal" Text="--%" Foreground="#FFD7DCE6" FontSize="11.5"
                       FontFamily="Consolas" MinWidth="42" TextAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
          </StackPanel>         </ScrollViewer>
        </Border>
      </StackPanel>

      <!-- 性能与散热 / 键盘灯 / 杂项 share this box. Its height, padding and margins are
           IDENTICAL to StatePanel above, so all four tabs occupy exactly the same rectangle
           and the window does not resize when switching (StatePanel is the one that gets
           Collapsed instead of this box).
           注意 Visibility="Collapsed" 是**必须**的：面板启动时默认就在「状态」页，只有重画
           之后才会把 ControlPanel 收起来。如果它一开始是可见的，首次布局就同时量到
           StatePanel(470) + ControlPanel(470)，窗口直接顶到 MaxHeight=920，用户看到的效果
           就是"先很长、再缩回实际高度"。实测（-SizeProbe）：
             win=468x920  StatePanel=470 ControlPanel=470     ← 修复前
             win=468x662  StatePanel=470 ControlPanel=0(c)    ← 重画之后
           把默认值和"默认标签页"对齐，首帧就等于最终帧，跳变彻底消失。 -->
      <Border x:Name="ControlPanel" Grid.Row="2" Background="#FF17191F" CornerRadius="12" Margin="16,0,16,0" Padding="20,14,20,12" Height="480" Visibility="Collapsed">
        <StackPanel>
          <!-- ============ 性能与散热（原两页合并） ============ -->
          <ScrollViewer x:Name="TabPerf" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <!-- 一键场景放最上面：这是本页唯一"点一下就全改"的东西，比下面任何单点控
                 制都更常按，而且它能一眼说清"现在是什么状态"。 -->
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="场景" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ScenePillRow">
$(New-PillXaml 'Scn' $script:ScenePills)
              </StackPanel>
            </Grid>
            <TextBlock x:Name="SceneHint" Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" Margin="66,0,0,8"/>
$(New-SwitchRowXaml 'ScnA' '自动切换' $script:OnOffPills '插电/电池时自动套用')

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="电源" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="PowerPillRow">
$(New-PillXaml 'Pwr' $script:PowerPills)
              </StackPanel>
            </Grid>

            <Grid x:Name="GpuRow" Margin="0,0,0,3">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="显卡" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="GpuPillRow">
$(New-PillXaml 'Gpu' $script:GpuPills)
              </StackPanel>
            </Grid>
            <!-- The confirm strip gets its own line: it carries two 52px buttons plus the
                 question, and in the right-hand column of a 468px row it would start on top
                 of the third mode pill (measured: pills end at x=336). -->
            <Grid Margin="66,0,0,8">
              <TextBlock x:Name="GpuNow" Text="" Foreground="#FF98A1B3" FontSize="11" VerticalAlignment="Center"/>
              <!-- 暂存了新模式以后，这一行的右边会出现「立即重启」：重启申请弹窗关掉之后
                   （或者用户当时选了"稍后"），想立刻重启还能在这儿点，不用去开始菜单。
                   它只在"已暂存 ≠ 当前生效"时出现。 -->
              <Border x:Name="GpuRebootBtn" Background="#FF272C36" CornerRadius="11" MinWidth="72" Padding="0,5"
                      HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand" Visibility="Collapsed">
                <TextBlock Text="立即重启" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
              </Border>
              <StackPanel x:Name="GpuConfirm" Orientation="Horizontal" HorizontalAlignment="Right" Visibility="Collapsed">
                <TextBlock x:Name="GpuConfirmText" Text="" Foreground="#FFE3C86F" FontSize="11" VerticalAlignment="Center" Margin="0,0,9,0"/>
                <Border x:Name="GpuOk" Background="#FFE3C86F" CornerRadius="13" MinWidth="52" Padding="0,5" Margin="0,0,7,0" Cursor="Hand">
                  <TextBlock Text="确认" Foreground="#FF11141A" FontSize="12" FontWeight="SemiBold" TextAlignment="Center"/>
                </Border>
                <Border x:Name="GpuCancel" Background="#FF272C36" CornerRadius="13" MinWidth="52" Padding="0,5" Cursor="Hand">
                  <TextBlock Text="取消" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
              </StackPanel>
            </Grid>


            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="风扇" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="FanPillRow">
$(New-PillXaml 'Fan' $script:FanPills)
              </StackPanel>
            </Grid>
            <!-- 曲线健康度 on its OWN line. In the 800px window it sat in a third column of
                 the fan row; at 468px the pill column is 326px wide and the Auto column
                 started UNDER the third pill (measured: text at x=281, 自定义 pill 259..329),
                 so the two overlapped. Measured with diag-layout.ps1, not guessed. -->
            <TextBlock x:Name="CurveHealth" Text="" Foreground="#FF98A1B3" FontSize="11" Margin="66,0,0,8"/>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="Ct2RowLabel" Grid.Column="0" Text="节点 2" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
$(New-StepperXaml 'Ct2T' '温度')
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal">
$(New-StepperXaml 'Ct2D' '转速' '%')
              </StackPanel>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="Ct3RowLabel" Grid.Column="0" Text="节点 3" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
$(New-StepperXaml 'Ct3T' '温度')
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal">
$(New-StepperXaml 'Ct3D' '转速' '%')
              </StackPanel>
            </Grid>

            <!-- 恢复初始 moved here from the title row: it is this tab's rollback button
                 (power / fan / curve / staged GPU / keyboard lighting), so it belongs next
                 to the things it undoes instead of competing with the tab buttons. -->
            <Border x:Name="RevertBtn" Background="#FF272C36" CornerRadius="13" Padding="0,6" Margin="0,10,0,0" Cursor="Hand">
              <TextBlock x:Name="RevertBtnT" Text="恢复初始（电源·风扇·曲线·显卡·键盘灯）" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
            </Border>            <TextBlock x:Name="PerfProto" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="· 「当前生效」里的电源 / 风扇 / 显卡都是回读值，被外部改掉会立刻跟着变。"/>
            <TextBlock x:Name="PerfScene" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"
                       Text="· 节点 1（40°C/28%）与节点 4（100°C/100%）由 EC 固定，这两行只控制中间两档。"/>                        <TextBlock x:Name="RevertHint" Foreground="#FF98A1B3" FontSize="10.5" TextWrapping="Wrap" Margin="2,8,0,0"
                       Text="恢复初始：把电源、风扇、曲线、显卡、键盘灯改回本次开机时的值（亮度不动），约 2 秒。"/>
            </StackPanel>           </ScrollViewer>

          <!-- ============ 键盘灯 ============ -->
          <ScrollViewer x:Name="TabKb" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="模式" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="LedModeRow">
$(New-PillXaml 'Led' $script:LedModePills 56)
              </StackPanel>
            </Grid>

            <!-- Colour row is shown ONLY for modes that actually take a colour (see the Colors
                 field on $script:LedModePills): 循环/关闭 hide it entirely. 彩虹 in the swatch
                 row means "multi-colour" - 静态 draws it per key, 波 hands the colour bands to
                 the firmware, 呼吸 hands it to the firmware. -->
            <!-- Colour row. The hint used to sit in a third column on the right; at 468px the
                 swatches ran underneath it, so every hint on this tab now gets its own line
                 under its row (uniform rule, no overlap possible). -->
            <Grid x:Name="LedColorRow" Margin="0,0,0,3">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="LedColorLabel" Grid.Column="0" Text="颜色" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
$(New-SwatchXaml 'Rgb' $script:RgbPills)
              </StackPanel>
            </Grid>
            <TextBlock x:Name="LedColorHint" Text="" Foreground="#FF8A93A6" FontSize="11" Margin="66,0,0,8"/>

            <!-- 方向：只有「波」用得到（帧里 d0 = 0xA1/0x71 + 方向），所以这一行只在选中
                 波的时候出现。提示放在按钮右边（短），不再单独占一行 —— 竖屏下这一页的
                 高度要用在色盘上（单独一行会把提示挤到色盘上面去）。 -->
            <Grid x:Name="LedDirRow" Margin="0,0,0,9">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="方向" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="LedDirPillRow">
$(New-PillXaml 'Dir' $script:LedDirPills 56)
              </StackPanel>
              <TextBlock x:Name="LedDirHint" Grid.Column="2" Text="色带滚过方向" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center"/>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="亮度" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="RgbBrightRow">
$(New-PillXaml 'RgbB' $script:RgbBrightness 56)
              </StackPanel>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="速度" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="LedSpeedRow">
$(New-PillXaml 'Spd' $script:LedSpeedPills 56)
              </StackPanel>
            </Grid>

            <!-- 色盘（用户要求：纯色可以直接取色）。只在需要颜色的模式出现（和颜色行同一
                 个可见性），点/拖都能取色；V 固定 1，亮度是上面那一行的事。
                 色盘和信息块**并排**：色盘只有 170px 宽，把它单独放一行会在右边留下大片空白
                 （用户反馈"看起来较宽"），并排之后整块居中，右边那块正好放取到的颜色。 -->
            <StackPanel x:Name="ColorWheelBox" Margin="0,2,0,6" HorizontalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Grid>
                  <Image x:Name="ColorWheel" Width="132" Height="132" Cursor="Cross"/>
                  <Canvas x:Name="WheelLayer" Width="132" Height="132" IsHitTestVisible="False">
                    <Ellipse x:Name="WheelMark" Width="14" Height="14" Stroke="#FFEDF0F5" StrokeThickness="2"
                             Visibility="Collapsed"/>
                  </Canvas>
                </Grid>
                <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
                  <Border x:Name="WheelPick" Width="56" Height="56" CornerRadius="28" Background="#FFFFFFFF"
                          BorderBrush="#FF2B303B" BorderThickness="1"/>
                  <TextBlock x:Name="WheelText" Text="--" Foreground="#FFD7DCE6" FontSize="11" FontFamily="Consolas"
                             Margin="0,8,0,0"/>
                  <TextBlock x:Name="WheelText2" Text="" Foreground="#FF98A1B3" FontSize="11" FontFamily="Consolas"
                             Margin="0,3,0,0"/>
                  <TextBlock x:Name="WheelHint" Text="取到的颜色会立刻写进键盘" Foreground="#FF8A93A6" FontSize="10"
                             Margin="0,8,0,0" TextWrapping="Wrap" MaxWidth="150"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>

            <TextBlock x:Name="KbHint" Foreground="#FF98A1B3" FontSize="11"
                       Text="$script:KbHintBase" TextWrapping="Wrap"/>
            <TextBlock x:Name="LedProto" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="· 写入帧 CC 01 6C R G B 00（7 字节，只改颜色不动其它设置）；灯亮没亮没有软件回读，面板用 AppSettings 副本核对。"/>
            <TextBlock x:Name="LedScene" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"
                       Text="· 场景「游戏 / 安静」会把灯色一起切过去；在本页改过颜色后，场景高亮会自动熄灭。"/>
            <TextBlock x:Name="LedScope" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"
                       Text="· 颜色只对 静态 / 呼吸 有效；波动与循环按方向跑，颜色按不进。" />
            </StackPanel>
          </ScrollViewer>

          <!-- ============ 杂项 ============ -->
          <ScrollViewer x:Name="TabMisc" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <!-- 屏幕亮度已经搬到状态页（用户要求），这里不再重复 -->

$(New-SwitchRowXaml 'Tp' '触控板' $script:OnOffPills '注册表 + 原厂通知')
$(New-SwitchRowXaml 'Wk' 'Win 键' $script:EnablePills '误触不会切走游戏' 56)
$(New-SwitchRowXaml 'Fl' 'FnLock' $script:OnOffPills 'F1-F12 免按 Fn')
$(New-SwitchRowXaml 'Ws' 'Win/Fn' $script:SwapPills '交换：左下角两键对调')
$(New-SwitchRowXaml 'Nl' '数字键盘' $script:OnOffPills '系统 NumLock')

            <!-- 输入设备：启动时读一次（设备枚举慢，不进采样循环）。键盘灯走的是哪一路 HID、
                 触控板挂在哪个总线上，出问题时要看的正是这两行。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,6,0,10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="键盘灯 HID " Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="DevKb" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="指针  " Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" Margin="0,6,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="DevTp" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
              </Grid>
            </Border>
                        <!-- 硬件身份：以前这四行挤在系统页里，用户反馈"系统页挤在一起"。
                 机型/序列号/BIOS/系统本来就是"设备"，放这里才对。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="13,8,14,8" Margin="0,0,0,4">
          <StackPanel x:Name="DevInfo">
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="76"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Text="处理器" Foreground="#FF98A1B3" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock x:Name="Dev_Cpu" Grid.Column="1" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"
                           FontFamily="Consolas" TextTrimming="CharacterEllipsis"/>
              </Grid>
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="76"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Text="内存总量" Foreground="#FF98A1B3" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock x:Name="Dev_Ram" Grid.Column="1" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"
                           FontFamily="Consolas" TextTrimming="CharacterEllipsis"/>
              </Grid>
$(foreach ($r in $script:DevRows) { New-AboutRowXaml ("Dev_" + $r.Key) $r.Label })
              </StackPanel>
            </Border>

<TextBlock x:Name="MiscHint" Foreground="#FF98A1B3" FontSize="11" TextWrapping="Wrap"
                       Text="摄像头切换只有原厂 cc30wk.exe 一条路，本面板不提供。开关显示的都是读回值。"/>
            </StackPanel>           </ScrollViewer>

          <!-- ============ 散热 ============ -->

          <!-- ============ 电池 ============ -->
          <ScrollViewer x:Name="TabBatt" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <!-- 电池状态：让充电限制的效果就在旁边看得见（系统给的电量/供电状态），
                 和下面那行的 EC 阈值是同一件事的两头。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,9,14,9" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="电池" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Background="#FF272C36" CornerRadius="3" Height="7" VerticalAlignment="Center" Margin="12,0,12,0">
                  <Border x:Name="BattBar" Background="#FF6FE38A" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
                </Border>
                <TextBlock Grid.Column="2" x:Name="BattText" Text="--" Foreground="#FF8A93A6" FontSize="11"
                           FontFamily="Consolas" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- 电池健康：只读，启动/首次打开本页时读一次（root\wmi BatteryStaticData 有点慢，不进采样循环）。
                 设计容量与满充容量之比就是损耗；循环次数本机不报（CycleCount 恒 0），这一格改显示制造日期。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal">
                  <TextBlock Text="健康度 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhHealth" Text="--" Foreground="#FF6FE38A" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal">
                  <TextBlock Text="制造 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhCycles" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="0" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="设计容量 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhDesign" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="满充容量 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhFull" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="2" Grid.Column="0" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="当前容量 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhNow" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="电压 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhVolt" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>                <StackPanel Grid.Row="3" Grid.Column="0" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="充放功率 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhRate" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Grid.Row="3" Grid.Column="1" Orientation="Horizontal" Margin="0,6,0,0">
                  <TextBlock Text="电池温度 " Foreground="#FF8A93A6" FontSize="11"/>
                  <TextBlock x:Name="BhTemp" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                </StackPanel>
              </Grid>
            </Border>
            <!-- 电池充电：原厂三选一。自定义时才显示阈值行（和键盘灯的颜色行同一个做法：
                 控件只在真的有用的时候出现，不用一排放着灰按钮）。 -->
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="电池充电" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChargerRow">
$(New-PillXaml 'Chg' $script:ChargerPills 74)
              </StackPanel>
            </Grid>
            <TextBlock x:Name="ChargerHint" Text="" Foreground="#FF8A93A6" FontSize="11" Margin="66,0,0,8"/>

            <!-- 自定义阈值行**常驻**（用户要求）：不管当前是哪个档都看得见，
                 但只有选中「自定义」时可选中；其它档位下变暗且点不动（和风扇节点行同一个做法）。
                 这样"自定义里有什么"一眼可见，也不会出现"点开了又收回去"。 -->
            <StackPanel x:Name="ChargerCustom">
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="66"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="充电开始" x:Name="ChgStartLabel" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChgStartRow">
$(New-PillXaml 'ChgS' $script:ChargerStartPills 32)
                </StackPanel>
              </Grid>
              <Grid Margin="0,0,0,9">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="66"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="充电停止" x:Name="ChgStopLabel" Foreground="#FF98A1B3" FontSize="12" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChgStopRow">
$(New-PillXaml 'ChgE' $script:ChargerStopPills 32)
                </StackPanel>
              </Grid>
            </StackPanel>


            <!-- 保养建议：按当前电池状态真算出来的几句话（不是固定文案）。
                 判据写在 panel-paint.ps1 的 batt 分支里，这样文案和判据不会分家。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,6,0,0">
              <StackPanel>
                <TextBlock Text="保养建议" Foreground="#FF8A93A6" FontSize="10.5" Margin="0,0,0,5"/>
                <TextBlock x:Name="BattAdvice" Text="--" Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" LineHeight="17"/>
              </StackPanel>
            </Border>
            <!-- 电池信息：来自 root\wmi 的 BatteryStaticData（启动时读一次，运行期不变）。
                 循环次数本机不报（读回 0），所以不列这一项。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,6,0,0">
              <StackPanel>
                <TextBlock Text="电池信息" Foreground="#FF8A93A6" FontSize="10.5" Margin="0,0,0,5"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" Margin="0,2,0,0">
                    <TextBlock Text="厂商 " Foreground="#FF8A93A6" FontSize="11"/>
                    <TextBlock x:Name="BhMfr" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" Margin="0,2,0,0">
                    <TextBlock Text="型号 " Foreground="#FF8A93A6" FontSize="11"/>
                    <TextBlock x:Name="BhDev" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Row="1" Grid.Column="0" Orientation="Horizontal" Margin="0,2,0,0">
                    <TextBlock Text="化学 " Foreground="#FF8A93A6" FontSize="11"/>
                    <TextBlock x:Name="BhChem" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                  </StackPanel>
                  <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,2,0,0">
                    <TextBlock Text="预计可用 " Foreground="#FF8A93A6" FontSize="11"/>
                    <TextBlock x:Name="BhLeft" Text="--" Foreground="#FFD7DCE6" FontSize="11.5"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
            </Border>
            </StackPanel>           </ScrollViewer>


          <!-- ============ 系统 ============ -->
          <ScrollViewer x:Name="TabSys" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <!-- 管的是程序自己：开机自启 / 托盘 / 更新检查。全在设置文件里，不碰 EC。 -->
$(New-SwitchRowXaml 'Auto' '开机自启' $script:AutostartPills '登录后自动启动')
$(New-SwitchRowXaml 'Tray' '收进托盘' $script:OnOffPills '不弹窗口，只留托盘图标')

            <!-- 检查更新：**必须由用户点**，不做后台自动轮询、不做静默下载（一条明确的红线）。
                 样式沿用本页既有的"Border + Cursor=Hand + MouseLeftButtonUp"，和标签页按钮同一套手感。 -->
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Border x:Name="AboutCheckUpdateBtn" Background="#FF272C36" CornerRadius="11" Padding="10,4" Cursor="Hand">
                <TextBlock x:Name="AboutCheckUpdateT" Text="检查更新" Foreground="#FFB98BFF" FontSize="11"/>
              </Border>
              <TextBlock x:Name="AboutUpdateStatus" Text="" Foreground="#FF8A93A6" FontSize="11"
                         Margin="10,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
            </StackPanel>

            <!-- 本机环境：值全部来自真实来源（EXE 自己的时间戳、本次运行的位置、DCHU 真选中的 DLL）。 -->
            <StackPanel x:Name="AboutInfo">
$(foreach ($r in $script:AboutRows) { New-AboutRowXaml ("About_" + $r.Key) $r.Label })
            </StackPanel>

            <!-- 运行记录：这一页管的是程序自己，所以"开了多久、日志多大、写在哪"都在这。
                 四个值全是只读、都在重画时当场算，不占采样通道。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,10,0,0">
              <StackPanel>
$(New-AboutRowXaml 'RunUp' '已运行')
$(New-AboutRowXaml 'RunFreq' '采样')
$(New-AboutRowXaml 'RunLogSize' '日志')
$(New-AboutRowXaml 'RunLogPath' '日志位置')
              </StackPanel>
            </Border>

            <!-- 操作提示：这几条原来只写在 README 里，装完不看文档的人根本不知道
                 × 只是收托盘、真退出在托盘右键。放在关于页成本最低。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,10,14,10" Margin="0,10,0,0">
              <StackPanel>
                <TextBlock Text="操作提示" Foreground="#FF8A93A6" FontSize="11" Margin="0,0,0,6"/>
                <TextBlock Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" LineHeight="18"
                           Text="· 托盘图标双击 = 打开面板，右键 = 菜单（电源/风扇/键盘灯都在那）&#10;· 右上 – 和 × 都是收进托盘，不是退出；真退出用 Alt+F4 或托盘右键&#10;· 非 X370SN 机型：加 --force-write 启动可临时放行写入"/>
              </StackPanel>
            </Border>

            <TextBlock x:Name="AboutGuardWarn" Foreground="#FFE38A6F" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"
                       Visibility="Collapsed"
                       Text="--"/>
            <!-- 只在通道坏了的时候出现：平时不重复底部状态栏已经写着的东西 -->
            <TextBlock x:Name="AboutChannelWarn" Foreground="#FFE38A6F" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                       Visibility="Collapsed"
                       Text="⚠ EC 通道当前读不到数据：温度/风扇/模式/键盘灯这些按钮都会失效。修复办法（任一）：托盘右键 → 修复 DCHU 驱动…；或运行 ClevoHelper.exe --install-driver（会弹 UAC），完成后重启面板。"/>
            </StackPanel>           </ScrollViewer>

          <!-- ============ 关于 ============ -->
          <ScrollViewer x:Name="TabAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Padding="0,0,0,0">
            <StackPanel>
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="14,12,14,12" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Ellipse Grid.Column="0" Width="96" Height="96" VerticalAlignment="Center">
                  <Ellipse.Fill>
                    <ImageBrush x:Name="AboutAvatarBrush" Stretch="UniformToFill"/>
                  </Ellipse.Fill>
                </Ellipse>
                <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                  <TextBlock x:Name="AboutName" Text="--" Foreground="#FFEDF0F5" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock x:Name="AboutTitle" Text="--" Foreground="#FFB98BFF" FontSize="12" Margin="0,4,0,0"/>
                  <TextBlock x:Name="AboutMail" Text="--" Foreground="#FF8A93A6" FontSize="11" Margin="0,4,0,0"/>
                  <TextBlock x:Name="AboutTagline" Text="--" Foreground="#FF98A1B3" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Grid>
            </Border>

            <!-- 本机适配：为什么能在这台机器上跑、换机器会怎样。纯静态文字，不占采样。 -->
            <Border Background="#FF1E222A" BorderBrush="#FF2B303B" BorderThickness="1" CornerRadius="10" Padding="13,9,14,9" Margin="0,10,0,0">
              <StackPanel>
                <TextBlock Text="本机适配" Foreground="#FF8A93A6" FontSize="10.5" Margin="0,0,0,5"/>
                <TextBlock Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,3"
                           Text="· 机型判据看序列号里的 X370SN —— 型号名（X17 Pro Max）里没有 X370"/>
                <TextBlock Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,0,0,3"
                           Text="· 通道 InsydeDCHU.dll → AcpiBridge.sys → ACPI _DSM（UUID 93f224e4…afad）"/>
                <TextBlock Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap"
                           Text="· 机型守卫只拦写入；只读监控在任何机器上都能用"/>
              </StackPanel>
            </Border>            <TextBlock x:Name="AboutFeatures" Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"
                       Text="功能：状态监控 · 电源模式 · 风扇曲线（可自定义节点） · 显卡模式（重启生效） · 键盘灯（静态/波/呼吸/循环 + 色盘取色） · 电池充电上限 · 亮度/触控板/Win 键/FnLock/数字键盘 · 托盘菜单 · 开机自启 · – / × 都是收进托盘（真退出：托盘右键 → 退出，或 Alt+F4）"/>
            <TextBlock x:Name="AboutProto" Foreground="#FF8A93A6" FontSize="10.5" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="写入一律经 SetDCHU_Data(121, {值,0,0,子项}) → AcpiBridge.sys → ACPI _DSM；键盘灯是另一条路，走 HID 的 CC 01 6C R G B 00。"/>                        <TextBlock x:Name="AboutNote" Foreground="#FF98A1B3" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="原理：温度/风扇/模式/键盘灯都走原厂那条 InsydeDCHU → AcpiBridge 通道（ACPI\CLV0001），和原厂控制中心用的是同一条路；每次写入都会从硬件读回校验，状态栏绿色=一致、橙色=不一致。显卡模式是开机前值，只能重启后生效，所以本面板只暂存、不替你重启。"/>
            <TextBlock x:Name="AboutDisclaimer" Foreground="#FF8A93A6" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="个人自用工具，与蓝天（Clevo）及其代工厂无关；所有写入都基于本机实测逆向出来的协议，换机器不保证可用。"/>
            </StackPanel>           </ScrollViewer>

        </StackPanel>
      </Border>

      <Border Grid.Row="3" Background="#FF17191F" CornerRadius="12" Margin="16,8,16,10" Padding="16,9,16,9">
        <TextBlock x:Name="StatusText" Text="初始化…" Foreground="#FF98A1B3" FontSize="11" TextWrapping="Wrap"/>
      </Border>
    </Grid>
  </Border>
</Window>
"@

$script:Win = [Windows.Markup.XamlReader]::Parse($xaml)

# 窗口句柄一建好就给它设 AUMID —— 必须在窗口显示之前（SourceInitialized 正是这个时机），
# 否则任务栏已经把这一组算成 PowerShell 了。
$script:Win.Add_SourceInitialized({
    try {
        $h = [System.Windows.Interop.WindowInteropHelper]::new($script:Win).Handle
        $rc = [ClevoHelper.ShellAumid]::SetWindowAumid($h, $script:Aumid)
        # 立刻回读是**读不到**的：写进窗口属性库由 shell 异步生效（实测写 rc=0、立刻读为空，
        # 几秒后由另一个进程读就是我们的 AUMID）。所以这里只记写入结果 + 句柄，
        # 真正的验证交给 diag-aumid.ps1（独立进程、独立时刻去读）。
        Write-Dbg ('window AUMID: write rc={0} hwnd=0x{1:X} （立刻回读为空是正常的，用 diag-aumid.ps1 验证）' -f $rc, $h.ToInt64())
    }
    catch { Write-Dbg ('window AUMID FAILED: ' + $_.Exception.Message) }
})
$n = @{}
$names = @('SubTitle', 'TitleIcon', 'CloseBtn', 'TitleBar', 'CpuHeader', 'CpuTemp', 'CpuRpm', 'CpuDutyText', 'CpuBar', 'CpuFreq', 'CpuPower', 'CpuUtil',
    'GpuTemp', 'GpuRpm', 'GpuDutyText', 'GpuBar', 'GpuFreq', 'GpuPower', 'GpuUtil',
    'StatusText', 'RevertBtn', 'RevertBtnT', 'CurveHealth', 'MinBtn',
    'GpuHeader', 'MemBar', 'MemText', 'MemPct', 'PhysDiskText',
    'GpuRow', 'GpuPillRow', 'GpuNow', 'GpuConfirm', 'GpuConfirmText', 'GpuOk', 'GpuCancel', 'GpuRebootBtn',
    'AutoRow', 'TitleTemps',
    'BhHealth', 'BhCycles', 'BhDesign', 'BhFull', 'BhNow', 'BhVolt', 'BhRate', 'BhTemp', 'BhMfr', 'BhDev', 'BhChem', 'BhLeft', 'DevKb', 'DevTp', 'RevertHint',
    'TabBtnState', 'TabBtnStateT', 'TabState', 'ControlPanel', 'StatePanel',
    'TabBtnPerf', 'TabBtnPerfT', 'TabBtnKb', 'TabBtnKbT', 'TabBtnMisc', 'TabBtnMiscT',
    'TabBtnBatt', 'TabBtnBattT',
    'TabPerf', 'TabKb', 'TabMisc', 'TabBatt', 'KbHint', 'MiscHint', 'LedProto', 'LedScene', 'LedScope', 'PerfProto', 'PerfScene', 'AboutProto', 'Dev_Cpu', 'Dev_Ram',
    'TabBtnSys', 'TabBtnSysT', 'TabSys',
    'TabBtnAbout', 'TabBtnAboutT', 'TabAbout', 'AboutAvatarBrush', 'AboutName', 'AboutTitle', 'AboutMail', 'AboutTagline',
    'AboutInfo', 'AboutNote', 'AboutFeatures', 'AboutDisclaimer', 'AboutChannelWarn', 'AboutGuardWarn',
    'AboutCheckUpdateBtn', 'AboutCheckUpdateT', 'AboutUpdateStatus',
    'LedDirRow', 'LedDirPillRow', 'LedDirHint', 'WheelText2', 'WheelHint',
    'LedModeRow', 'LedColorRow', 'LedColorHint', 'LedSpeedRow',
    'ChargerRow', 'ChargerHint', 'ChargerCustom', 'ChgStartRow', 'ChgStopRow', 'ChgStartLabel', 'ChgStopLabel',
    'ColorWheelBox', 'ColorWheel', 'WheelLayer', 'WheelMark', 'WheelPick', 'WheelText',
    'BattBar', 'BattText', 'BattAdvice',
    'BrightSlider', 'BrightVal',
    'LedColorLabel', 'Ct2RowLabel', 'Ct3RowLabel',
    'CpuTempUnit', 'GpuTempUnit', 'Ct2TMinus', 'Ct2TVal', 'Ct2TUnit', 'Ct2TPlus', 'Ct2DMinus', 'Ct2DVal', 'Ct2DUnit', 'Ct2DPlus',
    'Ct3TMinus', 'Ct3TVal', 'Ct3TUnit', 'Ct3TPlus', 'Ct3DMinus', 'Ct3DVal', 'Ct3DUnit', 'Ct3DPlus')
for ($i = 0; $i -lt $script:MaxVolumes; $i++) {
    $names += "Vol${i}Row"; $names += "Vol${i}Name"; $names += "Vol${i}Bar"
    $names += "Vol${i}Size"; $names += "Vol${i}Type"
}
for ($i = 0; $i -lt $script:PowerPills.Count; $i++) { $names += "Pwr$i"; $names += "Pwr${i}T" }
for ($i = 0; $i -lt $script:ScenePills.Count; $i++) { $names += "Scn$i"; $names += "Scn${i}T" }
for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) { $names += "ScnA$i"; $names += "ScnA${i}T" }
$names += 'SceneHint'
for ($i = 0; $i -lt $script:FanPills.Count; $i++) { $names += "Fan$i"; $names += "Fan${i}T" }
for ($i = 0; $i -lt $script:RgbPills.Count; $i++) { $names += "Rgb$i" }
for ($i = 0; $i -lt $script:RgbBrightness.Count; $i++) { $names += "RgbB$i"; $names += "RgbB${i}T" }
for ($i = 0; $i -lt $script:GpuPills.Count; $i++) { $names += "Gpu$i"; $names += "Gpu${i}T" }
for ($i = 0; $i -lt $script:LedModePills.Count; $i++) { $names += "Led$i"; $names += "Led${i}T" }
for ($i = 0; $i -lt $script:LedSpeedPills.Count; $i++) { $names += "Spd$i"; $names += "Spd${i}T" }
for ($i = 0; $i -lt $script:AutostartPills.Count; $i++) { $names += "Auto$i"; $names += "Auto${i}T" }
for ($i = 0; $i -lt $script:ChargerPills.Count; $i++) { $names += "Chg$i"; $names += "Chg${i}T" }
for ($i = 0; $i -lt $script:ChargerStartPills.Count; $i++) { $names += "ChgS$i"; $names += "ChgS${i}T" }
for ($i = 0; $i -lt $script:ChargerStopPills.Count; $i++) { $names += "ChgE$i"; $names += "ChgE${i}T" }
foreach ($pre in 'Tp', 'Wk', 'Fl', 'Ws', 'Nl', 'Tray') {
    for ($i = 0; $i -lt 2; $i++) { $names += "${pre}$i"; $names += "${pre}${i}T" }
}
foreach ($r in $script:AboutRows) { $names += ('About_' + $r.Key) }
    foreach ($r in $script:DevRows) { $names += ('Dev_' + $r.Key) }
    $names += @('RunUp', 'RunFreq', 'RunLogSize', 'RunLogPath')
for ($i = 0; $i -lt $script:LedDirPills.Count; $i++) { $names += "Dir$i"; $names += "Dir${i}T" }
foreach ($k in $names) { $n[$k] = $script:Win.FindName($k) }

$n.TitleBar.Add_MouseLeftButtonDown({
    if (Test-InTitleButton $_.OriginalSource) { return }
    # 合成事件（自检）里左键并不是真的按下，DragMove 会抛；包起来，别让一个拖动失败把面板带走
    try { $script:Win.DragMove() } catch { Write-Dbg ('DragMove skipped: ' + $_.Exception.Message) }
})
# × 也收进托盘（用户要的：点 × 不该把程序关掉）。**真退出**仍然有两条明确的路：
# 托盘右键 → 退出，或者 Alt+F4（那条走的是 WM_CLOSE，不经过这个按钮）。
$n.CloseBtn.Add_MouseLeftButtonDown({ Hide-ToTray })
$n.CloseBtn.ToolTip = '收进托盘（退出：托盘右键 → 退出，或 Alt+F4）'
$n.MinBtn.ToolTip = '收进托盘（后台继续监控）'
$n.CloseBtn.Add_MouseEnter({ $n.CloseBtn.Foreground = Get-Brush '#FFEDF0F5' })
$n.CloseBtn.Add_MouseLeave({ $n.CloseBtn.Foreground = Get-Brush '#FF8A93A6' })
$n.RevertBtn.Add_MouseEnter({ $n.RevertBtn.Background = Get-Brush '#FF30353F' })
$n.RevertBtn.Add_MouseLeave({ $n.RevertBtn.Background = Get-Brush '#FF272C36' })

try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $bb = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).IdentifyingNumber
    $bare = if ($bb -match 'X370') { 'Clevo X370SN' } else { 'Clevo' }
    $n.SubTitle.Text = "  $($cs.Model) · $bare"
}
catch { }

# ---------------------------------------------------------------- plumbing ---
$script:Sync = [hashtable]::Synchronized(@{ Stop = $false; Error = ''; Pending = $null; LastWrite = $null; RebootAsk = $null })
$script:Sync.DchuPath = $script:DchuPath
$script:Sync.LogPath = $script:LogPath
$script:Sync.NvidiaSmi = 'C:\Windows\System32\nvidia-smi.exe'   # legacy; gpu.ps1 searches instead
$script:Sync.GpuPath = Join-Path $PSScriptRoot 'gpu.ps1'
$script:Sync.KbLedPath = Join-Path $PSScriptRoot 'kbled.ps1'
$script:Sync.KbReady = $false
$script:Sync.FanCurvePath = Join-Path $PSScriptRoot 'fancurve.ps1'
$script:Sync.MiscPath = Join-Path $PSScriptRoot 'misc.ps1'
$script:Sync.Hist = @()
# 一键场景：采样器要自己判断"该套哪一档"，所以定义和判定状态都放进共享表。
# SceneDefs 是纯数据副本（PSCustomObject），采样器只读它 —— 不把界面上的 hashtable
# 递进去，免得两个 runspace 同时改同一个对象。
$script:Sync.SceneDefs = @($script:ScenePills | ForEach-Object {
        [pscustomobject]@{
            Label = [string]$_.Label; Power = [int]$_.Power; Fan = [int]$_.Fan; Kb = [string]$_.Kb
            R = [int]$_.R; G = [int]$_.G; B = [int]$_.B; Bright = [int]$_.Bright
        }
    })
$script:Sync.SceneAuto = [bool]$script:SceneAuto
$script:Sync.SceneOnAc = [int]$(if ($null -ne $script:Settings.SceneOnAc) { $script:Settings.SceneOnAc } else { 0 })
$script:Sync.SceneOnBat = [int]$(if ($null -ne $script:Settings.SceneOnBat) { $script:Settings.SceneOnBat } else { 2 })
$script:Sync.OnAcLast = $null     # 上一次看到的供电状态；null = 还没采到，这一轮只记录不切换
$script:Sync.AcTick = 0
$script:Sync.SceneIndex = -1
$script:Sync.BrightWrote = $false  # 用户/场景写过亮度后就别再补记基线（见采样器里的"亮度基线补记"）
$script:Sync.BrightTick = 0
# the 杂项 tab's state is read on a slower cadence than the sensors (once a second, and only
# while that tab is on screen): brightness goes through WMI and the touchpad through the
# registry, and neither is worth a query every 250 ms
$script:Sync.WantMisc = $false
# 启动时要跟"我的配置"比对充电窗口，而那需要一次**完整**的杂项读（平时只在杂项页可见时才读）。
# 这个"需求"由界面点亮、由采样器在真正读完一次完整杂项后清掉 —— 直接设 WantMisc 是不行的：
# 重画每 400ms 就会按当前标签页把它覆盖回去，而杂项读最快也要 1 秒才轮到。
$script:Sync.NeedFullMisc = $false
$script:Sync.MiscDirty = $false
$script:Sync.WantBright = $false      # 状态页：只读亮度这一路
# static host facts, queried once
try { $script:Sync.TotalRamMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) } catch { $script:Sync.TotalRamMB = 0 }
Write-Dbg ('AUMID check: set={0} actual={1} registered={2} {3}  (taskbar 名字/图标身份)' -f `
    $script:Aumid, $script:AumidActual, $script:AumidRegistered, $(if ($script:AumidRegErr) { 'err=' + $script:AumidRegErr } else { '' }))
try {
    $script:Sync.PhysDisks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
        [pscustomobject]@{ Model = "$($_.Model)".Trim(); GB = [math]::Round($_.Size / 1GB, 1) }
    })
} catch { $script:Sync.PhysDisks = @() }
$script:Sync.BaseMhz = 2200
try { $script:Sync.BaseMhz = (Get-CimInstance Win32_Processor).MaxClockSpeed } catch { }

# CPU load. % Processor Utility is the number Task Manager shows (it follows turbo
# headroom, so it is the honest "how busy is this CPU", and it can read >100 under
# boost - it is clamped below). It is absent on some builds, so probe once at start-up
# and fall back to the plain % Processor Time. If neither works CpuUtil stays $null and
# the panel shows "--" rather than a fake 0.
$script:Sync.CpuUtilCounter = ''
foreach ($cp in @('\Processor Information(_Total)\% Processor Utility', '\Processor(_Total)\% Processor Time')) {
    try {
        $probe = Get-Counter -Counter $cp -MaxSamples 1 -ErrorAction Stop
        if ($probe -and @($probe.CounterSamples).Count) { $script:Sync.CpuUtilCounter = $cp; break }
    }
    catch { }
}
Write-Dbg ('cpu util counter: ' + $(if ($script:Sync.CpuUtilCounter) { $script:Sync.CpuUtilCounter } else { 'none found' }))

# remember the state as it is right now, so [恢复初始] can undo the session
$script:Sync.GpuSupported = @($script:GpuInfo.Supported)
$script:Sync.GpuStaged = 0
# 机型守卫的结论要传到界面上（关于页那条橙色警示）。dchu.ps1 会 dot-source
# model-guard.ps1 并把 $script:ModelIsX370SN / $script:ModelGuardWhy 留在这个作用域里。
$script:Sync.GuardWarn = $null
$script:Sync.GuardForced = $false
try {
    . $script:DchuPath
    $t0 = Get-ClevoTelemetry
    # 亮度基线：立即读一次，读不到再试（开机这一瞬间 WMI 有时还没热身）。
    # 这里必须用「变量 + break」，不能写 $(for (...) { ... return $bv } -1)：
    # `return` 写在子表达式里退出的是**整个脚本**，不是那个 for。以前 misc.ps1 没在
    # 主作用域被 dot-source，Get-ScreenBrightness 每次都抛 CommandNotFound 被 catch 吃掉，
    # 于是这个 return 永远走不到；一旦它第一次真的读到值，脚本就在启动时静默结束
    # （现象：把亮度值 "55" 打到 stdout、exit 0、日志停在 cpu util counter 那行）。
    $bright0 = -1
    for ($bi = 0; $bi -lt 6; $bi++) {
        try {
            $bv = [int](Get-ScreenBrightness).Percent
            if ($bv -ge 0) { $bright0 = $bv; break }
        }
        catch { }
        Start-Sleep -Milliseconds 250
    }
    $script:Sync.StartState = [pscustomobject]@{
        PowerMode = $t0.PowerMode; FanMode = $t0.FanMode; FanOffset = $t0.FanOffset
        GpuMode   = $(if ($script:GpuInfo) { $script:GpuInfo.Mode } else { 0 })
        # 亮度一起记：场景会改亮度，"恢复初始"必须能把它一起还原（见 restore 分支的注释）。
        Bright    = $bright0
    }
    Write-Dbg ("panel start state: power={0} fan={1} offset={2} gpu={3} bright={4}" -f `
        $t0.PowerMode, $t0.FanMode, $t0.FanOffset, $script:Sync.StartState.GpuMode, $script:Sync.StartState.Bright)
    Write-Dbg ('dchu dll: ' + $script:DchuDll)
}
catch { $script:Sync.StartState = $null; Write-Dbg ('start state failed: ' + $_.Exception.Message) }

# ---- 机型守卫的界面投影 ----------------------------------------------------------
# 三种情况各有各的说法（用户点了按钮没反应时，必须能在关于页看到原因）：
#   * 走了逃生门   —— 明确写出"守卫已关闭"，免得用户以为保护还在；
#   * 判定不通过   —— 写出判定依据 + 只读仍可用的说明；
#   * 通过         —— 不显示任何东西（本机就是这种情况，平时永远看不到这条）。
if (-not $script:ModelGuardDone -or $null -eq $script:ModelIsX370SN) {
    # dchu.ps1 没加载成功（比如 DLL 缺失）—— 守卫没判定过，就别说守卫的事
}
elseif ($script:ModelGuardForced) {
    $script:Sync.GuardForced = $true
    $script:Sync.GuardWarn = '⚠ 机型守卫已关闭（--force-write）：本工具的命令字只在蓝天 Clevo X370SN 上实测过，当前允许写入。风险自负。'
}
elseif (-not $script:ModelIsX370SN) {
    $script:Sync.GuardWarn = ('⚠ 已停止写入：本机不是蓝天 Clevo X370SN（{0}）。监控照常，但电源模式/风扇/键盘灯这些写入会被拦下。' -f $script:ModelGuardWhy)
}
Write-Dbg ('model guard: ok={0} forced={1} why={2}' -f $script:ModelIsX370SN, $script:ModelGuardForced, $script:ModelGuardWhy)

for ($i = 0; $i -lt $script:ScenePills.Count; $i++) {
    $idx = $i
    $n["Scn$i"].Add_MouseLeftButtonUp({ Invoke-Scene $idx }.GetNewClosure())
}
for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) {
    $on = [bool]$script:OnOffPills[$i].On
    $n["ScnA$i"].Add_MouseLeftButtonUp({ Set-SceneAuto -On $on }.GetNewClosure())
}

for ($i = 0; $i -lt $script:PowerPills.Count; $i++) {
    $mode = $script:PowerPills[$i].Id
    $n["Pwr$i"].Add_MouseLeftButtonUp({
        Request-Write -Mode $mode -Kind 'power'
        Save-MyConfig 'PowerMode' $mode        # 点过的就是"我的配置"，下次开机注入
    }.GetNewClosure())
}
$n.RevertBtn.Add_MouseLeftButtonUp({ Request-Write -Mode 0 -Kind 'restore' })

# ---- 显卡模式：就地二次确认 ------------------------------------------------
# A wrong graphics mode can only be seen AFTER a reboot, and there is no online read-back,
# so a single click must never write. First click only stages the choice and turns the row
# into an explicit 确认/取消 pair; the write happens on 确认 and even then nothing moves
# until the user restarts - we never reboot for them.
#
# !! 这里曾经写成"三个匿名处理块 + GetNewClosure()"，结果是**点了确认什么都不写**：
#    `$script:GpuStage = $mode` 写在 GetNewClosure() 的块里时，赋的是**那个闭包自己的模块
#    作用域**里的变量，外面的脚本作用域根本看不到它；而 GpuOk 的处理块读到的还是 0，于是
#    `if ($m -gt 0)` 不成立，一条命令都不发。用户看到的就是"显卡模式不能改"。
#    为什么确认条照样出现？因为 `$n.GpuConfirm.Visibility = ...` 是**给对象赋属性**，不是给
#    变量赋值 —— 属性赋值改的是被捕获的那个对象，跨作用域没问题（键盘灯的 `$script:LedSel.X`
#    同理，所以那边一直是好的）。
#    自检实测证据（修之前）:
#      SELFTEST gpu: Invoke-Click=True GpuStage=0 确认条可见=Visible
#      SELFTEST gpu 写入结果: ... GpuStaged=0（目标 1）
#    修法：逻辑搬进**函数**。函数调用是在它自己的会话状态里跑的（`Request-Write` 从闭包里被
#    调用、照样能写 `$script:Sync.Pending`，就是这条的证据），所以函数里的 `$script:GpuStage`
#    就是脚本作用域那个。另外面板启动时会用 AST 静态扫一遍自己：凡是 GetNewClosure 块里出现
#    `$script:标量 = ...` 就报出来（见 Test-ClosureScopeTrap）。
$script:GpuStage = 0
for ($i = 0; $i -lt $script:GpuPills.Count; $i++) {
    $mode = $script:GpuPills[$i].Id
    $n["Gpu$i"].Add_MouseLeftButtonUp({ Set-GpuStage $mode }.GetNewClosure())
}
$n.GpuOk.Add_MouseLeftButtonUp({ Confirm-GpuStage })
$n.GpuCancel.Add_MouseLeftButtonUp({ Cancel-GpuStage })
# 暂存之后的「立即重启」：走的是同一张重启申请（先问再重启，和暂存那一刻弹的是同一个窗口）
$n.GpuRebootBtn.Add_MouseLeftButtonUp({
    $staged = $(if ($script:Sync.Snapshot) { [int]$script:Sync.Snapshot.GpuStaged } else { 0 })
    if ($staged -gt 0) { Show-RebootPrompt -Mode $staged }
    else {
        $n.StatusText.Text = '现在没有已暂存的显卡模式，不需要重启'
        $n.StatusText.Foreground = Get-Brush '#FF98A1B3'
    }
})

# 电池充电三选一：最大电量 = 不限制；推荐 = 原厂 70/80；自定义 = 用下面的阈值行。
# The thresholds travel WITH the request: the sampler runspace has its own copy of the world
# and must not read $script: state that belongs to the UI.
for ($i = 0; $i -lt $script:ChargerPills.Count; $i++) {
    $key = $script:ChargerPills[$i].Key
    $n["Chg$i"].Add_MouseLeftButtonUp({
        $script:MiscSel.Charger = $key
        if ($key -eq 'custom') {
            # 阈值行现在是常驻的，这里只负责"切到自定义"这个状态。CustomOpen 要记住：
            # 否则下一次重画（约 400ms 后）会按 EC 的当前值判定"现在是推荐"，按钮又变回不可点。
            $script:MiscSel.CustomOpen = $true
            $script:MiscSel.Charger = 'custom'
            $n.StatusText.Text = '自定义充电阈值：点起始与停止电量（可选项由 EC 提供，选了就写）'
            $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
        }
        else {
            $script:MiscSel.CustomOpen = $false
            $start = $(if ($key -eq 'rec') { [int]$script:ChargerRecommended.Start } else { [int]$script:MiscSel.Start })
            $stop = $(if ($key -eq 'rec') { [int]$script:ChargerRecommended.Stop } else { [int]$script:MiscSel.Stop })
            Request-Misc -Sub 'charger' -Value ([pscustomobject]@{ Mode = $key; Start = $start; Stop = $stop })
            # 充电窗口也是"我的配置"：下次开机按这个注入回去（最大电量 = 关闭限制）
            Save-MyConfig 'ChargerEnabled' $(if ($key -eq 'max') { 0 } else { 1 })
            if ($key -ne 'max') {
                Save-MyConfig 'ChargerStart' $start
                Save-MyConfig 'ChargerStop' $stop
            }
        }
    }.GetNewClosure())
}
for ($i = 0; $i -lt $script:ChargerStartPills.Count; $i++) {
    $v = [int]$script:ChargerStartPills[$i].Id
    $n["ChgS$i"].Add_MouseLeftButtonUp({
        $script:MiscSel.Start = $v
        Request-Misc -Sub 'start' -Value ([pscustomobject]@{ Start = $v; Stop = [int]$script:MiscSel.Stop })
        Save-MyConfig 'ChargerEnabled' 1
        Save-MyConfig 'ChargerStart' $v
    }.GetNewClosure())
}
for ($i = 0; $i -lt $script:ChargerStopPills.Count; $i++) {
    $v = [int]$script:ChargerStopPills[$i].Id
    $n["ChgE$i"].Add_MouseLeftButtonUp({
        $script:MiscSel.Stop = $v
        Request-Misc -Sub 'stop' -Value ([pscustomobject]@{ Start = [int]$script:MiscSel.Start; Stop = $v })
        Save-MyConfig 'ChargerEnabled' 1
        Save-MyConfig 'ChargerStop' $v
    }.GetNewClosure())
}

# ---- 屏幕亮度：拖动要跟手 --------------------------------------------------
# 用户报"调亮度一卡一卡的"。原因有三个叠在一起，都要治：
#   1. 拖动时每一个 ValueChanged 都发一次写入，而一次 WMI 写 + 250ms 等待 + 回读 ≈ 0.5s；
#   2. 面板每 0.4s 重画一次，会按"EC 读回值"去纠正滑块 —— 读回值天生慢半拍，
#      于是滑块被拽回上一个值，看起来就是一顿一顿；
#   3. 百分比文字要等写入回来才更新。
# 所以：拖动中用时间闸（≥120ms 才发一次，中间的自然被合并）+ 立刻本地显示数字 +
# 回读值在拖动中/有写入在飞时不碰滑块；松手时补发最后一个值并做一次带校验的写入。
$script:BrightDragging = $false
$script:BrightSyncing = $false      # 面板自己给滑块赋值时，别把这次赋值当成用户操作再写一遍
$script:BrightLastSent = [datetime]::MinValue
$script:BrightTickMs = 120
$n.BrightSlider.Add_ValueChanged({
    if ($script:BrightSyncing) { return }             # 这一下是面板同步读回值，不是用户在拖
    $v = [int][Math]::Round($n.BrightSlider.Value)
    $script:MiscSel.Bright = $v
    $n.BrightVal.Text = '{0}%' -f $v                    # 立刻显示，不等写入
    $now = Get-Date
    if ($script:BrightDragging -and (($now - $script:BrightLastSent).TotalMilliseconds -lt $script:BrightTickMs)) { return }
    $script:BrightLastSent = $now
    Request-Misc -Sub 'bright' -Value $v
})
$n.BrightSlider.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragStartedEvent,
    [System.Windows.RoutedEventHandler]{
        $script:BrightDragging = $true
        $n.StatusText.Text = '正在调屏幕亮度…'
        $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
    })
$n.BrightSlider.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent,
    [System.Windows.RoutedEventHandler]{
        $script:BrightDragging = $false
        Request-Misc -Sub 'bright' -Value ([int][Math]::Round($n.BrightSlider.Value))   # 松手补一发（带校验）
    })

# 通用开关：名称 -> (请求 Sub, 用的 pill 表)。点击只发目标状态，读回由 sampler 做。
$switchSpec = @(
    @{ Pre = 'Tp'; Sub = 'touchpad'; Pills = $script:OnOffPills },
    @{ Pre = 'Wk'; Sub = 'winkey';   Pills = $script:EnablePills },
    @{ Pre = 'Fl'; Sub = 'fnlock';   Pills = $script:OnOffPills },
    @{ Pre = 'Ws'; Sub = 'winfn';    Pills = $script:SwapPills },
    @{ Pre = 'Nl'; Sub = 'numlock';  Pills = $script:OnOffPills }
)
foreach ($sp in $switchSpec) {
    $sub = $sp.Sub
    for ($i = 0; $i -lt $sp.Pills.Count; $i++) {
        $want = [bool]$sp.Pills[$i].On
        $n["$($sp.Pre)$i"].Add_MouseLeftButtonUp({ Request-Misc -Sub $sub -Value $want }.GetNewClosure())
    }
}
# 模式（关闭 / 静态 / 波动 / 呼吸 / 循环）——**这一段曾经被我删掉过**：
# 加方向行时手滑把整个循环替换掉了，于是模式按钮一个都没接事件，表现就是"键盘灯模式改不了"。
# 自检当时也没覆盖"点模式按钮"，所以一直是绿的。现在两件事都补上了：
#   1. 这段绑定回来了；2. 面板末尾有一份接线自检（见 Test-PanelWiring），少接一个就报出来。
for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
    $mi = $i
    $n["Led$i"].Add_MouseLeftButtonUp({
        $script:LedSel.ModeIdx = $mi
        $script:LedSel.Mode = $script:LedModePills[$mi].Key
        Request-Led
    }.GetNewClosure())
}
# 方向（只有「波动」用得到）：点一下就是一次写入，帧里的 d0 会带上方向
for ($i = 0; $i -lt $script:LedDirPills.Count; $i++) {
    $idx = [int]$script:LedDirPills[$i].Idx
    $n["Dir$i"].Add_MouseLeftButtonUp({ $script:LedSel.Dir = $idx; Request-Led }.GetNewClosure())
}

for ($i = 0; $i -lt $script:RgbPills.Count; $i++) {
    $ci = $i
    $isRainbow = [bool]$script:RgbPills[$i].ContainsKey('Rainbow')
    # picking 彩虹 clears the single-colour choice and vice versa: they are alternatives,
    # not two independent settings
    $n["Rgb$i"].Add_MouseLeftButtonUp({
        $script:LedSel.Color = $ci
        $script:LedSel.Rainbow = $isRainbow
        $script:LedSel.UseCustom = $false     # a preset swatch wins over a wheel colour
        Update-LedColorSelection
    }.GetNewClosure())
    $sw = $n["Rgb$i"]
    # Hover feedback MUST NOT change Width/Height. The window is SizeToContent="Height",
    # so a swatch that grows changes the row height, which moves the swatch out from
    # under the pointer, which fires MouseLeave, which shrinks it again - the window
    # pulsed "big, small, big" while the cursor sat next to a swatch.
    # A RenderTransform scales the visual only: layout, and therefore the window, is
    # untouched. State is kept on the element itself (Tag) so the two handlers and the
    # paint pass cannot fight over it.
    $sw.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $sw.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $sw.Tag = 'idle'
    $sw.Add_MouseEnter({
        $s = $this
        if ($s.Tag -ne 'sel') { $s.Tag = 'hover' }
        $s.RenderTransform.ScaleX = 1.18
        $s.RenderTransform.ScaleY = 1.18
    })
    $sw.Add_MouseLeave({
        $s = $this
        $s.Tag = 'idle'
        $s.RenderTransform.ScaleX = 1.0
        $s.RenderTransform.ScaleY = 1.0
    })
}
for ($i = 0; $i -lt $script:RgbBrightness.Count; $i++) {
    $bi = $i
    $n["RgbB$i"].Add_MouseLeftButtonUp({ $script:LedSel.Bright = $bi; Request-Led }.GetNewClosure())
}
for ($i = 0; $i -lt $script:LedSpeedPills.Count; $i++) {
    $si = $i
    $n["Spd$i"].Add_MouseLeftButtonUp({ $script:LedSel.Speed = $si; Request-Led }.GetNewClosure())
}

# ---- 色盘：点一下或按住拖，取任意纯色 ----------------------------------------
# The bitmap is built once and cached, so the wheel costs nothing per paint. Drag = keep
# sending while the button is held, and because the sampler only keeps ONE pending write,
# intermediate positions collapse by themselves (the last one wins) - no throttling needed.
$n.ColorWheel.Source = New-ColorWheelBitmap $script:WheelSize
$script:WheelDragging = $false
$n.ColorWheel.Add_MouseLeftButtonDown({
    $script:WheelDragging = $true
    $pt = $_.GetPosition($n.ColorWheel)
    Set-LedFromWheel $pt.X $pt.Y
})
$n.ColorWheel.Add_MouseMove({
    if (-not $script:WheelDragging) { return }
    $pt = $_.GetPosition($n.ColorWheel)
    Set-LedFromWheel $pt.X $pt.Y
})
$n.ColorWheel.Add_MouseLeftButtonUp({ $script:WheelDragging = $false })
$n.ColorWheel.Add_MouseLeave({ $script:WheelDragging = $false })
# ---- 开机自启 --------------------------------------------------------------
# 真正的逻辑在 autostart.ps1 里（独立模块文件，可以脱离界面单独跑、单独测）。
# 这里只负责把结果说给用户听。
# 教训：老版本把自启目标写死成"桌面那个 exe"，用户把桌面文件删掉以后，**每次登录都弹**
# 「Windows Script Host —— 系统找不到指定的文件 (0x80070002)」。现在改成复制到
# %LOCALAPPDATA%\ClevoHelper + 候选路径 + 失败静默（见 autostart.ps1 顶部的说明）。
. (Join-Path $PSScriptRoot 'autostart.ps1')
for ($i = 0; $i -lt $script:AutostartPills.Count; $i++) {
    $on = [bool]$script:AutostartPills[$i].On
    $n["Auto$i"].Add_MouseLeftButtonUp({ Set-Autostart -On $on }.GetNewClosure())
}
$script:AutostartOn = Get-AutostartState
# 自启开着、但快捷方式丢了或指向的 exe 没了（用户删桌面/删副本/换目录都可能）——启动时自己补回去，
# 否则下次登录就是"静默地没启动"，用户完全看不出来。自启没开就什么都不做。
if ($script:AutostartOn) {
    try {
        $rp = Repair-Autostart
        if ($rp) { Write-Dbg ('AUTOSTART repaired: target={0} exists={1} 迁移旧 vbs={2}' -f $rp.Target, $rp.TargetExists, $rp.MigratedFromVbs) }
        else { Write-Dbg ('AUTOSTART ok: target={0}' -f (Get-AutostartTarget)) }
    }
    catch { Write-Dbg ('AUTOSTART repair failed: ' + $_.Exception.Message) }
}

# 启动时收进托盘（默认开，存在 settings.json 里）—— 常驻托盘的监控工具不该每次启动都弹窗口
for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) {
    $want = [bool]$script:OnOffPills[$i].On
    $n["Tray$i"].Add_MouseLeftButtonUp({
        $script:Settings.StartToTray = $want
        Save-Settings
        $n.StatusText.Text = $(if ($want) { '之后启动会直接收进托盘（双击托盘图标或再运行一次 exe 可叫出窗口）' }
                               else { '之后启动会直接显示窗口' })
        $n.StatusText.Foreground = Get-Brush '#FF6FE38A'
    }.GetNewClosure())
}

$n.TabBtnState.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'state' })
$n.TabBtnPerf.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'perf' })
$n.TabBtnKb.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'kb' })
$n.TabBtnBatt.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'batt' })
$n.TabBtnMisc.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'misc' })
$n.TabBtnSys.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'sys' })
$n.TabBtnAbout.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'about' })

# ---- 关于页：头像 + 名片 + 信息行 -------------------------------------------
# 头像是 EXE 里的资源，启动时解包到程序目录；这里只负责把它读进来。读不到就留空 ——
# 一个缺图不该让整页打不开（SameSky 那条老规矩：读不到就说读不到，不要假装）。
$n.AboutName.Text = $script:AuthorName
$n.AboutTitle.Text = '{0} v{1}' -f $script:AppName, $script:AppVersion
$n.AboutMail.Text = $script:AuthorMail
$n.AboutTagline.Text = '蓝天 Clevo X370SN · G-Helper 风格控制中心（自包含单文件）'
$script:AvatarFile = Join-Path $PSScriptRoot 'avatar.png'
try {
    if (Test-Path -LiteralPath $script:AvatarFile) {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = 'OnLoad'
        $bi.UriSource = New-Object System.Uri($script:AvatarFile)
        $bi.EndInit()
        $bi.Freeze()
        $n.AboutAvatarBrush.ImageSource = $bi
        Write-Dbg ('about avatar loaded: ' + $script:AvatarFile)
    }
    else { Write-Dbg ('about avatar NOT found at ' + $script:AvatarFile) }
}
catch { Write-Dbg ('about avatar failed: ' + $_.Exception.Message) }

$script:UpdateBusy = $false
$script:UpdateUrl = $null

$n.AboutCheckUpdateBtn.Add_MouseLeftButtonUp({
    if ($script:UpdateBusy) { return }
    $script:UpdateBusy = $true
    $script:UpdateUrl = $null
    $n.AboutCheckUpdateT.Text = '检查中…'
    $n.AboutUpdateStatus.Foreground = Get-Brush '#FF8A93A6'
    $n.AboutUpdateStatus.Cursor = 'Arrow'
    $n.AboutUpdateStatus.ToolTip = $null
    $n.AboutUpdateStatus.Text = '正在连接 GitHub…'
    # 先把上面这句刷到屏幕上，否则同步请求会把界面连"检查中"一起冻住，看起来像没反应。
    $script:Win.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $rel = Get-LatestRelease 6000
        switch ($rel.Kind) {
            'new' {
                $script:UpdateUrl = $rel.Url
                $n.AboutUpdateStatus.Foreground = Get-Brush '#FFE38A6F'
                $n.AboutUpdateStatus.Cursor = 'Hand'
                $n.AboutUpdateStatus.Text = ('发现新版本 {0}（当前 v{1}）· 点这里打开下载页' -f $rel.Tag, $script:AppVersion)
                $n.AboutUpdateStatus.ToolTip = $rel.Url
            }
            'older' {
                $n.AboutUpdateStatus.Text = ('已是最新发布 {0}，本机 v{1} 比它更新（开发版）' -f $rel.Tag, $script:AppVersion)
            }
            'same' {
                $n.AboutUpdateStatus.Text = ('已是最新版本（v{0}）' -f $script:AppVersion)
            }
            'norelease' {
                $n.AboutUpdateStatus.Foreground = Get-Brush '#FFE38A6F'
                $n.AboutUpdateStatus.Text = '仓库里还没有发布过版本，去 Releases 页面看草稿'
            }
            'timeout' {
                $n.AboutUpdateStatus.Foreground = Get-Brush '#FFE38A6F'
                $n.AboutUpdateStatus.Text = '检查超时：网络不通或 GitHub 被挡住，稍后再试'
            }
            default {
                $n.AboutUpdateStatus.Foreground = Get-Brush '#FFE38A6F'
                $n.AboutUpdateStatus.Text = '检查失败：' + $rel.Message
            }
        }
        Write-Dbg ('update check: kind={0} remote={1} local={2}' -f $rel.Kind, $rel.Tag, $script:AppVersion)
    }
    finally {
        $script:UpdateBusy = $false
        $n.AboutCheckUpdateT.Text = '检查更新'
    }
})

# 有新版本时，点那行字直接打开发布页（只在有 URL 时才有反应）。
$n.AboutUpdateStatus.Add_MouseLeftButtonUp({
    if ($script:UpdateUrl) { try { Start-Process $script:UpdateUrl } catch { } }
})

$script:FanCustomIndex = 2   # index of the 自定义 pill
for ($i = 0; $i -lt $script:FanPills.Count; $i++) {
    $p = $script:FanPills[$i]
    if ($p.ContainsKey('Curve')) {
        $n["Fan$i"].Add_MouseLeftButtonUp({ Request-FanCurve })
    }
    else {
        $mode = [int]$p.Mode
        $n["Fan$i"].Add_MouseLeftButtonUp({
            Request-Write -Mode $mode -Kind 'fan'
            Save-MyConfig 'FanMode' $mode      # 点过的就是"我的配置"，下次开机注入
        }.GetNewClosure())
    }
}

foreach ($f in 'T2', 'D2', 'T3', 'D3') {
    $pre = 'Ct' + $f.Substring(1, 1) + $f.Substring(0, 1)   # T2 -> Ct2T, D3 -> Ct3D
    $field = $f
    $n["${pre}Minus"].Add_MouseLeftButtonUp({ Step-FanCustom $field -5 }.GetNewClosure())
    $n["${pre}Plus"].Add_MouseLeftButtonUp({ Step-FanCustom $field 5 }.GetNewClosure())
}

# ---------------------------------------------------------------- sampling ---
$sampler = {
    param($S)

    function Convert-Raw([int]$Raw) {
        if ($Raw -le 0) { return 0 }
        [int][Math]::Round(60.0 / ($Raw * 5.565217391304348E-05) * 2.0)
    }

    . $S.DchuPath          # the runspace gets its own copy of the DCHU bridge

    # keyboard LED layer (HID only - independent of DCHU)
    try {
        . $S.KbLedPath
        $ErrorActionPreference = 'Continue'   # kbled.ps1 sets 'Stop' for interactive use
        $S.KbReady = $true
    }
    catch { Add-Content -LiteralPath $S.LogPath -Value ('KBLED LOAD FAILED: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }

    # fan-curve helpers (frame builder, clamps, slopes)
    try {
        . $S.FanCurvePath
        $ErrorActionPreference = 'Continue'
    }
    catch { Add-Content -LiteralPath $S.LogPath -Value ('FANCURVE LOAD FAILED: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }

    # GPU telemetry (NVML in-process, nvidia-smi only as a fallback)
    try {
        . $S.GpuPath
        $ErrorActionPreference = 'Continue'
    }
    catch { Add-Content -LiteralPath $S.LogPath -Value ('GPU LOAD FAILED: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }

    # 杂项 tab channels (screen brightness / touchpad / NumLock - none of them DCHU)
    try {
        . $S.MiscPath
        $ErrorActionPreference = 'Continue'
    }
    catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC LOAD FAILED: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }

    function Predict-Duty($curve, [double]$t) {
        $t1 = [double]$curve.T1; $t2 = [double]$curve.T2; $t3 = [double]$curve.T3
        $d1 = [double]$curve.D1; $d2 = [double]$curve.D2; $d3 = [double]$curve.D3
        if ($t -le $t1) { return $d1 }
        if ($t -le $t2) { if ($t2 -eq $t1) { return $d2 } return $d1 + ($t - $t1) * ($d2 - $d1) / ($t2 - $t1) }
        if ($t -le $t3) { if ($t3 -eq $t2) { return $d3 } return $d2 + ($t - $t2) * ($d3 - $d2) / ($t3 - $t2) }
        if ($t3 -ge 100) { return [double]$curve.D4 }
        $v = $d3 + ($t - $t3) * (100 - $d3) / (100 - $t3)
        if ($v -gt 100) { return 100.0 }
        return $v
    }

    function Write-WmiMode([int]$Sub, [int]$Value, [int]$Page, [int]$Offset) {
        $a = [ClevoHelper.DchuApi]::SetDCHU_Data(121, [byte[]]@([byte]$Value, 0, 0, [byte]$Sub), 4)
        $buf = New-Object byte[] 256
        $buf[0] = [byte]$Value
        $b = [ClevoHelper.DchuApi]::WriteAppSettings($Page, $Offset, 1, $buf)
        # read back from the firmware, not from the return codes
        $back = (Get-AppSettingPage $Page).Bytes[$Offset]
        [pscustomobject]@{ Rc = $a; Rc2 = $b; ReadBack = [int]$back; Ok = ([int]$back -eq $Value) }
    }

    # user-facing names: the raw enum names (Custom/Performance/...) were leaking into the
    # status line, which is why the bottom row read like debug output
    $names = @{ 0 = '自动'; 1 = '最大'; 2 = '静音'; 3 = '模式3'; 4 = '模式4'; 5 = 'MaxQ'; 6 = '曲线'; 7 = '防尘'; 8 = '无声'; 9 = 'IFSC' }
    $pnames = @{ 0 = '静音'; 1 = '省电'; 2 = '性能'; 3 = '娱乐' }

    Add-Content -LiteralPath $S.LogPath -Value 'SAMPLER start' -ErrorAction SilentlyContinue
    $iters = 0
    while (-not $S.Stop) {
      try {
        $iters++

        # --- execute a queued write FIRST so a click feels responsive ---
        $req = $S.Pending
        if ($null -ne $req) {
            $S.Pending = $null
            try {
                switch ($req.Kind) {
                    'power' {
                        $r = Write-WmiMode 25 $req.Mode 1 1
                        $S.LastWrite = [pscustomobject]@{ Ok = $r.Ok; Msg = ('电源模式 → {0}  写回={1}  {2}' -f $req.Mode, $r.ReadBack, $(if ($r.Ok) { '校验通过' } else { '校验不一致!' })); At = (Get-Date) }
                    }
                    'fan' {
                        $r = Write-WmiMode 1 $req.Mode 4 5
                        $S.LastWrite = [pscustomobject]@{ Ok = $r.Ok; Msg = ('风扇模式 → {0}  写回={1}  {2}' -f $req.Mode, $r.ReadBack, $(if ($r.Ok) { '校验通过' } else { '校验不一致!' })); At = (Get-Date) }
                    }
                    'scene' {
                        # 场景 = 四件事按顺序做完，一次汇报。每一项都是本面板已有的、各自验证过
                        # 的写路径，所以这里只负责"排队"和"如实汇总"：哪一项失败就说清是哪一项，
                        # 不做"全都成功"的美化。
                        $st = New-Object System.Collections.ArrayList
                        $ok = $true
                        $r1 = Write-WmiMode 25 ([int]$req.Power) 1 1
                        [void]$st.Add(('电源={0}(写回 {1})' -f $req.Power, $r1.ReadBack))
                        if (-not $r1.Ok) { $ok = $false }
                        $r2 = Write-WmiMode 1 ([int]$req.Fan) 4 5
                        [void]$st.Add(('风扇={0}(写回 {1})' -f $req.Fan, $r2.ReadBack))
                        if (-not $r2.Ok) { $ok = $false }
                        if ($req.Kb -and $S.KbReady) {
                            try {
                                if ($req.Kb -eq 'off') {
                                    Set-LedMode -Mode 'off' -Brightness 6 -Speed 5 -Apply | Out-Null
                                }
                                else {
                                    Set-LedMode -Mode ([string]$req.Kb) -R ([int]$req.R) -G ([int]$req.G) -B ([int]$req.B) `
                                        -Brightness 6 -Speed 5 -Apply | Out-Null
                                }
                                [void]$st.Add(('键盘灯={0}' -f $req.Kb))
                            }
                            catch { [void]$st.Add('键盘灯=失败'); $ok = $false }
                        }
                        if ([int]$req.Bright -ge 0) {
                            try {
                                [void](Set-ScreenBrightness -Percent ([int]$req.Bright) -Apply -Quick)
                                [void]$st.Add(('亮度={0}%' -f $req.Bright))
                            }
                            catch { [void]$st.Add('亮度=失败'); $ok = $false }
                        }
                        $S.SceneIndex = [int]$req.Index
                        if ([int]$req.Bright -ge 0) { $S.BrightWrote = $true }
                        $tag = $(if ($req.Auto) { '（插拔电源自动）' } else { '' })
                        $S.LastWrite = [pscustomobject]@{
                            Ok = $ok; At = (Get-Date)
                            Msg = ('场景「{0}」{1}：{2}' -f $req.Label, $tag, ($st -join ' · '))
                        }
                    }
                    'restore' {
                        if ($null -eq $S.StartState) { throw 'no start state was captured' }
                        $r1 = Write-WmiMode 25 $S.StartState.PowerMode 1 1
                        $r2 = Write-WmiMode 1 $S.StartState.FanMode 4 5
                        # a staged graphics mode is part of "the session", so undo it too -
                        # but say so plainly, because it can only be confirmed after a reboot
                        $g = ''
                        if ($S.GpuStaged -and $S.GpuStaged -ne $S.StartState.GpuMode) {
                            $rg = Set-GpuMode -Mode $S.StartState.GpuMode -Apply -Supported $S.GpuSupported
                            $S.GpuStaged = $S.StartState.GpuMode
                            $g = '；显卡已暂存回 {0}（重启后生效）' -f $rg.ModeName
                        }
                        # keyboard lighting is a write this project added, so it gets a
                        # rollback path as well: re-apply the mode/colour captured on open
                        $kb = ''
                        if ($S.KbReady -and $S.LedStartCaptured -and $S.LedStartMode) {
                            $cur = Get-LedModeFromAppSettings
                            if ($cur.Mode -ne $S.LedStartMode) {
                                $c0 = if ($S.LedStartColor) { $S.LedStartColor } else { @(255, 255, 255) }
                                Set-LedMode -Mode $S.LedStartMode -R $c0[0] -G $c0[1] -B $c0[2] -Brightness 6 -Speed 5 -Apply | Out-Null
                                $kb = '；键盘灯已恢复为 {0}' -f $S.LedStartMode
                            }
                        }
                        # 亮度也要还原。场景会改亮度，而"恢复初始"原先只管电源/风扇/灯 ——
                        # 2026-10-28 自检实测：场景把亮度设到 55%，恢复初始之后屏幕还停在 55%，
                        # 用户看到的"恢复初始"名不副实。这里补上（读不到就算了，不阻断其它还原）。
                        $br = ''
                        if ($null -ne $S.StartState.Bright -and [int]$S.StartState.Bright -ge 0) {
                            try {
                                [void](Set-ScreenBrightness -Percent ([int]$S.StartState.Bright) -Apply -Quick)
                                $br = '；亮度已恢复为 {0}%' -f $S.StartState.Bright
                            }
                            catch { $br = '；亮度还原失败' }
                        }
                        $S.LastWrite = [pscustomobject]@{ Ok = ($r1.Ok -and $r2.Ok); Msg = ('已恢复初始：电源={0} 风扇={1}{2}{3}{4}' -f $r1.ReadBack, $r2.ReadBack, $g, $kb, $br); At = (Get-Date) }
                    }
                    'gpu' {
                        # byte-identical to ControlCenter30.Window1.GPUSwitch_new(byte):
                        # SetDCHU_DataEx(4, { 0x16, mode, 0 ... }, 256, out). The value is
                        # consumed by the BIOS at POST, so this CANNOT be verified online -
                        # report it as staged, never as "done".
                        $r = Set-GpuMode -Mode $req.Mode -Apply -Supported $S.GpuSupported
                        $S.GpuStaged = $req.Mode
                        # 暂存成功就给界面留一张"重启申请"：显卡模式是 pre-boot 值，不重启不生效。
                        # 原厂 CC 是直接 shutdown -f -r -t 0 替你重启；我们只**申请**，重启与否由用户点。
                        $S.RebootAsk = [pscustomobject]@{ Mode = [int]$req.Mode; At = (Get-Date) }
                        $S.LastWrite = [pscustomobject]@{
                            Ok = $true; At = (Get-Date)
                            Msg = ('显卡模式已暂存「{0}」→ 重启后生效；当前生效仍是 {1}。这一步无法在线校验（原厂 CC 同样不校验，它写完直接强制重启）' -f `
                                $r.ModeName, $script:GpuModeName[$r.BeforeActive])
                        }
                    }
                    'curve' {
                        # Duties arrive in PERCENT (see $script:FanCustom / Step-FanCustom);
                        # Test-FanCurve clamps in percent and New-FanCurveFrame converts to
                        # raw with the vendor's own round(pct/100*255).
                        $fans = Test-FanCurve -Fans @(
                            [pscustomobject]@{ Fan = 'CPU';  T1 = 40; T2 = $req.T2; T3 = $req.T3; T4 = 100; D1 = $req.D1; D2 = $req.D2; D3 = $req.D3; D4 = 100 },
                            [pscustomobject]@{ Fan = 'GPU1'; T1 = 40; T2 = $req.T2; T3 = $req.T3; T4 = 100; D1 = $req.D1; D2 = $req.D2; D3 = $req.D3; D4 = 100 },
                            [pscustomobject]@{ Fan = 'GPU2'; T1 = 0; T2 = 0; T3 = 0; T4 = 0; D1 = 0; D2 = 0; D3 = 0; D4 = 0 }
                        )
                        $frame = New-FanCurveFrame $fans
                        # The 4th argument is the native OUTPUT BUFFER: it must be a byte[]
                        # (native writes a whole buffer through it). This used to be
                        # `[ref]$out` with a single byte, which threw
                        # "Cannot convert PSReference[Byte] to System.Byte[]" on EVERY write -
                        # the real reason the old 自定义/曲线 buttons appeared to do nothing.
                        $outBuf = New-Object byte[] 256
                        $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(14, $frame, 256, $outBuf)
                        if ($rc -ne 14) { throw ('block-14 write rejected, rc=0x{0:X}' -f $rc) }

                        # DO NOT mirror this into AppSettings page 4.
                        # Reverse-engineered from the vendor's own fan app
                        # (FanSpeedSetting.exe -> Interface_FanTable.WriteEC_Fan1_Fan2_table):
                        # saving a curve calls ONLY the EC (SetWMIPackageEx(4, frame) with
                        # frame[0]=41 and 112-byte per-fan records at [16]/[128]) - it never
                        # touches page 4. Our old full-page mirror did, and writing page 4
                        # makes the EC reload its runtime table from a page-4 layout we do not
                        # have byte-exact: measured result was T2 = T1+1 and T3 = T2
                        # (i.e. `40,41,61` instead of `40,61,88`), which silently made the
                        # fans follow a curve nobody asked for.
                        # The mode switch uses the M2-verified path (WMI 1 + read-back) rather
                        # than the old ad-hoc SetDCHU_Data(121) + page-4 byte poke.
                        $w = Write-WmiMode 1 6 4 5     # fan mode -> Custom (6), verified read-back
                        if (-not $w.Ok) { throw ('切到自定义模式失败，写回={0}' -f $w.ReadBack) }

                        # READ-BACK against block 13 - the runtime table the EC is executing.
                        # This step used to be missing entirely: the old handler reported
                        # success because SetDCHU_DataEx returned 14, i.e. it reported "the
                        # call was accepted", not "the fans changed". That is precisely why
                        # the old 自定义/曲线 pills looked like they did nothing.
                        # ~450 ms is the latch time measured in the M3 work.
                        Start-Sleep -Milliseconds 450
                        $b13v = (Get-WmiPackage 13).Bytes
                        $gotT = @([int]$b13v[16], [int]$b13v[18], [int]$b13v[20])
                        $gotD = @([int]$b13v[17], [int]$b13v[19], [int]$b13v[21])
                        # expected duties: percent -> raw, the same conversion the frame used
                        $expD1 = Convert-DutyPctToRaw $fans[0].D1
                        $expD2 = Convert-DutyPctToRaw $fans[0].D2
                        $expD3 = Convert-DutyPctToRaw $fans[0].D3
                        $ok = ($gotT[0] -eq $fans[0].T1 -and $gotT[1] -eq $fans[0].T2 -and $gotT[2] -eq $fans[0].T3 -and
                               $gotD[0] -eq $expD1 -and $gotD[1] -eq $expD2 -and $gotD[2] -eq $expD3)
                        $gotPct = @($gotD | ForEach-Object { [int][Math]::Round(100.0 * $_ / 255) })
                        $S.Hist = @()   # restart the health window
                        $S.LastWrite = [pscustomobject]@{
                            Ok = $ok; At = (Get-Date)
                            Msg = ('曲线「{0}」{1}：节点1 {2}C/{3}%（EC 固定）· 节点2 {4}C/{5}% · 节点3 {6}C/{7}% · 节点4 100C/100% ｜ 读回 {8}C/{9}% {10}C/{11}% {12}C/{13}%' -f `
                                $req.Label, $(if ($ok) { '写入并读回一致' } else { '写入后读回不一致!' }),
                                $fans[0].T1, $fans[0].D1, $fans[0].T2, $fans[0].D2, $fans[0].T3, $fans[0].D3,
                                $gotT[0], $gotPct[0], $gotT[1], $gotPct[1], $gotT[2], $gotPct[2])
                        }
                    }
                    'led' {
                        # Vendor per-key mode types. Set-LedMode sends the vendor's own frame
                        # (see kbled.ps1 $script:LedModes) and mirrors mode/colour/speed into
                        # AppSetting page 2 - the same bytes the vendor's UI reads - which is
                        # then read back. The LED hardware itself reports nothing, so a
                        # correct read-back means "the setting is stored", not "I saw the
                        # light": that distinction is kept in the message on purpose.
                        if (-not $S.KbReady) { throw 'keyboard LED layer not loaded' }
                        $r = Set-LedMode -Mode $req.Mode -Direction $req.Dir `
                            -R $req.R -G $req.G -B $req.B -R2 $req.R2 -G2 $req.G2 -B2 $req.B2 `
                            -Brightness $req.Bright -Speed $req.Speed -Random:$req.Rainbow -Apply
                        $back = Get-LedModeFromAppSettings
                        $ok = ($back.Mode -eq $req.Mode)
                        $colTxt = if ($req.Rainbow) { '彩虹（多色）' }
                                  elseif ($req.Mode -in @('off', 'random', 'cycle')) { '—' }
                                  elseif ($req.Mode -eq 'ripple') { '用 EC 里存的颜色' }
                                  else { 'R{0} G{1} B{2}' -f $req.R, $req.G, $req.B }
                        $colBack = if ($back.Color) { 'R{0} G{1} B{2}' -f $back.Color[0], $back.Color[1], $back.Color[2] } else { '—' }
                        $S.LastWrite = [pscustomobject]@{
                            Ok = $ok; At = (Get-Date)
                            Msg = ('键盘灯 → {0} 色 {1} 亮度 {2}/10 速度 {3}/10 ｜ AppSettings 回读：模式={4} 色={5} {6}（灯色无软件读回，需肉眼确认）' -f `
                                $req.ModeLabel, $colTxt, $req.Bright, $req.Speed, `
                                $(if ($back.Mode) { $back.Mode } else { '(无)' }), $colBack, $(if ($ok) { '✓' } else { '✗ 不一致' }))
                        }
                    }
                    'misc' {
                        # The 杂项 tab. Four unrelated channels behind one kind, so the
                        # message always names what was written AND what was read back.
                        $ok = $false; $msg = ''
                        switch ($req.Sub) {
                            'charger' {
                                $v = $req.Value
                                if ($v.Mode -eq 'max') {
                                    $r = Set-FlexiCharger -Enabled $false -Apply
                                    $msg = '电池充电 → 最大电量（不限制）｜EC 回读：{0}' -f $r.After
                                }
                                else {
                                    $r = Set-FlexiCharger -Enabled $true -Start ([int]$v.Start) -Stop ([int]$v.Stop) -Apply
                                    $msg = '电池充电 → {0}｜EC 回读：{1}' -f $(if ($v.Mode -eq 'rec') { '推荐' } else { '自定义' }), $r.After
                                }
                                $ok = $r.Ok
                            }
                            'start' {
                                $v = $req.Value
                                $r = Set-FlexiCharger -Enabled $true -Start ([int]$v.Start) -Stop ([int]$v.Stop) -Apply
                                $ok = $r.Ok
                                $msg = '充电开始 → {0}%（停止 {1}%）｜EC 回读：{2}' -f $v.Start, $v.Stop, $r.After
                            }
                            'stop' {
                                $v = $req.Value
                                $r = Set-FlexiCharger -Enabled $true -Start ([int]$v.Start) -Stop ([int]$v.Stop) -Apply
                                $ok = $r.Ok
                                $msg = '充电停止 → {0}%（开始 {1}%）｜EC 回读：{2}' -f $v.Stop, $v.Start, $r.After
                            }
                            'bright' {
                                # 用户自己调过亮度之后，"开机时的亮度"就不再是不可能被改变的历史，
                                # 后面别再补记基线（否则会把用户的新值当成初始值）
                                $S.BrightWrote = $true
                                # 拖动中的中间值只写不校验（后面还排着新值呢），松手那一发才校验。
                                # 否则每次拖动都要等 250ms 稳定 + 一次回读，手感就是"一卡一卡"。
                                $quick = ($null -ne $S.Pending -and $S.Pending.Sub -eq 'bright')
                                $r = Set-ScreenBrightness -Percent ([int]$req.Value) -Apply -Quick:$quick
                                if ($quick) {
                                    $ok = $true
                                    $msg = '屏幕亮度 → {0}%（拖动中，松手后校验）' -f $req.Value
                                }
                                else {
                                    $ok = $r.Ok
                                    $msg = '屏幕亮度 → {0}%｜WMI 回读：{1}%' -f $req.Value, $r.After
                                }
                            }
                            'touchpad' {
                                $r = Set-TouchPadState -Enabled ([bool]$req.Value) -Apply
                                $ok = $r.Ok
                                $msg = '触控板 → {0}｜注册表回读：Enabled={1}（手指才能确认是否真的切换了）' -f `
                                    $(if ($req.Value) { '开' } else { '关' }), $r.After
                            }
                            'numlock' {
                                $r = Set-NumLockState -On ([bool]$req.Value) -Apply
                                $ok = $r.Ok
                                $msg = '数字键盘 → {0}｜会话回读：NumLock={1}' -f $(if ($req.Value) { '开' } else { '关' }), $r.After
                            }
                            'winkey' {
                                $r = Set-KeyboardSetting -WinKey ([bool]$req.Value) -Apply
                                $ok = $r.Ok
                                $msg = 'Win 键 → {0}｜帧 {1} 回读 {2}' -f $(if ($req.Value) { '启用' } else { '禁用' }), $r.Frame, $r.After
                            }
                            'fnlock' {
                                $r = Set-KeyboardSetting -FnLock ([bool]$req.Value) -Apply
                                $ok = $r.Ok
                                $msg = 'FnLock → {0}｜帧 {1} 回读 {2}' -f $(if ($req.Value) { '开' } else { '关' }), $r.Frame, $r.After
                            }
                            'winfn' {
                                $r = Set-KeyboardSetting -WinFnSwap ([bool]$req.Value) -Apply
                                $ok = $r.Ok
                                $msg = 'Win/Fn 交换 → {0}｜帧 {1} 回读 {2}' -f $(if ($req.Value) { '交换' } else { '常规' }), $r.Frame, $r.After
                            }
                            default { throw ('unknown misc sub-command: ' + $req.Sub) }
                        }
                        $S.LastWrite = [pscustomobject]@{ Ok = $ok; Msg = ($msg + $(if ($ok) { '  ✓' } else { '  ✗ 读回不一致' })); At = (Get-Date) }
                        $S.MiscDirty = $true   # refresh the tab's state on the next loop
                    }
                    'rgb' {
                        # legacy single-colour path, still used by -SelfTest
                        if (-not $S.KbReady) { throw 'keyboard LED layer not loaded' }
                        if ($req.R -lt 0) {
                            Set-LedBrightness -Level $req.Brightness -Speed 1 -Apply | Out-Null
                            $S.LastWrite = [pscustomobject]@{ Ok = $true; Msg = ('键盘灯亮度 → {0}/10' -f $req.Brightness); At = (Get-Date) }
                        }
                        else {
                            if ($req.R -eq 0 -and $req.G -eq 0 -and $req.B -eq 0) {
                                Clear-Led -Apply | Out-Null
                                $S.LastWrite = [pscustomobject]@{ Ok = $true; Msg = '键盘灯已关闭'; At = (Get-Date) }
                            }
                            else {
                                Set-LedBrightness -Level 10 -Speed 1 -Apply | Out-Null
                                Set-LedAllColor -R $req.R -G $req.G -B $req.B -Apply 6>$null | Out-Null
                                $S.LastWrite = [pscustomobject]@{ Ok = $true; Msg = ('键盘灯 → R{0} G{1} B{2}（已 ClearColor 并重绘全部键）' -f $req.R, $req.G, $req.B); At = (Get-Date) }
                            }
                        }
                    }
                }
            }
            catch {
                $S.LastWrite = [pscustomobject]@{ Ok = $false; Msg = ('写入失败: ' + $_.Exception.Message); At = (Get-Date) }
            }
            # 启动注入的结果必须落盘：开机那次到底写没写、成功没有，以前日志里查不到
            # （LastWrite 只在界面和自检里被读），2026-10-06 这次排查就卡在这里。
            if ($req.Startup -and $S.LastWrite) {
                Add-Content -LiteralPath $S.LogPath -Value ('STARTUP {0}: ok={1}  {2}' -f $req.Kind, $S.LastWrite.Ok, $S.LastWrite.Msg) -ErrorAction SilentlyContinue
            }
        }

        $snap = [ordered]@{ At = (Get-Date) }

        try {
            $b = (Get-WmiPackage 12).Bytes
            $snap.CpuTemp = [int]$b[18]
            $snap.GpuTemp = [int]$b[21]
            $snap.CpuFanRpm = Convert-Raw (([int]$b[2] * 256) + $b[3])
            $snap.GpuFanRpm = Convert-Raw (([int]$b[4] * 256) + $b[5])
            $snap.CpuFanDuty = [int][Math]::Round($b[16] * 100 / 255)
            $snap.GpuFanDuty = [int][Math]::Round($b[19] * 100 / 255)
            $p4 = (Get-AppSettingPage 4).Bytes
            $p1 = (Get-AppSettingPage 1).Bytes
            $fm = [int]$p4[5]; $pm = [int]$p1[1]
            $snap.FanMode = $fm
            $snap.PowerMode = $pm
            $snap.FanModeName = if ($names.ContainsKey($fm)) { $names[$fm] } else { "Mode $fm" }
            $snap.PowerModeName = if ($pnames.ContainsKey($pm)) { $pnames[$pm] } else { "Mode $pm" }
            $snap.FanOffset = [int]$p4[7]
            $snap.Curve = (Get-ClevoFanCurve).Curves | Where-Object Fan -eq 'CPU'

            # block 13 (EEVT) echoes the RUNTIME fan table the EC is actually executing,
            # in RAW 0-255 units. This is the correct reference for the health check and
            # it is also how a curve write is verified.
            $b13 = (Get-WmiPackage 13).Bytes
            $snap.RuntimeT = @([int]$b13[16], [int]$b13[18], [int]$b13[20], [int]$b13[22])
            $snap.RuntimeD = @(
                [int][Math]::Round(100 * $b13[17] / 255), [int][Math]::Round(100 * $b13[19] / 255),
                [int][Math]::Round(100 * $b13[21] / 255), [int][Math]::Round(100 * $b13[23] / 255)
            )
            $snap.RuntimeRaw = @([int]$b13[17], [int]$b13[19], [int]$b13[21], [int]$b13[23])
            try {
                $gm = Get-GpuMode
                $snap.GpuMode = $gm.Mode
                $snap.GpuModeName = $gm.ModeName
                $snap.GpuMask = $gm.Mask
                # a staged change is invisible to the EC until POST, so the only record of
                # it is this session's own memory - carry it into every snapshot
                $snap.GpuStaged = [int]$S.GpuStaged
            }
            catch { $snap.GpuMode = $null; $snap.GpuModeName = ''; $snap.GpuStaged = 0 }
            # keyboard LED state, read back from the EC's own AppSettings copy rather than
            # from "what we last clicked" - so the strip reflects reality even if the mode
            # was changed by something else (Fn hotkey, factory app).
            try {
                if ($S.KbReady) {
                    $lm = Get-LedModeFromAppSettings
                    $snap.LedMode = [string]$lm.Mode
                    $snap.LedColor = $lm.Color
                    # remember the keyboard lighting as it was when the panel opened, so
                    # [恢复初始] can put it back like it does for power/fan/GPU - every
                    # write this project adds is supposed to be undoable from the UI.
                    if (-not $S.LedStartCaptured) {
                        $S.LedStartMode = [string]$lm.Mode
                        $S.LedStartColor = $lm.Color
                        $S.LedStartCaptured = $true
                    }
                }
                else { $snap.LedMode = ''; $snap.LedColor = $null }
            }
            catch { $snap.LedMode = '' }

            # ---- 亮度基线补记 ----
            # 开机那一瞬间 WMI 还没热身，直接读亮度会抛（日志里就是 panel start state: bright=-1），
            # 而"恢复初始"要靠这个值把场景改过的亮度还原回去。所以在这里每秒补读一次，
            # 拿到就记进 StartState；用户一旦自己调过亮度（BrightWrote）就不再补记，免得把
            # 他刚设的值当成"初始值"还原。
            if ($null -ne $S.StartState -and [int]$S.StartState.Bright -lt 0 -and -not $S.BrightWrote) {
                $S.BrightTick = [int]$S.BrightTick + 1
                if ($S.BrightTick -ge 4) {
                    $S.BrightTick = 0
                    try {
                        $bv = [int](Get-ScreenBrightness).Percent
                        if ($bv -ge 0) {
                            $S.StartState.Bright = $bv
                            Add-Content -LiteralPath $S.LogPath -Value ('BRIGHT baseline captured late: {0}%' -f $bv) -ErrorAction SilentlyContinue
                        }
                    }
                    catch { }
                }
            }

            # ---- 一键场景的自动切换：只盯"插拔电源"这一个事件 ----
            # 读数用 Win32_Battery（复用 Get-BatteryState），但**不能每轮都查**：那是一次
            # WMI 查询，250ms 一次会把采样线程拖慢（本项目测过 WMI 读是采样里最贵的一档）。
            # 供电状态变化是以秒计的事，所以攒够 8 轮（约 2 秒）查一次就够。
            # 打开开关后的第一轮只记基线（OnAcLast 为 null），不动任何东西 —— 见 Set-SceneAuto。
            if ($S.SceneAuto) {
                $S.AcTick = [int]$S.AcTick + 1
                if ($S.AcTick -ge 8) {
                    $S.AcTick = 0
                    try {
                        $bs = Get-BatteryState
                        if ($bs.Supported) {
                            $onAc = [bool]$bs.OnAc
                            if ($null -eq $S.OnAcLast) {
                                $S.OnAcLast = $onAc
                                Add-Content -LiteralPath $S.LogPath -Value ('SCENE auto baseline: onAc={0}' -f $onAc) -ErrorAction SilentlyContinue
                            }
                            elseif ($S.OnAcLast -ne $onAc) {
                                $S.OnAcLast = $onAc
                                $pick = [int]$(if ($onAc) { $S.SceneOnAc } else { $S.SceneOnBat })
                                if ($null -eq $S.Pending -and $pick -ge 0 -and $pick -lt $S.SceneDefs.Count) {
                                    $d = $S.SceneDefs[$pick]
                                    # 槽空才发：槽里已有的那条是用户刚点的，不能顶掉
                                    $S.Pending = [pscustomobject]@{
                                        Kind = 'scene'; Index = $pick; Label = [string]$d.Label
                                        Power = [int]$d.Power; Fan = [int]$d.Fan; Kb = [string]$d.Kb
                                        R = [int]$d.R; G = [int]$d.G; B = [int]$d.B; Bright = [int]$d.Bright
                                        Auto = $true; Startup = $false; At = (Get-Date)
                                    }
                                    Add-Content -LiteralPath $S.LogPath -Value ('SCENE auto queued: onAc={0} → {1}' -f $onAc, $d.Label) -ErrorAction SilentlyContinue
                                }
                            }
                        }
                    }
                    catch { Add-Content -LiteralPath $S.LogPath -Value ('SCENE ac probe failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                }
            }

            # ---- 杂项 tab: read only while it is on screen, roughly once a second ----
            # The gate is ELAPSED TIME, not an iteration count. It used to be `$iters % 4`,
            # which assumed a 250 ms loop: a real cycle costs ~600 ms (WMI + Get-Counter +
            # GPU + DCHU), so every 4th iteration meant every ~3 s and the 杂项 tab sat blank
            # for seconds after being opened. Measured with the self-test log, not assumed.
            # $S.MiscDirty is set by a write, so a click is reflected on the very next loop.
            # EACH CHANNEL IS WRAPPED SEPARATELY: one unavailable channel (e.g. a WMI class
            # missing on another SKU) must leave its own row blank, not wipe the whole tab.
            $miscDue = ($null -eq $S.MiscLastRead) -or (((Get-Date) - $S.MiscLastRead).TotalSeconds -ge 1.0)
            if ($S.WantMisc -and ($S.MiscDirty -or $miscDue)) {
                $S.MiscDirty = $false
                $S.MiscLastRead = Get-Date
                $mi = [ordered]@{}
                try {
                    $fc = Get-FlexiCharger
                    $mi.ChargerEnabled = [bool]$fc.Enabled
                    $mi.ChargerStart = [int]$fc.Start
                    $mi.ChargerStop = [int]$fc.Stop
                    $mi.ChargerStartOptions = @($fc.StartOptions)
                    $mi.ChargerStopOptions = @($fc.StopOptions)
                }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC flexicharger read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                try {
                    $ks = Get-KeyboardSetting
                    $mi.FnLock = [bool]$ks.FnLock
                    $mi.WinKey = [bool]$ks.WinKey
                    $mi.WinFnSwap = [bool]$ks.WinFnSwap
                }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC keyboard-setting read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                try { $mi.Bright = (Get-ScreenBrightness).Percent }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC brightness read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                try { $mi.TouchPad = (Get-TouchPadState).Enabled }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC touchpad read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                try { $mi.NumLock = (Get-NumLockState).On }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC numlock read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                try { $mi.Battery = Get-BatteryState }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC battery read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                $snap.Misc = [pscustomobject]$mi
                # 这次是完整读（含充电窗口）—— 启动时那个"必须读一次"的需求可以撤了
                $S.NeedFullMisc = $false
                if (-not $S.MiscLogged) {
                    $S.MiscLogged = $true
                    Add-Content -LiteralPath $S.LogPath -Value ('MISC first read: bright={0} touchpad={1} numlock={2} charger={3}/{4} enabled={5} winKey={6} fnLock={7} winFn={8}' -f `
                        $mi.Bright, $mi.TouchPad, $mi.NumLock, $mi.ChargerStart, $mi.ChargerStop, $mi.ChargerEnabled, $mi.WinKey, $mi.FnLock, $mi.WinFnSwap) -ErrorAction SilentlyContinue
                }
            }
            elseif ($S.WantBright -and ((($null -eq $S.BrightLastRead) -or (((Get-Date) - $S.BrightLastRead).TotalSeconds -ge 1.0)))) {
                # 状态页只要亮度（滑杆在那里）。单独读这一个值，其余字段沿用上一次读的 ——
                # 为了一个数字把触控板/电池/充电器都拉一遍，会把采样周期拖慢。
                $S.BrightLastRead = Get-Date
                try {
                    $bNow = (Get-ScreenBrightness).Percent
                    if ($S.LastMisc) { $S.LastMisc.Bright = $bNow }
                    else { $S.LastMisc = [pscustomobject]@{ Bright = $bNow } }
                    if (-not $S.BrightLogged) {
                        $S.BrightLogged = $true
                        Add-Content -LiteralPath $S.LogPath -Value ('MISC bright-only read: {0} (lastMisc={1})' -f $bNow, $(if ($S.LastMisc) { 'set' } else { 'null' })) -ErrorAction SilentlyContinue
                    }
                }
                catch { Add-Content -LiteralPath $S.LogPath -Value ('MISC brightness(only) read failed: ' + $_.Exception.Message) -ErrorAction SilentlyContinue }
                $snap.Misc = $S.LastMisc
            }
            else { $snap.Misc = $S.LastMisc }   # reuse the previous read instead of showing blanks
            if ($snap.Misc) { $S.LastMisc = $snap.Misc }
            $snap.Err = ''

            # Fan-curve health. Only meaningful in Custom/curve mode: Auto has its own logic
            # (measured 100% where the persisted curve says ~50%), so judging Auto would
            # always look "broken".
            #
            # ONE-SIDED on purpose. The EC does NOT evaluate the curve at the temperature
            # this panel reads (block 12): measured proof - at the SAME reported 84 C, the
            # 原厂 table gives 77% duty and the 强冷 table gives 100%, and switching back
            # returns to 77%. Both are consistent with the EC controlling on a HIGHER
            # internal temperature (~93 C), so the linear prediction from block 12 lands
            # ~20 points low and an absolute-difference test cried "曲线异常 23%" on a
            # perfectly healthy curve. What actually matters for safety is only the
            # under-cooling direction: measured BELOW the table = the fans are doing less
            # than the table promises.
            if ($snap.FanMode -eq 6) {
                $rt = [pscustomobject]@{
                    T1 = $snap.RuntimeT[0]; D1 = $snap.RuntimeD[0]
                    T2 = $snap.RuntimeT[1]; D2 = $snap.RuntimeD[1]
                    T3 = $snap.RuntimeT[2]; D3 = $snap.RuntimeD[2]
                    D4 = $snap.RuntimeD[3]
                }
                $exp = Predict-Duty $rt $snap.CpuTemp
                $S.Hist = @($S.Hist) + , ([double]$snap.CpuFanDuty - $exp)
                if ($S.Hist.Count -gt 8) { $S.Hist = @($S.Hist[($S.Hist.Count - 8)..($S.Hist.Count - 1)]) }
                if ($S.Hist.Count -ge 5) {
                    $tail = @($S.Hist[($S.Hist.Count - 5)..($S.Hist.Count - 1)])
                    $m = ($tail | Measure-Object -Average).Average
                    $snap.CurveErr = [Math]::Round($m, 1)
                    if ($m -lt -12) { $snap.CurveHealth = 'bad' } else { $snap.CurveHealth = 'ok' }
                }
                else { $snap.CurveHealth = 'measuring' }
            }
            else { $snap.CurveHealth = 'na'; $S.Hist = @() }
        }
        catch {
            $snap.Err = 'DCHU: ' + $_.Exception.Message
            # one-shot repair hint: the DCHU driver/service is the only prerequisite this app
            # cannot carry in-process, so the panel says out loud how to put it back.
            if (-not $S.DchuHintShown) {
                $S.DchuHintShown = $true
                $S.LastWrite = [pscustomobject]@{
                    Ok = $false; At = (Get-Date)
                    Msg = 'DCHU 通道读不到数据（温度/风扇/模式会失效）。修复：运行 ClevoHelper.exe --install-driver（会弹 UAC，用自带的驱动包重装 ACPI 桥驱动），完成后重启面板。'
                }
            }
        }

        # Performance counters, kept ALIVE across iterations.
        # This used to be `Get-Counter $paths -MaxSamples 1`. % Processor Performance,
        # % Processor Utility and RAPL Power are all RATE counters: PDH cannot answer them
        # from one sample, so Get-Counter takes two with its own ~1 s gap. That single call
        # was therefore the panel's whole refresh period - measured 0.7 Hz (a 1.4 s cycle) in
        # the self-test log. Reusing the counter objects lets NextValue() pair this cycle's
        # sample with the previous cycle's, which costs microseconds and no wait.
        # The first NextValue() of a rate counter always returns 0, so a 0 is treated as
        # "no reading yet" instead of being published as a real value.
        try {
            if (-not $S.PerfCounters) { $S.PerfCounters = @{} }
            function Get-PerfValue([string]$cat, [string]$name, [string]$inst) {
                $key = '{0}|{1}|{2}' -f $cat, $name, $inst
                if (-not $S.PerfCounters.ContainsKey($key)) {
                    try { $S.PerfCounters[$key] = New-Object System.Diagnostics.PerformanceCounter($cat, $name, $inst, $true) }
                    catch { $S.PerfCounters[$key] = $false }
                }
                $pc = $S.PerfCounters[$key]
                if (-not $pc) { return $null }
                try { return [double]$pc.NextValue() } catch { return $null }
            }

            $perf = Get-PerfValue 'Processor Information' '% Processor Performance' '_Total'
            if ($null -ne $perf -and $perf -gt 0) {
                $snap.CpuMhz = [int][Math]::Round($S.BaseMhz * $perf / 100)
            }
            $memFree = Get-PerfValue 'Memory' 'Available MBytes' ''
            if ($null -ne $memFree -and $memFree -gt 0) { $snap.RamFreeMB = [int]$memFree }
            $rapl = Get-PerfValue 'Energy Meter' 'Power' 'rapl_package0_pkg'
            if ($null -ne $rapl -and $rapl -gt 0) { $snap.CpuWatts = [Math]::Round($rapl / 1000.0, 1) }
            # the start-up probe decided which utilisation counter this machine has; fall back
            # to the classic one if the probe failed
            if ($S.CpuUtilCounter) {
                $util = Get-PerfValue 'Processor Information' '% Processor Utility' '_Total'
                if ($null -eq $util -or $util -le 0) { $util = Get-PerfValue 'Processor Information' '% Processor Time' '_Total' }
            }
            else { $util = Get-PerfValue 'Processor Information' '% Processor Time' '_Total' }
            if ($null -ne $util -and $util -gt 0) {
                $v = [int][Math]::Round($util)
                if ($v -lt 0) { $v = 0 } elseif ($v -gt 100) { $v = 100 }
                $snap.CpuUtil = $v
            }
        }
        catch { }

    # GPU telemetry: NVML inside this process (nvml.dll ships with the driver). No
    # nvidia-smi subprocess, so no dependency on that executable or on its location.
    try {
        $S.Gpu = Get-GpuTelemetry
        if ($S.Gpu -and $S.Gpu.Ok) {
            if ($null -ne $S.Gpu.Watts) { $snap.GpuWatts = [double]$S.Gpu.Watts }
            if ($null -ne $S.Gpu.Mhz) { $snap.GpuMhz = [int]$S.Gpu.Mhz }
            if ($null -ne $S.Gpu.Util) { $snap.GpuUtil = [int]$S.Gpu.Util }
            $snap.GpuSensor = $S.Gpu.Sensor
            if ($iters -eq 1) {
                Add-Content -LiteralPath $S.LogPath -Value ('gpu telemetry source: ' + $S.Gpu.Sensor) -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }

        try {
            $snap.Volumes = @([System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name  = $_.Name.TrimEnd('\')
                        Label = "$($_.VolumeLabel)"
                        Total = [double]$_.TotalSize
                        Free  = [double]$_.AvailableFreeSpace
                    }
                })
        }
        catch { $snap.Volumes = @() }

        $S.Snapshot = [pscustomobject]$snap
        $S.LastIters = $iters
        # Real loop rate. The status line used to claim a hard-coded "4 Hz" while a cycle
        # actually costs ~0.5-0.7 s (WMI + Get-Counter + GPU + DCHU), i.e. ~1.5 Hz. Measured
        # over a rolling second, so what is shown is what the panel is really doing.
        $now = Get-Date
        if ($null -eq $S.RateAt) { $S.RateAt = $now; $S.RateBase = $iters }
        elseif (($now - $S.RateAt).TotalSeconds -ge 1.0) {
            $S.RateHz = [Math]::Round(($iters - $S.RateBase) / ($now - $S.RateAt).TotalSeconds, 1)
            $S.RateAt = $now; $S.RateBase = $iters
        }
        if (($iters % 40) -eq 0) { [System.GC]::Collect() }
      }
      catch {
        Add-Content -LiteralPath $S.LogPath -Value ("SAMPLER-ERR " + $_.Exception.ToString()) -ErrorAction SilentlyContinue
      }
      Start-Sleep -Milliseconds 250
    }
}

Start-Sampler

# ------------------------------------------------------------------- paint ---
# Explicit brush conversion: do not rely on implicit string -> Brush coercion in
# property assignments, it can fail silently inside event handlers.
$script:BrushCache = @{}

Update-Panel
$null = Test-Sampler -Silent   # if the sampler is already dead, recover before the first paint tick

# ------------------------------------------------------------------- tray ----
# A control centre is expected to live in the tray。**– 和 × 都是"收进托盘"**（用户要求：
# 点 × 不该把程序关掉）。真退出只有两条明确的路：托盘右键 → 退出，或者 Alt+F4（WM_CLOSE）。
# 三条收托盘的入口都走 Hide-ToTray：– / × / 系统最小化（Win+↓、任务栏右键菜单）。
#
# 图标只有一个来源：src\app.ico（打包后从 EXE 里解包到程序目录）。这个文件同时是
#   · EXE 自己的图标（build-exe.ps1 的 /win32icon）
#   · 窗口图标 —— 面板是 powershell.exe 起的，不设 Window.Icon 的话任务栏显示的是
#     PowerShell 的图标，那正是"应用图标和托盘图标不一样"的原因
#   · 托盘图标（取 16px 那一档）
# 读不到时才退回以前那套运行时画出来的图形。
$script:IconFile = Join-Path $PSScriptRoot 'app.ico'
if (Test-Path -LiteralPath $script:IconFile) {
    try {
        # 窗口/任务栏给大一点的那一档（64），系统缩小时用的就是它
        $script:Win.Icon = Get-IconBitmapSource $script:IconFile 64
        # 自绘标题栏也放同一张（窗口是 WindowStyle=None，用户看到的就是这一条）
        if ($n.TitleIcon) { $n.TitleIcon.Source = Get-IconBitmapSource $script:IconFile 32 }
        Write-Dbg ('window icon: app.ico -> {0}x{1}' -f $script:Win.Icon.PixelWidth, $script:Win.Icon.PixelHeight)
    }
    catch { Write-Dbg ('window icon FAILED: ' + $_.Exception.Message) }
}
else { Write-Dbg ('app.ico not found at ' + $script:IconFile + ' - window keeps the default icon') }
$script:ExitRequested = $false
try {
    $hicon = $null
    if (-not (Test-Path -LiteralPath $script:IconFile)) {
        # 兜底：没有 app.ico 就按同一套画法在内存里画一个（和 build-exe 的图形一致）
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::FromArgb(20, 22, 25))
        $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(87, 176, 255))), 4, 4, 24, 24)
        $g.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(20, 22, 25), 3)), 16, 9, 16, 17)
        $g.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(20, 22, 25), 3)), 16, 17, 11, 22)
        $g.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(20, 22, 25), 3)), 16, 17, 21, 22)
        $g.Dispose()
        $hicon = $bmp.GetHicon()
    }

    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    if ($hicon) { $script:Tray.Icon = [System.Drawing.Icon]::FromHandle($hicon) }
    else { $script:Tray.Icon = New-Object System.Drawing.Icon($script:IconFile, 16, 16) }
    $script:Tray.Text = 'ClevoHelper'
    $script:Tray.Visible = $true

    # 托盘右键：只放用户要的两件事（显卡模式 / 电源模式）+ 显示面板 / 退出。
    # Everything else stays in the window - a tray menu that mirrors the whole app is how the
    # old Control Center ended up with 12 entries nobody could find anything in.
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('显示面板')
    [void]$menu.Items.Add('-')
    $miPower = $menu.Items.Add('电源模式')
    foreach ($p in $script:PowerPills) {
        $sub = $miPower.DropDownItems.Add($p.Label)
        $id = [int]$p.Id
        $sub.Add_Click({ Request-Write -Mode $id -Kind 'power'; $script:Win.Show() }.GetNewClosure())
    }
    $miGpu = $menu.Items.Add('显卡模式（重启后生效）')
    if ($script:GpuPills.Count -gt 0) {
        foreach ($g in $script:GpuPills) {
            # GpuPills was built from the EC's supported-mode bitmask; a mode the firmware
            # does not report is not offered here either.
            $sub = $miGpu.DropDownItems.Add($g.Label)
            $gid = [int]$g.Id
            $glabel = [string]$g.Label
            $sub.Add_Click({
                # Same two-step confirmation the panel uses: staging a graphics mode is a
                # pre-boot change, so a stray tray click must not do it silently.
                $r = [System.Windows.Forms.MessageBox]::Show(
                    ("暂存显卡模式「{0}」？`n`n重启后才会生效。暂存后可以再改回，或重启前用面板的恢复初始撤回。" -f $glabel),
                    'ClevoHelper', 'YesNo', 'Question')
                if ($r -eq 'Yes') { Request-Write -Mode $gid -Kind 'gpu' }
            }.GetNewClosure())
        }
    }
    else {
        $na = $miGpu.DropDownItems.Add('（EC 未报告可切换模式）')
        $na.Enabled = $false
    }
    [void]$menu.Items.Add('-')
    $miExit = $menu.Items.Add('退出')
    $miShow.Add_Click({ $script:Win.Show(); $script:Win.Activate() })
    $miExit.Add_Click({ $script:ExitRequested = $true; $script:Win.Close() })
    # DCHU 通道坏了的时候，"很多按钮无效"的根因就在驱动/服务上。把修复入口放在托盘里，
    # 这样即使面板上的控件全都点不动，用户也有一条明确的路可走。
    # 平时（通道正常）这一项是灰的，不占注意力。
    $miFix = $menu.Items.Add('修复 DCHU 驱动…')
    $miFix.Add_Click({
        try {
            $exe = $(if ($script:HostExe) { $script:HostExe } else { Join-Path $PSScriptRoot 'ClevoHelper.ps1' })
            if ($script:HostExe) { Start-Process -FilePath $exe -ArgumentList '--install-driver' }
            else {
                Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
                    '-File', (Join-Path $PSScriptRoot 'Install-DchuDriver.ps1'), '-Apply')
            }
        }
        catch { $n.StatusText.Text = '启动驱动修复失败：' + $_.Exception.Message }
    })
    $script:TrayFixItem = $miFix
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.Add_MouseDoubleClick({ $script:Win.Show(); $script:Win.Activate() })
    Write-Dbg 'tray icon created'
}
catch { Write-Dbg ('TRAY FAILED: ' + $_.Exception.Message) }

# ---------------------------------------------------------- 收进托盘 --------
# "最小化到托盘"在这类常驻工具里是默认行为：面板只是一个窗口，真正的程序活在托盘里。
# 三条入口都走这一个函数：标题栏的 – 、× 、以及系统层面的最小化（Win+↓ / 任务栏右键 →
# 最小化，那条会先变成 WindowState=Minimized，我们在这里把它接住）。
$script:TrayHintShown = $false
# 系统层面的最小化（Win+↓、任务栏右键菜单）也收进托盘，而不是留一个小标题条
$script:Win.Add_StateChanged({
    if ($script:Win.WindowState -eq 'Minimized') { Hide-ToTray }
})

$n.MinBtn.Add_MouseLeftButtonDown({ Hide-ToTray })
$n.MinBtn.Add_MouseEnter({ $n.MinBtn.Foreground = Get-Brush '#FFEDF0F5' })
$n.MinBtn.Add_MouseLeave({ $n.MinBtn.Foreground = Get-Brush '#FF8A93A6' })

# ------------------------------------------------------------- 接线自检 -----
# 为什么非要有这一段：键盘灯的**模式按钮整段绑定被删掉过**（我加方向行时把它替换掉了）。
# 按钮画在屏幕上、点下去毫无反应，而当时的自检是"直接调用 Request-Led" —— 等于替按钮把活
# 干了，所以自检一路全绿，用户报"键盘灯模式改不了"时我还在怀疑别的地方。
# 结论：自检不能只测"下游能不能干活"，必须碰**控件本身**有没有接上。
#
# 这里用反射读 WPF 自己那份处理器表（UIElement.EventHandlersStore）：
#   * 表是 null                -> 这个控件一个事件都没接
#   * Contains(RoutedEvent)    -> 这个事件有没有人管
# 这条判据是**实测过**的，不是猜的（见 src\diag-wire5.ps1）：只接 MouseLeftButtonUp 的控件，
# 问 Up 得 True、问 Down/Wheel 得 False，而没接线的控件表本身是 null。也就是说它是按事件
# 区分的，不是"表非空就算接了"。
# 查的是控件自己的表，不是我另记的一本账：账本会和代码一起被改错，反射不会。
$script:WireStoreProp = [System.Windows.UIElement].GetProperty('EventHandlersStore',
    [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
$script:WireEventMap = [ordered]@{
    Up    = [System.Windows.UIElement]::MouseLeftButtonUpEvent
    Down  = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    Value = [System.Windows.Controls.Primitives.RangeBase]::ValueChangedEvent
}

# 托盘菜单是 WinForms，不走 RoutedEvent。WinForms 的处理器存在 Component 自己的
# EventHandlerList 里（私有字段 events），键是 ToolStripItem 的私有静态 EventClick。
# 这些都拿不到时就如实说"没检查"，不假装通过。
$script:TrayClickKey = $null
try {
    $kf = [System.Windows.Forms.ToolStripItem].GetField('EventClick',
        [System.Reflection.BindingFlags]'Static,NonPublic')
    if ($kf) { $script:TrayClickKey = $kf.GetValue($null) }
}
catch { $script:TrayClickKey = $null }
if (-not $script:TrayClickKey) { $script:TrayClickKeyField = 'MISSING' }
else { $script:TrayClickKeyField = 'ok' }

$script:WiringCheck = Test-PanelWiring
Write-Dbg ('WIRING: 应接 {0} 个，缺 {1} 个（托盘叶子 {2}，其中可核查 {3}，WinForms 反射 {4}；探测器 {5} {6}）' -f `
    $script:WiringCheck.Total, $script:WiringCheck.Missing.Count, $script:WiringCheck.TrayLeaves,
    $script:WiringCheck.TrayChecked, $script:WiringCheck.TrayReflect,
    $(if ($script:WiringCheck.Detector) { 'ok' } else { 'FAIL' }), $script:WiringCheck.DetectorNote)
if ($script:WiringCheck.Missing.Count -gt 0) {
    foreach ($m in $script:WiringCheck.Missing) { Write-Dbg ('WIRING MISSING: ' + $m) }
    $n.StatusText.Text = ('接线自检：有 {0} 个控件没接事件（明细在日志里）' -f $script:WiringCheck.Missing.Count)
    $n.StatusText.Foreground = Get-Brush '#FFE38A6F'
}
else { Write-Dbg 'WIRING: 全部通过' }

$selfPath = $PSCommandPath
if (-not $selfPath) { try { $selfPath = $MyInvocation.MyCommand.Path } catch { } }
$script:ScopeCheck = Test-ClosureScopeTrap $selfPath
if ($script:ScopeCheck.Checked) {
    Write-Dbg ('SCOPE: GetNewClosure 块 {0} 个，其中给 $script: 标量赋值的 {1} 处（探测器 {2}）' -f `
        $script:ScopeCheck.Blocks, $script:ScopeCheck.Hits.Count, $(if ($script:ScopeCheck.DetectorOk) { 'ok' } else { 'FAIL' }))
    foreach ($h in $script:ScopeCheck.Hits) { Write-Dbg ('SCOPE TRAP: ' + $h) }
    if ($script:ScopeCheck.Hits.Count -eq 0 -and $script:ScopeCheck.DetectorOk) { Write-Dbg 'SCOPE: 没有这种坑' }
    if (-not $script:ScopeCheck.DetectorOk) {
        Write-Dbg 'SCOPE: !! 探测器失效，"没有坑"这个结论不可信'
        $n.StatusText.Text = '作用域自检：探测器失效，结论不可信（见日志）'
        $n.StatusText.Foreground = Get-Brush '#FFE38A6F'
    }
}
else { Write-Dbg ('SCOPE: ' + $script:ScopeCheck.Note) }

# -------------------------------------------------- 尺寸探针（-SizeProbe）----
# "启动时 UI 先从很长变成实际的"这种问题只能量出来：窗口是 SizeToContent="Height"，
# 只要**首次显示**时的内容比最终高，用户就会看到窗口先顶到 MaxHeight 再缩回去。
# 这个模式每 120ms 记一次窗口高度 + 几个关键元素的高度，只在数值变化时写日志。
# 它强制不托盘（否则窗口根本不显示），14 秒后自己关掉。
if ($SizeProbe) {
    $script:ProbeT0 = Get-Date
    $script:ProbeLast = ''
    $script:ProbeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProbeTimer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:ProbeTimer.Add_Tick({
        $el = ((Get-Date) - $script:ProbeT0).TotalSeconds
        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add(('win={0}x{1}' -f [int]$script:Win.ActualWidth, [int]$script:Win.ActualHeight))
        [void]$parts.Add(('vis={0}' -f $script:Win.IsVisible))
        [void]$parts.Add(('snap={0}' -f $(if ($script:Sync.Snapshot) { 'yes' } else { 'no' })))
        foreach ($nm in 'StatePanel', 'ControlPanel', 'TabState', 'TabPerf', 'TabKb', 'TabBatt', 'TabMisc', 'TabSys', 'TabAbout',
            'Vol0Row', 'Vol1Row', 'MemRow', 'BrightSlider', 'StatusText', 'TitleTemps') {
            $e = $script:Win.FindName($nm)
            if ($e) {
                [void]$parts.Add(('{0}={1}{2}' -f $nm, [int]$e.ActualHeight, $(if ($e.Visibility -ne 'Visible') { '(c)' } else { '' })))
            }
        }
        $key = ($parts -join ' ')
        if ($key -ne $script:ProbeLast) {
            Write-Dbg ('SIZEPROBE {0,6:N2}s {1}' -f $el, $key)
            $script:ProbeLast = $key
        }
        if ($el -gt 14) { $script:ProbeTimer.Stop(); $script:Win.Close() }
    })
    $script:ProbeTimer.Start()
}

if ($SelfTest) {    # Exercises the exact path a pill click takes: Request-Write -> $Sync.Pending ->
    # sampler write -> read-back -> $Sync.LastWrite -> paint. Uses Quiet then restores,
    # so it is fully reversible, and closes itself.
    $script:SelfTestStep = 0
    $script:SelfTestSceneClicked = $false
    $st = New-Object System.Windows.Threading.DispatcherTimer
    $st.Interval = [TimeSpan]::FromSeconds(1)
    $st.Add_Tick({
        $script:SelfTestStep++
        switch ($script:SelfTestStep) {
            2 {
                # 接线自检放在最前面：如果按钮根本没接上，后面那些"直接调用函数"的测试全绿也
                # 没有意义 —— 那正是键盘灯模式按钮被删掉绑定时的情形。
                $wc = $script:WiringCheck
                Write-Dbg ('SELFTEST wiring: 应接={0} 缺={1} 托盘叶子={2} 可核查={3} 反射={4} 探测器={5}' -f `
                    $wc.Total, $wc.Missing.Count, $wc.TrayLeaves, $wc.TrayChecked, $wc.TrayReflect,
                    $(if ($wc.Detector) { 'ok' } else { 'FAIL' }))
                if ($wc.Missing.Count) {
                    Write-Dbg 'SELFTEST wiring FAIL:'
                    foreach ($m in $wc.Missing) { Write-Dbg ('SELFTEST wiring   - ' + $m) }
                }
                else { Write-Dbg 'SELFTEST wiring: PASS（每个该接的控件都接了事件）' }
                $sc = $script:ScopeCheck
                Write-Dbg ('SELFTEST scope: checked={0} 闭包块={1} 坑={2} {3}' -f `
                    $sc.Checked, $sc.Blocks, $sc.Hits.Count, $sc.Note)
                foreach ($h in $sc.Hits) { Write-Dbg ('SELFTEST scope   - ' + $h) }
                Write-Dbg ('SELFTEST window: shown={0} loaded={1}' -f $script:Win.IsVisible, $script:Win.IsLoaded)
            }
            3 { Write-Dbg 'SELFTEST: simulating click on [省电]'; Request-Write -Mode 1 -Kind 'power' }
            6 {
                # 键盘灯"开机自动注入"这条链路的验证（用户报：键盘灯每次都会重置）。
                # 这里看两件事：① 启动时到底注入了没有（日志里有 LED restore 那行，这里看状态与镜像）；
                # ② 配置能不能存下来并在下次启动读回来（存 → 独立再读，写到临时文件，不碰你的 settings.json）。
                $s2 = $script:Sync.Snapshot
                Write-Dbg ('SELFTEST led: 已注入={0} 配置来源={1} 键盘灯层就绪={2} 当前选择 模式={3} 亮度={4} 速度={5}' -f `
                    $script:LedRestored, $script:LedConfigSource, $script:Sync.KbReady,
                    $script:LedSel.Mode, $script:LedSel.Bright, $script:LedSel.Speed)
                Write-Dbg ('SELFTEST led: EC 镜像里现在写的模式={0}（期望等于上面那个模式：注入成功的证据）' -f `
                    $(if ($s2) { $s2.LedMode } else { 'none' }))
                $keepPath = $script:SettingsPath
                $keepLed = $script:Settings.Led
                $keepSrc = $script:LedConfigSource
                $tmp = Join-Path $env:TEMP 'clevo-led-roundtrip.json'
                try {
                    $script:SettingsPath = $tmp
                    Save-LedConfig
                    Start-Sleep -Milliseconds 120
                    $j = (Get-Content -LiteralPath $tmp -Raw) | ConvertFrom-Json
                    $ok = ($null -ne $j.Led -and [string]$j.Led.Mode -eq [string]$script:LedSel.Mode -and
                           [int]$j.Led.Bright -eq [int]$script:LedSel.Bright -and [int]$j.Led.Speed -eq [int]$script:LedSel.Speed)
                    Write-Dbg ('SELFTEST led: settings.json 往返 ok={0}；文件里 mode={1} bright={2} speed={3} rainbow={4} custom={5}' -f `
                        $ok, $j.Led.Mode, $j.Led.Bright, $j.Led.Speed, $j.Led.Rainbow, $j.Led.UseCustom)
                }
                catch { Write-Dbg ('SELFTEST led: 往返失败: ' + $_.Exception.Message) }
                finally {
                    $script:SettingsPath = $keepPath
                    $script:Settings.Led = $keepLed
                    $script:LedConfigSource = $keepSrc
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            8 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST power result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            10 { Write-Dbg 'SELFTEST: simulating click on [恢复初始]'; Request-Write -Mode 0 -Kind 'restore' }
            13 {
                # 一键场景：走"点按钮"那条真路（Invoke-Scene 造一条 scene 请求塞进槽），采样器在
                # 同一个请求里依次写 电源→风扇→键盘灯→亮度。选「安静」（电源=0 风扇=2 灯=静态蓝
                # 亮度=55%），四个量都不同于默认值，写错一个就露馅。
                # 挑第 13 步是因为第 10 步的 restore 要跑两三秒，槽还占着时点场景会被
                # Invoke-Scene 直接挡回来（它不会顶掉正在执行的请求）—— 这里先把槽的状态记下来。
                Write-Dbg ('SELFTEST scene: 点击前槽空闲={0}' -f (Test-ReqSlotFree))
                if (Test-ReqSlotFree) {
                    Write-Dbg 'SELFTEST: simulating click on scene [安静]'
                    Invoke-Scene -Index 1
                    $script:SelfTestSceneClicked = $true
                }
                else { Write-Dbg 'SELFTEST scene: 槽被 restore 占着，这一步跳过（下一步会有 FAIL 提示）' }
            }
            15 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST restore result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            16 {
                if (-not $script:SelfTestSceneClicked) {
                    Write-Dbg 'SELFTEST scene: FAIL —— 没点成（槽一直不空闲），这一步没验到任何东西'
                }
                else {
                    $lw = $script:Sync.LastWrite
                    Write-Dbg ('SELFTEST scene result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
                    # 光有汇报不算证据：再独立读一次硬件，看电源/风扇是不是真变成了那一档。
                    # 键盘灯和亮度没有可靠的软件读回，只把期望值写进日志，靠眼睛确认。
                    $s3 = $script:Sync.Snapshot
                    $d3 = $script:ScenePills[1]
                    if ($s3) {
                        Write-Dbg ('SELFTEST scene verify: 电源 期望={0} 实际={1} {2}｜风扇 期望={3} 实际={4} {5}' -f `
                            $d3.Power, $s3.PowerMode, $(if ([int]$s3.PowerMode -eq [int]$d3.Power) { 'ok' } else { 'FAIL' }), `
                            $d3.Fan, $s3.FanMode, $(if ([int]$s3.FanMode -eq [int]$d3.Fan) { 'ok' } else { 'FAIL' }))
                        Write-Dbg ('SELFTEST scene verify: 键盘灯 期望模式={0} 色=({1},{2},{3}) 亮度期望={4}%｜EC 镜像当前模式={5}' -f `
                            $d3.Kb, $d3.R, $d3.G, $d3.B, $d3.Bright, $s3.LedMode)
                    }
                    else { Write-Dbg 'SELFTEST scene verify: 没有采样快照，无法独立核对' }
                }
            }
            17 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST restore result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            17 {
                Write-Dbg ('SELFTEST: kbLed loaded={0}' -f $script:Sync.KbReady)
                Write-Dbg 'SELFTEST: simulating click on keyboard brightness [亮] (level 10 = documented default)'
                Request-Rgb -R -1 -G -1 -B -1 -Brightness 10
            }
            22 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST rgb result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            24 {
                # The 杂项 tab goes through a different chain than the rest of the panel
                # (Request-Misc -> sampler 'misc' -> misc.ps1 / dchu.ps1 -> read back), and it
                # is the only one whose state is read on demand, so exercise it here: open the
                # tab, let the sampler fill $s.Misc, then write the brightness it already has
                # (a verified no-op) and print what came back.
                Write-Dbg 'SELFTEST: opening the 杂项 tab and waiting for its state read'
                $script:LedSel.Tab = 'misc'
            }
            27 {
                $s2 = $script:Sync.Snapshot
                $mi = $(if ($s2) { $s2.Misc } else { $null })
                Write-Dbg ('SELFTEST misc read: hasMiscProp={0} miscIsNull={1} snapAge={2:N1}s rate={3}Hz' -f `
                    $(if ($s2) { @($s2.PSObject.Properties.Name) -contains 'Misc' } else { 'noSnapshot' }),
                    ($null -eq $mi),
                    $(if ($s2 -and $s2.At) { ((Get-Date) - $s2.At).TotalSeconds } else { -1 }),
                    $script:Sync.RateHz)
                Write-Dbg ('SELFTEST misc read: bright={0} touchpad={1} numlock={2} charger={3}/{4} winKey={5} fnLock={6}' -f `
                    $(if ($mi) { $mi.Bright } else { 'none' }), $(if ($mi) { $mi.TouchPad } else { 'none' }),
                    $(if ($mi) { $mi.NumLock } else { 'none' }), $(if ($mi) { $mi.ChargerStart } else { 'none' }),
                    $(if ($mi) { $mi.ChargerStop } else { 'none' }), $(if ($mi) { $mi.WinKey } else { 'none' }),
                    $(if ($mi) { $mi.FnLock } else { 'none' }))
                if ($mi -and $null -ne $mi.Bright) {
                    Write-Dbg ('SELFTEST: clicking 屏幕亮度 with its current value ({0}%)' -f $mi.Bright)
                    Request-Misc -Sub 'bright' -Value ([int]$mi.Bright)
                }
                else { Write-Dbg 'SELFTEST: no misc read yet, skipping the brightness write' }
            }
            32 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST misc write result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            34 {
                # 色盘：走的是"取色 -> Request-Led -> sampler -> kbled"这条完整链路，而且它是
                # 唯一一条颜色不是来自预设色块的路径，所以在这里实测一次，然后恢复用户原来
                # 选的颜色（恢复用的就是同一个 Request-Led，不写任何测试专用的东西）。
                $script:LedSel.Tab = 'kb'
                $script:WheelBefore = @{
                    Color = [int]$script:LedSel.Color; Rainbow = [bool]$script:LedSel.Rainbow
                    UseCustom = [bool]$script:LedSel.UseCustom
                    Mode = [string]$script:LedSel.Mode; ModeIdx = [int]$script:LedSel.ModeIdx
                    # 自定义 RGB 也要存！第一版漏了它，自检点完色盘只还原了 UseCustom/Color，
                    # 于是把用户的"自定义颜色"永久留成了测试取的那个颜色（真踩了）。
                    R = [int]$script:LedSel.Custom.R; G = [int]$script:LedSel.Custom.G; B = [int]$script:LedSel.Custom.B
                }
                # 色盘只在需要颜色的模式才发颜色，所以这里先切到「静态」，测完再切回去 ——
                # 否则用户把灯设成「关闭」时，这个测试测到的是"关闭不发颜色"而不是取色链路。
                for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
                    if ($script:LedModePills[$i].Key -eq 'static') { $script:LedSel.ModeIdx = $i; $script:LedSel.Mode = 'static' }
                }
                Write-Dbg ('SELFTEST: picking a colour on the wheel (saved selection: color={0} rainbow={1} custom={2} mode={3})' -f `
                    $script:WheelBefore.Color, $script:WheelBefore.Rainbow, $script:WheelBefore.UseCustom, $script:WheelBefore.Mode)
                Set-LedFromWheel 120 45      # inside the circle, off-axis: not one of the presets
            }
            38 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST wheel pick result: ok={0} msg={1} picked=#{2:X2}{3:X2}{4:X2}' -f `
                    $lw.Ok, $lw.Msg, [int]$script:LedSel.Custom.R, [int]$script:LedSel.Custom.G, [int]$script:LedSel.Custom.B)
                $b = $script:WheelBefore
                $script:LedSel.Color = [int]$b.Color
                $script:LedSel.Rainbow = [bool]$b.Rainbow
                $script:LedSel.UseCustom = [bool]$b.UseCustom
                $script:LedSel.Mode = [string]$b.Mode
                $script:LedSel.ModeIdx = [int]$b.ModeIdx
                $script:LedSel.Custom = @{ R = [int]$b.R; G = [int]$b.G; B = [int]$b.B }   # 自定义颜色也还原
                Request-Led
                Write-Dbg ('SELFTEST: restored the pre-test colour + mode selection（含自定义 RGB {0}/{1}/{2}）' -f $b.R, $b.G, $b.B)
            }
            40 {
                # 把上一次写入的记录清掉，这样 42 那一下真点产生的写入是**唯一**能出现在
                # LastWrite 里的东西，46 的判定就不会把恢复写入误当成本次点击的结果。
                # （状态栏那一行会因此闪回默认文案一秒，无所谓。）
                $script:Sync.LastWrite = $null
                Write-Dbg 'SELFTEST: cleared LastWrite so the next click''s write is unambiguous'
            }
            42 {
                # 用户报的 bug：「键盘灯模式改不了」。根因是模式按钮那一整段绑定被删掉了，而
                # 老自检只调 Request-Led（等于替按钮干活），所以看不出来。这里**真点**一下：
                # 造鼠标消息打到控件上，走它自己接的处理器。点的是"当前已选中的模式"，所以
                # 灯效不变、不需要恢复；要验的是"这一下到底有没有变成一次真正的写入"。
                $idx = [int]$script:LedSel.ModeIdx
                $lbl = $(if ($idx -ge 0 -and $idx -lt $script:LedModePills.Count) { $script:LedModePills[$idx].Label } else { '(模式未同步)' })
                $script:ClickPill = "Led$idx"
                $script:ClickSkipped = $false
                $script:ClickOk = $false
                if ($idx -lt 0 -or $idx -ge $script:LedModePills.Count) {
                    # EC 里存着的模式不在面板提供的五个里（比如原厂应用留下的某种效果），画面上
                    # 没有一盏灯亮着，没有"当前模式"的按钮可点。如实说跳过，不假装点过了。
                    $script:ClickSkipped = $true
                    Write-Dbg ('SELFTEST: 模式未同步（ModeIdx={0}），跳过真点；按钮接线由 2 秒处的接线自检覆盖' -f $idx)
                }
                else {
                    Write-Dbg ('SELFTEST: 真点键盘灯模式按钮 [{0}] {1}（点的是当前模式，不改灯效）' -f $script:ClickPill, $lbl)
                    $script:ClickOk = Invoke-Click $script:ClickPill
                    Write-Dbg ('SELFTEST: Invoke-Click 返回 {0}（False = 控件找不到/抛异常）' -f $script:ClickOk)
                    $pd = $script:Sync.Pending
                    Write-Dbg ('SELFTEST: 点完 Pending = {0}' -f `
                        $(if ($pd) { "$($pd.Kind)/$($pd.Mode)" } else { 'null（采样器已经取走，正常）' }))
                }
            }
            49 {
                $lw = $script:Sync.LastWrite
                # 注意别用 `$script:ClickOk -eq 'skipped'` 这种写法：PowerShell 会把字符串转成
                # bool，$true -eq 'skipped' 是 **True**，于是"点过了"会被判成"跳过了"
                # （这次就是这样，第一次跑自检时报了假的"跳过"）。用单独的布尔量。
                if ($script:ClickSkipped) {
                    Write-Dbg 'SELFTEST 模式点击结果: 跳过（EC 里的模式不在面板的五个里，没有可点的当前模式按钮）'
                }
                else {
                    Write-Dbg ('SELFTEST 模式点击结果: clickOk={0} 写入存在={1} ok={2} msg={3}' -f `
                        $script:ClickOk, ($null -ne $lw), $(if ($lw) { $lw.Ok } else { 'none' }), $(if ($lw) { $lw.Msg } else { 'none' }))
                }
                Write-Dbg ('SELFTEST: 当前模式 = {0}（下标 {1}），应与点击时一致' -f $script:LedSel.Mode, $script:LedSel.ModeIdx)
            }
            44 {
                # 用户报的 bug：点「自定义」以后阈值行一闪就被收回去（现在这一行常驻，
                # 改成"非自定义时按钮不可选"）。这里模拟那次点击，隔几次重画再看：
                # 档位还在不在自定义、按钮能不能点。
                Write-Dbg 'SELFTEST: simulating click on 电池充电 → 自定义'
                $script:MiscSel.CustomOpen = $true
                $script:MiscSel.Charger = 'custom'
                $script:LedSel.Tab = 'misc'
            }
            47 {
                Write-Dbg ('SELFTEST charger custom after 3 repaints: selected={0} rowVisible={1} startPillClickable={2} (expect custom/Visible/True)' -f `
                    $script:MiscSel.Charger, $n.ChargerCustom.Visibility, $n['ChgS0'].IsHitTestVisible)
            }
            50 {
                # 再点一个合法阈值，验证"自定义"真的写进 EC（选项来自 EC，不自己编数字）
                $s2 = $script:Sync.Snapshot
                $mi = $(if ($s2) { $s2.Misc } else { $null })
                $so = $(if ($mi) { @($mi.ChargerStartOptions) } else { @() })
                $eo = $(if ($mi) { @($mi.ChargerStopOptions) } else { @() })
                if ($so.Count -and $eo.Count) {
                    # 挑一组和当前值不同、且合法的（优先 60/90）
                    $start = $(if ($so -contains 60) { 60 } else { [int]$so[0] })
                    $stop = $(if ($eo -contains 90) { 90 } else { [int]$eo[-1] })
                    if ($start -ge $stop) { $start = [int]$so[0]; $stop = [int]$eo[-1] }
                    Write-Dbg ('SELFTEST: picking custom charge thresholds {0}/{1}' -f $start, $stop)
                    Request-Misc -Sub 'start' -Value ([pscustomobject]@{ Start = $start; Stop = $stop })
                }
                else { Write-Dbg 'SELFTEST: EC reported no charge options, skipping the custom write' }
            }
            55 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST charger custom write: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
                Write-Dbg 'SELFTEST: restoring the recommended charge window (70/80)'
                Request-Misc -Sub 'charger' -Value ([pscustomobject]@{ Mode = 'rec'; Start = 70; Stop = 80 })
                $script:MiscSel.CustomOpen = $false
            }
            60 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST charger restore: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
                Write-Dbg 'SELFTEST: killing the sampler runspace on purpose'
                try { $script:Ps.Stop() } catch { Write-Dbg ('SELFTEST kill threw: ' + $_.Exception.Message) }
            }
            68 {
                Write-Dbg ('SELFTEST after kill: restarts={0} snapshotIsNull={1}' -f `
                    $script:Sync.Restarts, ($null -eq $script:Sync.Snapshot))
            }
            78 {
                $s2 = $script:Sync.Snapshot
                Write-Dbg ('SELFTEST recovered snapshot: cpu={0}C fan={1}rpm restarts={2} rate={3}Hz' -f `
                    $(if ($s2) { $s2.CpuTemp } else { 'none' }), $(if ($s2) { $s2.CpuFanRpm } else { 0 }), $script:Sync.Restarts, $script:Sync.RateHz)
                # the perf-counter rewrite (Get-Counter -> persistent PerformanceCounter) is
                # only proven if these four still carry real numbers
                Write-Dbg ('SELFTEST perf values: freq={0}MHz watts={1}W util={2}% ramFree={3}MB' -f `
                    $(if ($s2) { $s2.CpuMhz } else { 'none' }), $(if ($s2) { $s2.CpuWatts } else { 'none' }),
                    $(if ($s2) { $s2.CpuUtil } else { 'none' }), $(if ($s2) { $s2.RamFreeMB } else { 'none' }))
            }
            80 {
                # 显卡模式这条链路以前**从没被自检覆盖过**（用户报"显卡模式不能改"时我手里
                # 没有任何一条自检证据）。这里用和键盘灯一样的办法真点：点模式药丸 → 确认条出现
                # → 点「确认」→ 看写入结果 → 再把原来的模式暂存回去（同一套命令，原值）。
                # 注意：显卡模式是 pre-boot 值，在线读不回来，所以这里能证明的只是
                # "点击→确认→写命令发出并成功返回"，**效果仍然只能重启后看**。
                $s2 = $script:Sync.Snapshot
                $cur = [int]$(if ($s2 -and $s2.GpuMode) { $s2.GpuMode } else { $script:GpuInfo.Mode })
                $targetIdx = -1
                for ($i = 0; $i -lt $script:GpuPills.Count; $i++) {
                    if ([int]$script:GpuPills[$i].Id -ne $cur) { $targetIdx = $i; break }
                }
                $script:GpuClickTarget = $(if ($targetIdx -ge 0) { [int]$script:GpuPills[$targetIdx].Id } else { 0 })
                $script:GpuClickOrig = $cur
                $script:GpuClickOk = $false
                if ($targetIdx -lt 0) {
                    Write-Dbg ('SELFTEST gpu: 只有一个受支持模式（当前 {0}），没有可点的目标，跳过' -f $cur)
                }
                else {
                    Write-Dbg ('SELFTEST gpu: 真点显卡模式药丸 [Gpu{0}] {1}（当前 {2}）' -f `
                        $targetIdx, $script:GpuPills[$targetIdx].Label, $cur)
                    $script:GpuClickOk = Invoke-Click "Gpu$targetIdx"
                    Write-Dbg ('SELFTEST gpu: Invoke-Click={0} GpuStage={1} 确认条可见={2} 确认文字="{3}"' -f `
                        $script:GpuClickOk, $script:GpuStage, $n.GpuConfirm.Visibility, $n.GpuConfirmText.Text)
                }
            }
            81 {
                if ($script:GpuClickTarget -gt 0) {
                    Write-Dbg 'SELFTEST gpu: 真点「确认」'
                    $null = Invoke-Click 'GpuOk'
                    Write-Dbg ('SELFTEST gpu: 确认后 GpuStage={0}（应为 0）确认条={1}' -f $script:GpuStage, $n.GpuConfirm.Visibility)
                }
            }
            85 {
                $lw = $script:Sync.LastWrite
                $s2 = $script:Sync.Snapshot
                Write-Dbg ('SELFTEST gpu 写入结果: ok={0} msg={1}' -f $(if ($lw) { $lw.Ok } else { 'none' }), $(if ($lw) { $lw.Msg } else { 'none' }))
                Write-Dbg ('SELFTEST gpu 暂存状态: GpuStaged={0}（目标 {1}）GpuNow="{2}" 「立即重启」按钮={3}' -f `
                    $(if ($s2) { $s2.GpuStaged } else { 'none' }), $script:GpuClickTarget, $n.GpuNow.Text, $n.GpuRebootBtn.Visibility)
                if ($script:GpuClickTarget -gt 0 -and $script:GpuClickOrig -gt 0) {
                    $oi = -1
                    for ($i = 0; $i -lt $script:GpuPills.Count; $i++) {
                        if ([int]$script:GpuPills[$i].Id -eq $script:GpuClickOrig) { $oi = $i; break }
                    }
                    if ($oi -ge 0) {
                        Write-Dbg ('SELFTEST gpu: 把原来的模式暂存回去（[Gpu{0}] = {1}）' -f $oi, $script:GpuClickOrig)
                        $null = Invoke-Click "Gpu$oi"
                        # 这里必须确认"撤销暂存"真的进了确认条：如果 Set-GpuStage 把"点当前模式"
                        # 当成无事可做而 return，确认条不会出现，GpuOk 也就白点 —— 上一次自检就是
                        # 这样把 EC 留在"已暂存核显"上的（见下面的告警）。
                        Write-Dbg ('SELFTEST gpu: 点原模式后 确认条={0} GpuStage={1}（应为 {2}）' -f `
                            $n.GpuConfirm.Visibility, $script:GpuStage, $script:GpuClickOrig)
                        if ($script:GpuStage -ne $script:GpuClickOrig) {
                            Write-Dbg 'SELFTEST gpu: !! 撤销暂存没能进确认条，EC 里可能仍留着测试用的模式'
                        }
                        else { $null = Invoke-Click 'GpuOk' }
                    }
                    else { Write-Dbg ('SELFTEST gpu: 原始模式 {0} 没有对应的药丸，无法暂存回去！' -f $script:GpuClickOrig) }
                }
            }
            89 {
                $lw = $script:Sync.LastWrite
                $s2 = $script:Sync.Snapshot
                Write-Dbg ('SELFTEST gpu 还原结果: ok={0} msg={1}' -f $(if ($lw) { $lw.Ok } else { 'none' }), $(if ($lw) { $lw.Msg } else { 'none' }))
                Write-Dbg ('SELFTEST gpu: GpuStaged={0}（应为 {1} = 原值）' -f `
                    $(if ($s2) { $s2.GpuStaged } else { 'none' }), $script:GpuClickOrig)
            }
            91 {
                # 风扇曲线：① 编辑器里的四个数必须都是 Step(5) 的倍数（用户明确要求；EC 里原厂
                # 那份是 60/38、86/59，界面上点都点不出来）；② "我的配置"要能存进 settings.json
                # 并在下次启动时读回来 —— 这里做**存 → 独立再读**的往返，而且是写到临时文件里，
                # 不碰用户真正的 settings.json（诊断不该顺手改用户的配置）。
                $lim = $script:FanLimits
                $vals = @([int]$script:FanCustom.T2, [int]$script:FanCustom.D2, [int]$script:FanCustom.T3, [int]$script:FanCustom.D3)
                $bad = @($vals | Where-Object { ([int]$_ % [int]$lim.Step) -ne 0 })
                Write-Dbg ('SELFTEST fan: 来源={0} T2={1} D2={2} T3={3} D3={4}（Step={5}，非 5 倍数 {6} 个）' -f `
                    $script:FanCurveSource, $vals[0], $vals[1], $vals[2], $vals[3], $lim.Step, $bad.Count)
                $keepPath = $script:SettingsPath
                $keepCurve = $script:Settings.FanCurve
                $keepSource = $script:FanCurveSource
                $tmp = Join-Path $env:TEMP 'clevo-settings-roundtrip.json'
                try {
                    $script:SettingsPath = $tmp
                    Save-FanCurve
                    Start-Sleep -Milliseconds 150
                    $j = (Get-Content -LiteralPath $tmp -Raw) | ConvertFrom-Json
                    $ok = ($null -ne $j.FanCurve -and
                           [int]$j.FanCurve.T2 -eq $vals[0] -and [int]$j.FanCurve.D2 -eq $vals[1] -and
                           [int]$j.FanCurve.T3 -eq $vals[2] -and [int]$j.FanCurve.D3 -eq $vals[3])
                    Write-Dbg ('SELFTEST fan: settings.json 往返 ok={0}；文件里 {1}/{2}/{3}/{4}，StartToTray={5}' -f `
                        $ok, $j.FanCurve.T2, $j.FanCurve.D2, $j.FanCurve.T3, $j.FanCurve.D3, $j.StartToTray)
                }
                catch { Write-Dbg ('SELFTEST fan: 往返失败: ' + $_.Exception.Message) }
                finally {
                    $script:SettingsPath = $keepPath
                    $script:Settings.FanCurve = $keepCurve
                    $script:FanCurveSource = $keepSource
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            93 {
                # 重启申请：**只在 dry 模式下自检**。真点「立即重启」会安排一次真的重启，
                # 那种事不能由自检替你决定（面板的规矩就是不替你重启）。dry 模式把
                # shutdown.exe 换成一行日志，只验证界面这条路：申请弹出来了没有、
                # 两个按钮在不在、倒计时/取消能不能走。
                Write-Dbg 'SELFTEST reboot-prompt: 用 dry 模式弹一次重启申请'
                try { Show-RebootPrompt -Mode $script:GpuClickTarget -DryRun } catch { Write-Dbg ('SELFTEST reboot-prompt FAILED: ' + $_.Exception.Message) }
                $d = $script:RebootDlg
                if ($d) {
                    Write-Dbg ('SELFTEST reboot-prompt: 窗口可见={0} 申请区={1} 倒计时区={2}' -f `
                        $d.Win.IsVisible, $d.Ask.Visibility, $d.Count.Visibility)
                }
                else { Write-Dbg 'SELFTEST reboot-prompt: 没有拿到对话框状态' }
            }
            95 {
                $d = $script:RebootDlg
                if ($d) {
                    Confirm-RebootNow $d
                    Write-Dbg ('SELFTEST reboot-prompt: 点「立即重启」(dry) → 申请区={0} 倒计时区={1} 文案="{2}"' -f `
                        $d.Ask.Visibility, $d.Count.Visibility, $d.Note.Text)
                }
            }
            97 {
                $d = $script:RebootDlg
                if ($d) {
                    Cancel-RebootNow $d
                    Write-Dbg ('SELFTEST reboot-prompt: 点「取消重启」(dry) → 文案="{0}"' -f $d.Note.Text)
                    Start-Sleep -Milliseconds 900
                    try { $d.Win.Close() } catch { }
                    Write-Dbg ('SELFTEST reboot-prompt: 关掉对话框后窗口可见={0}' -f $d.Win.IsVisible)
                }
            }
            101 {
                # 最小化 / 关闭 → 收进托盘。都是**真点**：– 是 Down 绑定（以前是 Up，被标题栏
                # 的 DragMove 吃掉了，所以"点了没反应"），× 现在也只收托盘、不再退出。
                # 下面三条依次覆盖：– / × / 系统层面的最小化。
                Write-Dbg 'SELFTEST tray-hide: 真点标题栏的「–」'
                $null = Invoke-Click 'MinBtn'
                Write-Dbg ('SELFTEST tray-hide: 「–」之后 窗口可见={0}（期望 False）' -f $script:Win.IsVisible)
                $script:Win.Show()
                Start-Sleep -Milliseconds 300
                Write-Dbg ('SELFTEST tray-hide: Show() 又叫回来了 可见={0}' -f $script:Win.IsVisible)
            }
            103 {
                Write-Dbg 'SELFTEST tray-hide: 真点标题栏的「×」（现在应该只收托盘、不退出）'
                $null = Invoke-Click 'CloseBtn'
                Write-Dbg ('SELFTEST tray-hide: 「×」之后 窗口可见={0}（期望 False；进程还活着才会有后面的日志）' -f $script:Win.IsVisible)
                $script:Win.Show()
                Start-Sleep -Milliseconds 300
            }
            105 {
                # 系统层面的最小化（Win+↓ / 任务栏右键菜单）也要被接住
                Write-Dbg 'SELFTEST tray-hide: 把 WindowState 设成 Minimized（模拟 Win+↓）'
                $script:Win.WindowState = 'Minimized'
                Start-Sleep -Milliseconds 400
                Write-Dbg ('SELFTEST tray-hide: 之后 状态={0} 可见={1}（期望 Normal/False）' -f $script:Win.WindowState, $script:Win.IsVisible)
                $script:Win.Show()
                Start-Sleep -Milliseconds 300
                Write-Dbg ('SELFTEST tray-hide: 收尾 可见={0}（期望 True）' -f $script:Win.IsVisible)
            }
            107 {
                # 检查更新：版本比较是纯函数（离线也能验），网络那一段照发一次 ——
                # 离线/被墙时看它记 error/timeout 而不是抛异常，这本身就是"不崩"的证据。
                $cases = @(
                    @('v1.4', '1.3', 1), @('v1.3', '1.3', 0), @('v1.2', '1.3', -1),
                    @('v1.10', '1.9', 1), @('1.3.0', '1.3', 0), @('v2', '1.99', 1)
                )
                $bad = 0
                foreach ($c in $cases) {
                    $got = Compare-AppVersion $c[0] $c[1]
                    if ($got -ne $c[2]) { $bad++; Write-Dbg ('SELFTEST update FAIL: {0} vs {1} 期望 {2} 实得 {3}' -f $c[0], $c[1], $c[2], $got) }
                }
                Write-Dbg ('SELFTEST update: 版本比较 {0}/{1} 通过（{2}）' -f ($cases.Count - $bad), $cases.Count,
                    $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' }))
                $grel = Get-LatestRelease 6000
                Write-Dbg ('SELFTEST update: 实网 kind={0} ok={1} 远端={2} 本机=v{3} url={4} msg={5}' -f `
                    $grel.Kind, $grel.Ok, $grel.Tag, $script:AppVersion, $grel.Url, $grel.Message)
            }
            106 {
                # 收尾：把机器交还给用户。自检里改过电源/风扇/灯/亮度，其中场景那一步是四个一起改
                # 的，不还原就留在「安静」上——自检跑完人走了，机器还静音着，这不行。
                Write-Dbg 'SELFTEST: 收尾，恢复打开面板时捕获的初始状态'
                Request-Write -Mode 0 -Kind 'restore'
            }
            109 {
                # 第 106 步排的"收尾还原"要等它真的做完再关窗：请求是排队交给采样器的，
                # 立刻 Close() 会把还没执行的还原丢掉 —— 那样日志上写了"恢复初始"，
                # 机器却停在自检最后改的那一档（2026-10-28 实测亮度就留在 55%）。
                for ($w = 0; $w -lt 25 -and -not (Test-ReqSlotFree); $w++) { Start-Sleep -Milliseconds 200 }
                Write-Dbg 'SELFTEST: done, closing'
                $script:Win.Close()
            }
        }
    })
    $st.Start()
}

# ---- 合盖/睡眠恢复后重新注入键盘灯 ------------------------------------------------
# 现象：合上盖子再打开，键盘灯回到蓝色/彩虹，得手动点一次「关闭灯光」才回来。
# 原因：灯效注入是"每个进程只做一次"（$script:LedRestored 一置位就不再重发，见 2848 行那块），
#       而 EC 在 S3 恢复时会把键盘灯打回它自己的开机状态（就是冷启动那套"先彩虹后蓝"），
#       程序里又没有任何电源事件处理，所以醒来后没人再注入。
# 判据：定时器 400ms 一跳、采样器整轮 0.5-0.7s，正常两跳间隔远小于 45s；一旦 ≥45s，
#       只可能是系统停摆过（S3/S4、现代待机被冻结）。窗口被锁/负载高都不会到这个量级。
#       不用 PowerModeChanged 是因为它在 S0ix 现代待机下会漏事件，而"时间差"骗不了人。
# 动作：把 $script:LedRestored 置回 $false，下一轮 Update-Panel 就会照常排队重新注入
#       （走和开机完全相同的那条路径，成功/失败照样落盘成 STARTUP led: ok=…）。
$script:LastTickAt = $null
$script:ResumeGapSeconds = 45

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:Timer.Add_Tick({ $null = Test-Sampler; Test-ResumeGap; Update-Panel; Test-ShowRequest; Test-RebootAsk })
$script:Timer.Start()

# 第二次双击 EXE 时，启动器会写一个 show.request 文件（见 build-exe.ps1 的 ActivateExisting）。
# 面板在这里消费它：Show + Activate —— 这条对"最小化到托盘"（窗口真的被 Hide 了）也有效，
# 而从外面调 SetForegroundWindow 是叫不醒一个隐藏窗口的。
# 以前启动器遇到"已经在运行"就直接 return，用户双击桌面上的 EXE 时什么都不会发生，
# 看起来就是"这个 exe 用不了"。
$script:ShowFlag = Join-Path (Split-Path $PSScriptRoot -Parent) 'show.request'

$script:Win.Add_Closed({
    try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
    $script:Sync.Stop = $true
    $script:Timer.Stop()
    try { $script:Ps.Stop() } catch { }
    try { $script:Rs.Close() } catch { }
    # 收进托盘那种启动方式用的是 Show + Dispatcher.Run（没有 ShowDialog 可返回），
    # 所以关窗时要把消息循环也停掉，否则进程会留在后台什么都不干。
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
})

if ($script:StartToTray) {
    # 直接进托盘：窗口**创建但不显示**（必须创建，否则托盘图标和两个定时器没有宿主消息循环）。
    # Show 期间把 Opacity 设成 0 再 Hide，避免"闪一下窗口"。之后被托盘双击/再运行一次 exe
    # 叫出来时，WindowStartupLocation 还是 CenterScreen，会正常出现在屏幕中央。
    Write-Dbg 'startup: going straight to the tray (window created but not shown)'
    $script:Win.Opacity = 0
    $script:Win.Show()
    $script:Win.Hide()
    $script:Win.Opacity = 1
    [System.Windows.Threading.Dispatcher]::Run()
}
else {
    # **这里不能用 ShowDialog()**：实测（src\diag-showdialog-hide.ps1）Hide() 会让 ShowDialog
    # 直接返回 —— 于是"收进托盘"变成了"退出程序"：窗口一藏，消息循环就结束，脚本跑到结尾，
    # 进程消失。托盘那条路一直没事，恰恰因为它用的是 Show + Dispatcher.Run()。
    # 现在两条路一致：Show() 显示、Dispatcher.Run() 跑消息循环，真正的退出只发生在
    # Win.Close()（托盘右键 → 退出 / Alt+F4）→ Closed 里 InvokeShutdown 的那一刻。
    Write-Dbg 'startup: showing the window (Show + Dispatcher.Run, not ShowDialog)'
    $script:Win.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}