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
$script:Settings = @{ StartToTray = $true; FanCurve = $null }
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
    }
}
catch { }
function Save-Settings {
    try {
        # -Depth 5：FanCurve 是嵌套的哈希表，默认深度会把里面那层丢掉（写出去只剩一个空对象）。
        ($script:Settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { Write-Dbg ('settings save failed: ' + $_.Exception.Message) }
}
# -StartHidden 只在启动器要求时生效；设置里的开关决定"双击启动"要不要也收进托盘。
# 例外：-SelfTest 时必须让窗口真的显示出来 —— 自检里有几处是"真点按钮"（Invoke-Click 走
# RaiseEvent），而控件不在**已显示**的可视树里时 RaiseEvent 不会触发处理器（实测见
# src\diag-wire6.ps1），否则自检会报一堆假失败。
$script:StartToTray = ($StartHidden -or [bool]$script:Settings.StartToTray) -and (-not $SelfTest) -and (-not $SizeProbe)

$script:LogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\monitor-debug.log'
function Write-Dbg([string]$m) {
    try {
        # create the log directory on demand: when running from the packaged exe the whole
        # tree lives under %LOCALAPPDATA%\ClevoHelper and the artifacts folder does not
        # exist yet - Add-Content would throw and the panel would log NOTHING, silently.
        $dir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # keep the log bounded: a repeating error would otherwise grow it forever
        $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 1MB) {
            $keep = Get-Content -LiteralPath $script:LogPath -Tail 200 -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $script:LogPath -Value $keep -Encoding UTF8
            Add-Content -LiteralPath $script:LogPath -Value '(log truncated at 1 MB)' -Encoding UTF8
        }
        Add-Content -LiteralPath $script:LogPath -Value ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $m) -Encoding UTF8
    }
    catch { }
}

# ---------------------------------------------------------------- 关于页 ----
# 头像和署名沿用用户另一个工具（SICAU-AutoLogin 校园网自动认证）里的"我的信息"：同一张头像、
# 同一个署名、同样的"名片 + 信息行 + 原理说明"结构，这样两个工具看起来是一个人做的。
# 头像是嵌进 EXE 的资源（build-exe.ps1 里 img.avatar.png），运行时解包到程序目录，
# 不依赖任何外部文件 —— 和那个工具一样，"程序只有一个 EXE"这个约定不破。
# 版本号的单一来源：这里改一处，标题栏和关于页都跟着变。
$script:AppName = 'ClevoHelper'
$script:AppVersion = '1.0'
$script:AuthorName = '极夜光'
$script:AuthorMail = 'yeguang225@outlook.com'

# 关于页的信息行。**只放别处看不到的东西**（用户要求）：机型在标题栏、开机自启在杂项页、
# 显卡在状态/性能页、内存和处理器在状态页、EC 通道在底部状态栏 —— 这些这里都不再重复，
# 关于页只留"程序是谁、什么版本、装在哪"和两个别处确实没有的硬件号。
$script:AboutRows = @(
    @{ Key = 'Version';  Label = '版本' }
    @{ Key = 'Built';    Label = '构建' }
    @{ Key = 'Mode';     Label = '运行方式' }
    @{ Key = 'ExePath';  Label = '程序位置' }
    @{ Key = 'DataDir';  Label = '数据目录' }
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

# 曲线上的每个数都必须是 Step(5) 的倍数：界面上只能按 5 加减，所以**读进来的值一律先吸附**，
# 否则会冒出一个点不出来的数（比如 38%、59%、86°C）。
function Snap-FanValue([int]$Value, [int]$Min, [int]$Max) {
    $st = [int]$script:FanLimits.Step
    $v = [int]([Math]::Round($Value / $st) * $st)
    if ($v -lt $Min) { $v = [int]([Math]::Ceiling($Min / $st) * $st) }
    if ($v -gt $Max) { $v = [int]([Math]::Floor($Max / $st) * $st) }
    return [int]$v
}
function Set-FanCustomSafe([hashtable]$src) {
    # 四个数一起收，顺手保证 节点2温度 < 节点3温度、节点2转速 <= 节点3转速 ——
    # 这两种"界面点不出来"的状态如果被写进编辑器，加减按钮的夹取会让它卡住不动。
    $lim = $script:FanLimits
    $t2 = Snap-FanValue ([int]$src.T2) $lim.TMin $lim.TMax
    $t3 = Snap-FanValue ([int]$src.T3) $lim.TMin $lim.TMax
    $d2 = Snap-FanValue ([int]$src.D2) $lim.DMin $lim.DMax
    $d3 = Snap-FanValue ([int]$src.D3) $lim.DMin $lim.DMax
    if ($t3 -le $t2) {
        # 两个温度撞在一起时把 T3 抬上去；抬不动（T2 已经顶到上限）就把 T2 压下来 ——
        # 否则会留下"节点2 温度 == 节点3 温度"这种界面上点不出来的状态。
        $t3 = [Math]::Min($lim.TMax, $t2 + $lim.Step)
        if ($t3 -le $t2) { $t2 = [Math]::Max($lim.TMin, $t3 - $lim.Step) }
    }
    if ($d3 -lt $d2) { $d3 = $d2 }
    $script:FanCustom.T2 = $t2
    $script:FanCustom.D2 = $d2
    $script:FanCustom.T3 = $t3
    $script:FanCustom.D3 = $d3
    return $script:FanCustom
}
function Save-FanCurve {
    $script:Settings.FanCurve = @{
        T2 = [int]$script:FanCustom.T2; D2 = [int]$script:FanCustom.D2
        T3 = [int]$script:FanCustom.T3; D3 = [int]$script:FanCustom.D3
    }
    Save-Settings
    # 存下来了，界面上那行提示就该改口叫"你保存的曲线"（说的必须是真的）
    $script:FanCurveSource = 'settings'
}
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

function New-PillXaml([string]$prefix, $pills, [int]$minW = 70) {
    # MinWidth + centred text instead of per-pill Padding: 自动 / 强冷 / 均衡 are
    # different lengths, and content-sized pills made every row look ragged. With a
    # fixed MinWidth all pills in a group are the same size and line up in columns.
    # The keyboard mode row passes a smaller width so its 9 modes still fit on one line.
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($p in $pills) {
        $tip = if ($p.ContainsKey('Tip')) { ' ToolTip="' + $p.Tip + '"' } else { '' }
        [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Background="#FF262A33" CornerRadius="13" MinWidth="{2}" Padding="0,5" Margin="0,0,7,0" Cursor="Hand"{3}>' -f $prefix, $i, $minW, $tip))
        [void]$sb.AppendLine(('  <TextBlock x:Name="{0}{1}T" Text="{2}" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>' -f $prefix, $i, $p.Label))
        [void]$sb.AppendLine('</Border>')
        $i++
    }
    $sb.ToString()
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
# What the keyboard tab is currently set to. The LED hardware reports nothing back, so this
# session-side state is what the UI shows; the AppSettings mirror is the verification.
# default colour indices are looked up by label: inserting 彩虹 at the front shifted every
# index, and a hardcoded number would silently point at a different colour
function Get-RgbIndex([string]$label) {
    for ($i = 0; $i -lt $script:RgbPills.Count; $i++) { if ($script:RgbPills[$i].Label -eq $label) { return $i } }
    return 0
}
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

function New-SwatchXaml([string]$prefix, $pills) {
    # A swatch is either a solid colour or the 彩虹 entry ($RainbowSwatch), which gets a real
    # gradient brush so it reads as "multi-colour" rather than as one more colour.
    # 24px + a 5px gap: at the portrait width the content column is 326px wide and the panel
    # offers 10 swatches, so 26+7 (=330) did not fit and the last ones slid under the row's
    # hint text. Measured after the change: 10 x 29 = 290.
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($p in $pills) {
        if ($p.Swatch -eq $script:RainbowSwatch) {
            [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Width="24" Height="24" CornerRadius="12" Margin="0,0,5,0" Cursor="Hand" ToolTip="{2}">' -f $prefix, $i, $p.Label))
            [void]$sb.AppendLine('  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0">')
            [void]$sb.AppendLine('    <GradientStop Color="#FFFF3B30" Offset="0"/><GradientStop Color="#FFFFD60A" Offset="0.2"/>')
            [void]$sb.AppendLine('    <GradientStop Color="#FF32D74B" Offset="0.4"/><GradientStop Color="#FF64D2FF" Offset="0.6"/>')
            [void]$sb.AppendLine('    <GradientStop Color="#FF0A84FF" Offset="0.8"/><GradientStop Color="#FFBF5AF2" Offset="1"/>')
            [void]$sb.AppendLine('  </LinearGradientBrush></Border.Background>')
            [void]$sb.AppendLine('</Border>')
        }
        else {
            [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Width="24" Height="24" CornerRadius="12" Background="{2}" Margin="0,0,5,0" Cursor="Hand" ToolTip="{3}"/>' -f $prefix, $i, $p.Swatch, $p.Label))
        }
        $i++
    }
    $sb.ToString()
}

function New-SwitchRowXaml([string]$prefix, [string]$label, $pills, [string]$hint, [int]$pillW = 46) {
    # label + pill pair + a SHORT note to the right of the buttons (user request).
    # It has been in both shapes now, and the rule that makes the right-hand column safe is
    # simply that the note stays short: the content column is 326px, two pills take 106px,
    # which leaves ~210px - about 17 Chinese characters at 11px. The earlier version of this
    # row used full sentences ('系统 NumLock（原厂无 EC 通道，走系统按键）', ~240px) and the
    # text landed on top of the 关 pill (measured: hint x=191, pills 105..204).
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('            <Grid Margin="0,0,0,9">')
    [void]$sb.AppendLine('              <Grid.ColumnDefinitions>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="66"/>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="*"/>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="Auto"/>')
    [void]$sb.AppendLine('              </Grid.ColumnDefinitions>')
    [void]$sb.AppendLine(('              <TextBlock Grid.Column="0" Text="{0}" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>' -f $label))
    [void]$sb.AppendLine(('              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="{0}Row">' -f $prefix))
    [void]$sb.Append((New-PillXaml $prefix $pills $pillW))
    [void]$sb.AppendLine('              </StackPanel>')
    [void]$sb.AppendLine(('              <TextBlock Grid.Column="2" Text="{0}" Foreground="#FF5A6273" FontSize="11" VerticalAlignment="Center" ToolTip="{1}"/>' -f $hint, $hint))
    [void]$sb.AppendLine('            </Grid>')
    $sb.ToString()
}

function New-StepperXaml([string]$prefix, [string]$caption) {
    # − value unit + stepper.
    # The number sits right-aligned in a FIXED 34px box and the unit left-aligned in its own
    # 22px box (monospace). Centre-aligning "60 °C" / "100 °C" in one box made the digits and
    # the ± buttons slide sideways as the value changed - measured, not guessed.
    @"
              <StackPanel Orientation="Horizontal" Margin="0,0,20,0" VerticalAlignment="Center">
                <TextBlock Text="$caption" Foreground="#FF5A6273" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Border x:Name="${prefix}Minus" Background="#FF262A33" CornerRadius="11" MinWidth="26" Padding="0,3" Cursor="Hand">
                  <TextBlock Text="&#x2212;" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
                <TextBlock x:Name="${prefix}Val" Text="--" Foreground="#FFD7DCE6" FontFamily="Consolas" FontSize="13"
                           Width="34" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="${prefix}Unit" Text="$([char]0x00B0)C" Foreground="#FF6B7385" FontFamily="Consolas" FontSize="11"
                           Width="22" TextAlignment="Left" VerticalAlignment="Center" Margin="3,0,3,0"/>
                <Border x:Name="${prefix}Plus" Background="#FF262A33" CornerRadius="11" MinWidth="26" Padding="0,3" Cursor="Hand">
                  <TextBlock Text="+" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
              </StackPanel>
"@
}

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
function New-ColorWheelBitmap([int]$size) {
    $bmp = New-Object System.Windows.Media.Imaging.WriteableBitmap($size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Bgra32), $null)
    $px = [ClevoHelper.ColorWheel]::Pixels($size)
    $bmp.WritePixels((New-Object System.Windows.Int32Rect(0, 0, $size, $size)), $px, ($size * 4), 0)
    $bmp.Freeze()
    return $bmp
}


function New-AboutRowXaml([string]$name, [string]$label) {
    # 关于页的一行：左侧小标签 + 右侧等宽值（和其它页面同一套列宽，所以标签列也对齐）
    @"
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="$label" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" x:Name="$name" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" FontFamily="Consolas"
                         VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </Grid>
"@
}

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

function New-VolumeRowXaml([int]$n) {
    # row 0 starts visible (empty) so the auto-sized window does not jump 25px when the
    # first storage sample arrives; the paint tick collapses it if the host has no disks
    $vis = if ($n -eq 0) { 'Visible' } else { 'Collapsed' }
    @"
            <Grid x:Name="Vol${n}Row" Margin="0,7,0,0" Visibility="$vis">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="76"/>
                <ColumnDefinition Width="96"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="Vol${n}Name" Text="" Foreground="#FFD7DCE6" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <Border Grid.Column="1" Background="#FF262A33" CornerRadius="3" Height="7" VerticalAlignment="Center">
                <Border x:Name="Vol${n}Bar" Background="#FF57B0FF" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
              </Border>
              <TextBlock Grid.Column="2" x:Name="Vol${n}Size" Text="" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" Margin="10,0,10,0" TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Column="3" x:Name="Vol${n}Type" Text="" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" MinWidth="46" TextAlignment="Right"/>
            </Grid>
"@
}
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClevoHelper" Width="468" SizeToContent="Height" MaxHeight="920"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display">
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
          <TextBlock x:Name="SubTitle" Text="  Clevo X370SN" Foreground="#FF6B7385" FontSize="12" Margin="8,2,0,0"/>
        </StackPanel>
        <TextBlock x:Name="MinBtn" Text="&#x2013;" Foreground="#FF7C8598" FontSize="16"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,48,6" Cursor="Hand"/>
        <TextBlock x:Name="CloseBtn" Text="&#x2715;" Foreground="#FF7C8598" FontSize="14"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,22,0" Cursor="Hand"/>
      </Grid>

      <StackPanel Grid.Row="1" Margin="16,0,16,0">
        <!-- Tab bar + the always-visible strip. Monitoring used to occupy the top of the
             window permanently; now it is the 状态 tab, and the strip keeps the numbers that
             matter (temps/fans/power + the active modes) on screen whichever tab is open.
             The four tab buttons share the full width equally (star columns) instead of being
             content-sized: in a portrait window a ragged row of pills looks like a mistake.
             开机自启 moved into 杂项 and 恢复初始 into 性能与散热, so this row holds nothing
             but navigation. -->
        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" x:Name="TabBtnState" Background="#FF262A33" CornerRadius="13" Margin="0,0,5,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnStateT" Text="状态" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="1" x:Name="TabBtnPerf" Background="#FF262A33" CornerRadius="13" Margin="0,0,5,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnPerfT" Text="性能散热" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="2" x:Name="TabBtnKb" Background="#FF262A33" CornerRadius="13" Margin="0,0,5,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnKbT" Text="键盘灯" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="3" x:Name="TabBtnMisc" Background="#FF262A33" CornerRadius="13" Margin="0,0,5,0" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnMiscT" Text="杂项" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
          </Border>
          <Border Grid.Column="4" x:Name="TabBtnAbout" Background="#FF262A33" CornerRadius="13" Padding="0,5" Cursor="Hand">
            <TextBlock x:Name="TabBtnAboutT" Text="关于" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
          </Border>
        </Grid>

        <Border Background="#FF1B1E25" CornerRadius="10" Padding="14,6,14,6" Margin="0,0,0,8">
          <StackPanel>
            <TextBlock x:Name="VitalsSensors" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" FontFamily="Consolas"/>
            <TextBlock x:Name="VitalsModes" Text="--" Foreground="#FF8A93A6" FontSize="11" Margin="0,3,0,0"/>
          </StackPanel>
        </Border>

        <!-- ============ 状态 ============ -->
        <!-- Same box as the other three tabs: same background/radius/padding and the SAME
             fixed height, so switching tabs never changes the window size (user request:
             四个界面的长宽一样). The CPU/GPU cards are stacked instead of side by side -
             two cards cannot both fit across a portrait window. -->
        <Border x:Name="StatePanel" Background="#FF191C22" CornerRadius="12" Padding="22,15,22,14" Height="470">
        <StackPanel x:Name="TabState">
          <Border Background="#FF1B1E25" CornerRadius="12" Margin="0,0,0,8" Padding="18,14,18,12">
            <StackPanel>
              <TextBlock x:Name="CpuHeader" Text="CPU · i9-13900HX" Foreground="#FF7C8598" FontSize="11" TextTrimming="CharacterEllipsis"/>
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
                  <TextBlock Text="温度" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <Grid Height="34">
                    <TextBlock x:Name="CpuFreq" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="有效频率" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <Grid Height="34">
                    <TextBlock x:Name="CpuPower" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="封装功耗" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="#FF262A33" Margin="0,10,0,9"/>
              <!-- identical geometry to the GPU card: 负载 | 风扇转速 | 风扇占空比 -->
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="112"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="负载 " Foreground="#FF5A6273" FontSize="11"/>
                  <TextBlock x:Name="CpuUtil" Text="--" Foreground="#FFD7DCE6" FontSize="13" FontFamily="Consolas"
                             Width="34" TextAlignment="Left"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="风扇 " Foreground="#FF5A6273" FontSize="11"/>
                  <TextBlock x:Name="CpuRpm" Text="--" Foreground="#FFEDF0F5" FontSize="13" FontFamily="Consolas"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock x:Name="CpuDutyText" Text="--" Foreground="#FF6B7385" FontSize="11" Margin="0,0,8,0" MinWidth="30" TextAlignment="Right"/>
                  <Border Background="#FF262A33" CornerRadius="3" Height="6" Width="104">
                    <Border x:Name="CpuBar" Background="#FF57B0FF" CornerRadius="3" Height="6" Width="0" HorizontalAlignment="Left"/>
                  </Border>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

          <Border Background="#FF1B1E25" CornerRadius="12" Margin="0,0,0,8" Padding="18,14,18,12">
            <StackPanel>
              <TextBlock x:Name="GpuHeader" Text="GPU · RTX 4080 Laptop" Foreground="#FF7C8598" FontSize="11" TextTrimming="CharacterEllipsis"/>
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
                  <TextBlock Text="温度" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <Grid Height="34">
                    <TextBlock x:Name="GpuFreq" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="核心频率" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <Grid Height="34">
                    <TextBlock x:Name="GpuPower" Text="--" Foreground="#FFD7DCE6" FontSize="18" VerticalAlignment="Bottom" Margin="0,0,0,3"/>
                  </Grid>
                  <TextBlock Text="功耗" Foreground="#FF5A6273" FontSize="10" Margin="0,4,0,0"/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="#FF262A33" Margin="0,10,0,9"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="112"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="负载 " Foreground="#FF5A6273" FontSize="11"/>
                  <TextBlock x:Name="GpuUtil" Text="--" Foreground="#FFD7DCE6" FontSize="13" FontFamily="Consolas"
                             Width="34" TextAlignment="Left"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="风扇 " Foreground="#FF5A6273" FontSize="11"/>
                  <TextBlock x:Name="GpuRpm" Text="--" Foreground="#FFEDF0F5" FontSize="13" FontFamily="Consolas"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock x:Name="GpuDutyText" Text="--" Foreground="#FF6B7385" FontSize="11" Margin="0,0,8,0" MinWidth="30" TextAlignment="Right"/>
                  <Border Background="#FF262A33" CornerRadius="3" Height="6" Width="104">
                    <Border x:Name="GpuBar" Background="#FF6FE38A" CornerRadius="3" Height="6" Width="0" HorizontalAlignment="Left"/>
                  </Border>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

        <!-- 内存 -->
        <Border Background="#FF1B1E25" CornerRadius="12" Margin="0,0,0,8" Padding="18,12,18,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="76"/>
              <ColumnDefinition Width="96"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="内存" Foreground="#FF7C8598" FontSize="11" VerticalAlignment="Center"/>
            <Border Grid.Column="1" Background="#FF262A33" CornerRadius="3" Height="7" VerticalAlignment="Center">
              <Border x:Name="MemBar" Background="#FFB98BFF" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
            </Border>
            <TextBlock Grid.Column="2" x:Name="MemText" Text="--" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" Margin="10,0,10,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Grid.Column="3" x:Name="MemPct" Text="" Foreground="#FFB98BFF" FontSize="11" VerticalAlignment="Center" MinWidth="46" TextAlignment="Right"/>
          </Grid>
        </Border>

        <!-- 存储 -->
        <Border Background="#FF1B1E25" CornerRadius="12" Padding="18,11,18,12">
          <StackPanel>
            <Grid>
              <TextBlock Text="存储" Foreground="#FF7C8598" FontSize="11"/>
              <TextBlock x:Name="PhysDiskText" HorizontalAlignment="Right" Foreground="#FF5A6273" FontSize="11"/>
            </Grid>
$(for ($i = 0; $i -lt $script:MaxVolumes; $i++) { New-VolumeRowXaml $i })
          </StackPanel>
        </Border>

        <!-- 屏幕亮度：从杂项页搬到这里（用户要求）—— 调亮度是"看屏幕时随手就做"的事，
             放在监控页比放在杂项页顺路。 -->
        <Border Background="#FF1B1E25" CornerRadius="12" Margin="0,8,0,0" Padding="18,9,18,9">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="76"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="屏幕亮度" Foreground="#FF7C8598" FontSize="11" VerticalAlignment="Center"/>
            <Slider Grid.Column="1" x:Name="BrightSlider" Minimum="0" Maximum="100" TickFrequency="5"
                    IsSnapToTickEnabled="False" IsMoveToPointEnabled="True" VerticalAlignment="Center"
                    Foreground="#FF57B0FF" Background="#FF262A33" Margin="0,0,10,0"/>
            <TextBlock Grid.Column="2" x:Name="BrightVal" Text="--%" Foreground="#FFD7DCE6" FontSize="11.5"
                       FontFamily="Consolas" MinWidth="42" TextAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        </StackPanel>
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
      <Border x:Name="ControlPanel" Grid.Row="2" Background="#FF191C22" CornerRadius="12" Margin="16,0,16,0" Padding="22,15,22,14" Height="470" Visibility="Collapsed">
        <StackPanel>
          <!-- ============ 性能与散热 ============ -->
          <StackPanel x:Name="TabPerf" Visibility="Collapsed">
            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="电源" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="PowerPillRow">
$(New-PillXaml 'Pwr' $script:PowerPills)
              </StackPanel>
            </Grid>

            <Grid x:Name="GpuRow" Margin="0,0,0,3">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="显卡" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="GpuPillRow">
$(New-PillXaml 'Gpu' $script:GpuPills)
              </StackPanel>
            </Grid>
            <!-- The confirm strip gets its own line: it carries two 52px buttons plus the
                 question, and in the right-hand column of a 468px row it would start on top
                 of the third mode pill (measured: pills end at x=336). -->
            <Grid Margin="66,0,0,8">
              <TextBlock x:Name="GpuNow" Text="" Foreground="#FF6B7385" FontSize="11" VerticalAlignment="Center"/>
              <!-- 暂存了新模式以后，这一行的右边会出现「立即重启」：重启申请弹窗关掉之后
                   （或者用户当时选了"稍后"），想立刻重启还能在这儿点，不用去开始菜单。
                   它只在"已暂存 ≠ 当前生效"时出现。 -->
              <Border x:Name="GpuRebootBtn" Background="#FF262A33" CornerRadius="11" MinWidth="72" Padding="0,5"
                      HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand" Visibility="Collapsed">
                <TextBlock Text="立即重启" Foreground="#FF98A1B3" FontSize="11" TextAlignment="Center"/>
              </Border>
              <StackPanel x:Name="GpuConfirm" Orientation="Horizontal" HorizontalAlignment="Right" Visibility="Collapsed">
                <TextBlock x:Name="GpuConfirmText" Text="" Foreground="#FFE3C86F" FontSize="11" VerticalAlignment="Center" Margin="0,0,9,0"/>
                <Border x:Name="GpuOk" Background="#FFE3C86F" CornerRadius="13" MinWidth="52" Padding="0,5" Margin="0,0,7,0" Cursor="Hand">
                  <TextBlock Text="确认" Foreground="#FF11141A" FontSize="12" FontWeight="SemiBold" TextAlignment="Center"/>
                </Border>
                <Border x:Name="GpuCancel" Background="#FF262A33" CornerRadius="13" MinWidth="52" Padding="0,5" Cursor="Hand">
                  <TextBlock Text="取消" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
              </StackPanel>
            </Grid>

            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="风扇" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="FanPillRow">
$(New-PillXaml 'Fan' $script:FanPills)
              </StackPanel>
            </Grid>
            <!-- 曲线健康度 on its OWN line. In the 800px window it sat in a third column of
                 the fan row; at 468px the pill column is 326px wide and the Auto column
                 started UNDER the third pill (measured: text at x=281, 自定义 pill 259..329),
                 so the two overlapped. Measured with diag-layout.ps1, not guessed. -->
            <TextBlock x:Name="CurveHealth" Text="" Foreground="#FF6B7385" FontSize="11" Margin="66,0,0,8"/>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="Ct2RowLabel" Grid.Column="0" Text="节点 2" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
$(New-StepperXaml 'Ct2T' '温度')
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal">
$(New-StepperXaml 'Ct2D' '转速')
              </StackPanel>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="Ct3RowLabel" Grid.Column="0" Text="节点 3" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
$(New-StepperXaml 'Ct3T' '温度')
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal">
$(New-StepperXaml 'Ct3D' '转速')
              </StackPanel>
            </Grid>

            <TextBlock x:Name="CustHint" Text="" Foreground="#FF5A6273" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>

            <TextBlock x:Name="ModeText" Text="风扇 --   ·   电源 --" Foreground="#FF8A93A6" FontSize="11.5" FontFamily="Consolas"/>
            <TextBlock x:Name="CurveText" Text="曲线 --" Foreground="#FF6B7385" FontSize="11.5" FontFamily="Consolas" Margin="0,6,0,0" LineHeight="16"/>

            <!-- 恢复初始 moved here from the title row: it is this tab's rollback button
                 (power / fan / curve / staged GPU / keyboard lighting), so it belongs next
                 to the things it undoes instead of competing with the tab buttons. -->
            <Border x:Name="RevertBtn" Background="#FF262A33" CornerRadius="13" Padding="0,6" Margin="0,12,0,0" Cursor="Hand">
              <TextBlock x:Name="RevertBtnT" Text="恢复初始（电源·风扇·曲线·显卡·键盘灯）" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
            </Border>
          </StackPanel>

          <!-- ============ 键盘灯 ============ -->
          <StackPanel x:Name="TabKb" Visibility="Collapsed">
            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="模式" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
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
              <TextBlock x:Name="LedColorLabel" Grid.Column="0" Text="颜色" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
$(New-SwatchXaml 'Rgb' $script:RgbPills)
              </StackPanel>
            </Grid>
            <TextBlock x:Name="LedColorHint" Text="" Foreground="#FF5A6273" FontSize="11" Margin="66,0,0,8"/>

            <!-- 方向：只有「波」用得到（帧里 d0 = 0xA1/0x71 + 方向），所以这一行只在选中
                 波的时候出现。提示放在按钮右边（短），不再单独占一行 —— 竖屏下这一页的
                 高度要用在色盘上（单独一行会把提示挤到色盘上面去）。 -->
            <Grid x:Name="LedDirRow" Margin="0,0,0,9" Visibility="Collapsed">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="方向" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="LedDirPillRow">
$(New-PillXaml 'Dir' $script:LedDirPills 56)
              </StackPanel>
              <TextBlock x:Name="LedDirHint" Grid.Column="2" Text="色带滚过方向" Foreground="#FF5A6273" FontSize="11" VerticalAlignment="Center"/>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="亮度" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="RgbBrightRow">
$(New-PillXaml 'RgbB' $script:RgbBrightness 56)
              </StackPanel>
            </Grid>

            <Grid Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="速度" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
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
                  <Image x:Name="ColorWheel" Width="170" Height="170" Cursor="Cross"/>
                  <Canvas x:Name="WheelLayer" Width="170" Height="170" IsHitTestVisible="False">
                    <Ellipse x:Name="WheelMark" Width="14" Height="14" Stroke="#FFEDF0F5" StrokeThickness="2"
                             Visibility="Collapsed"/>
                  </Canvas>
                </Grid>
                <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
                  <Border x:Name="WheelPick" Width="56" Height="56" CornerRadius="28" Background="#FFFFFFFF"
                          BorderBrush="#FF2B303B" BorderThickness="1"/>
                  <TextBlock x:Name="WheelText" Text="--" Foreground="#FFD7DCE6" FontSize="11" FontFamily="Consolas"
                             Margin="0,8,0,0"/>
                  <TextBlock x:Name="WheelText2" Text="" Foreground="#FF6B7385" FontSize="11" FontFamily="Consolas"
                             Margin="0,3,0,0"/>
                  <TextBlock x:Name="WheelHint" Text="取到的颜色会立刻写进键盘" Foreground="#FF5A6273" FontSize="10"
                             Margin="0,8,0,0" TextWrapping="Wrap" MaxWidth="150"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>

            <TextBlock x:Name="KbHint" Foreground="#FF6B7385" FontSize="11"
                       Text="$script:KbHintBase" TextWrapping="Wrap"/>
          </StackPanel>

          <!-- ============ 杂项 ============ -->
          <StackPanel x:Name="TabMisc" Visibility="Collapsed">
            <!-- 电池状态：让充电限制的效果就在旁边看得见（系统给的电量/供电状态），
                 和下面那行的 EC 阈值是同一件事的两头。 -->
            <Border Background="#FF1B1E25" CornerRadius="10" Padding="14,9,14,9" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="电池" Foreground="#FF7C8598" FontSize="11" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Background="#FF262A33" CornerRadius="3" Height="7" VerticalAlignment="Center" Margin="12,0,12,0">
                  <Border x:Name="BattBar" Background="#FF6FE38A" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
                </Border>
                <TextBlock Grid.Column="2" x:Name="BattText" Text="--" Foreground="#FF8A93A6" FontSize="11"
                           FontFamily="Consolas" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- 电池充电：原厂三选一。自定义时才显示阈值行（和键盘灯的颜色行同一个做法：
                 控件只在真的有用的时候出现，不用一排放着灰按钮）。 -->
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="电池充电" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChargerRow">
$(New-PillXaml 'Chg' $script:ChargerPills 74)
              </StackPanel>
            </Grid>
            <TextBlock x:Name="ChargerHint" Text="" Foreground="#FF5A6273" FontSize="11" Margin="66,0,0,8"/>

            <!-- 自定义阈值行**常驻**（用户要求）：不管当前是哪个档都看得见，
                 但只有选中「自定义」时可选中；其它档位下变暗且点不动（和风扇节点行同一个做法）。
                 这样"自定义里有什么"一眼可见，也不会出现"点开了又收回去"。 -->
            <StackPanel x:Name="ChargerCustom">
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="66"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="充电开始" x:Name="ChgStartLabel" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChgStartRow">
$(New-PillXaml 'ChgS' $script:ChargerStartPills 32)
                </StackPanel>
              </Grid>
              <Grid Margin="0,0,0,9">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="66"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="充电停止" x:Name="ChgStopLabel" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="ChgStopRow">
$(New-PillXaml 'ChgE' $script:ChargerStopPills 32)
                </StackPanel>
              </Grid>
            </StackPanel>

            <!-- 屏幕亮度已经搬到状态页（用户要求），这里不再重复 -->

$(New-SwitchRowXaml 'Tp' '触控板' $script:OnOffPills '注册表 + 原厂通知')
$(New-SwitchRowXaml 'Wk' 'Win 键' $script:EnablePills '误触不会切走游戏' 56)
$(New-SwitchRowXaml 'Fl' 'FnLock' $script:OnOffPills 'F1-F12 免按 Fn')
$(New-SwitchRowXaml 'Ws' 'Win/Fn 交换' $script:SwapPills '左下角两键对调')
$(New-SwitchRowXaml 'Nl' '数字键盘' $script:OnOffPills '系统 NumLock')
$(New-SwitchRowXaml 'Auto' '开机自启' $script:AutostartPills '登录后自动启动')
$(New-SwitchRowXaml 'Tray' '启动收进托盘' $script:OnOffPills '不弹窗口，只留托盘图标')

            <TextBlock x:Name="MiscHint" Foreground="#FF6B7385" FontSize="11" TextWrapping="Wrap"
                       Text="摄像头切换只有原厂 cc30wk.exe 这一条路（已确认），本面板不提供。所有开关显示的都是读回值，不是你刚才点的那个。"/>
          </StackPanel>

          <!-- ============ 关于 ============ -->
          <!-- 结构照用户另一个工具（SICAU-AutoLogin）的「关于」：左边圆形头像 + 名片，
               右边/下面是环境与原理。头像跟着 EXE 走（内嵌资源），没有外部文件。 -->
          <StackPanel x:Name="TabAbout" Visibility="Collapsed">
            <Border Background="#FF1B1E25" CornerRadius="10" Padding="14,12,14,12" Margin="0,0,0,12">
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
                  <TextBlock x:Name="AboutTagline" Text="--" Foreground="#FF6B7385" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Grid>
            </Border>

            <StackPanel x:Name="AboutInfo">
$(foreach ($r in $script:AboutRows) { New-AboutRowXaml ("About_" + $r.Key) $r.Label })
            </StackPanel>

            <TextBlock x:Name="AboutFeatures" Foreground="#FF8A93A6" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"
                       Text="功能：状态监控 · 电源模式 · 风扇曲线（可自定义节点） · 显卡模式（重启生效） · 键盘灯（静态/波/呼吸/循环 + 色盘取色） · 电池充电上限 · 亮度/触控板/Win 键/FnLock/数字键盘 · 托盘菜单 · 开机自启 · – / × 都是收进托盘（真退出：托盘右键 → 退出，或 Alt+F4）"/>
            <TextBlock x:Name="AboutNote" Foreground="#FF6B7385" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="原理：温度/风扇/模式/键盘灯都走原厂那条 InsydeDCHU → AcpiBridge 通道（ACPI\CLV0001），和原厂控制中心用的是同一条路；每次写入都会从硬件读回校验，状态栏绿色=一致、橙色=不一致。显卡模式是开机前值，只能重启后生效，所以本面板只暂存、不替你重启。"/>
            <!-- 只在通道坏了的时候出现：平时不重复底部状态栏已经写着的东西 -->
            <TextBlock x:Name="AboutChannelWarn" Foreground="#FFE38A6F" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                       Visibility="Collapsed"
                       Text="⚠ EC 通道当前读不到数据：温度/风扇/模式/键盘灯这些按钮都会失效。修复办法（任一）：托盘右键 → 修复 DCHU 驱动…；或运行 ClevoHelper.exe --install-driver（会弹 UAC），完成后重启面板。"/>
            <TextBlock x:Name="AboutDisclaimer" Foreground="#FF5A6273" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="个人自用工具，与蓝天（Clevo）及其代工厂无关；所有写入都基于本机实测逆向出来的协议，换机器不保证可用。"/>
          </StackPanel>

        </StackPanel>
      </Border>

      <Border Grid.Row="3" Background="#FF191C22" CornerRadius="12" Margin="16,8,16,10" Padding="16,9,16,9">
        <TextBlock x:Name="StatusText" Text="初始化…" Foreground="#FF6B7385" FontSize="11" TextWrapping="Wrap"/>
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
    'ModeText', 'CurveText', 'StatusText', 'UpdatedText', 'RevertBtn', 'RevertBtnT', 'CurveHealth', 'MinBtn',
    'GpuHeader', 'MemBar', 'MemText', 'MemPct', 'PhysDiskText',
    'GpuRow', 'GpuPillRow', 'GpuNow', 'GpuConfirm', 'GpuConfirmText', 'GpuOk', 'GpuCancel', 'GpuRebootBtn',
    'AutoRow', 'VitalsSensors', 'VitalsModes', 'TabBtnState', 'TabBtnStateT', 'TabState', 'ControlPanel', 'StatePanel',
    'TabBtnPerf', 'TabBtnPerfT', 'TabBtnKb', 'TabBtnKbT', 'TabBtnMisc', 'TabBtnMiscT', 'TabPerf', 'TabKb', 'TabMisc', 'KbHint', 'MiscHint',
    'TabBtnAbout', 'TabBtnAboutT', 'TabAbout', 'AboutAvatarBrush', 'AboutName', 'AboutTitle', 'AboutMail', 'AboutTagline',
    'AboutInfo', 'AboutNote', 'AboutFeatures', 'AboutDisclaimer', 'AboutChannelWarn',
    'LedDirRow', 'LedDirPillRow', 'LedDirHint', 'WheelText2', 'WheelHint',
    'LedModeRow', 'LedColorRow', 'LedColorHint', 'LedSpeedRow',
    'ChargerRow', 'ChargerHint', 'ChargerCustom', 'ChgStartRow', 'ChgStopRow', 'ChgStartLabel', 'ChgStopLabel',
    'ColorWheelBox', 'ColorWheel', 'WheelLayer', 'WheelMark', 'WheelPick', 'WheelText',
    'BattBar', 'BattText',
    'BrightSlider', 'BrightVal',
    'LedColorLabel', 'CustHint', 'Ct2RowLabel', 'Ct3RowLabel',
    'CpuTempUnit', 'GpuTempUnit', 'Ct2TMinus', 'Ct2TVal', 'Ct2TUnit', 'Ct2TPlus', 'Ct2DMinus', 'Ct2DVal', 'Ct2DUnit', 'Ct2DPlus',
    'Ct3TMinus', 'Ct3TVal', 'Ct3TUnit', 'Ct3TPlus', 'Ct3DMinus', 'Ct3DVal', 'Ct3DUnit', 'Ct3DPlus')
for ($i = 0; $i -lt $script:MaxVolumes; $i++) {
    $names += "Vol${i}Row"; $names += "Vol${i}Name"; $names += "Vol${i}Bar"
    $names += "Vol${i}Size"; $names += "Vol${i}Type"
}
for ($i = 0; $i -lt $script:PowerPills.Count; $i++) { $names += "Pwr$i"; $names += "Pwr${i}T" }
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
for ($i = 0; $i -lt $script:LedDirPills.Count; $i++) { $names += "Dir$i"; $names += "Dir${i}T" }
foreach ($k in $names) { $n[$k] = $script:Win.FindName($k) }

# 标题栏拖动。**必须放过最小化/关闭按钮**：DragMove() 是一个模态的拖动循环，鼠标按下
# 之后消息都由它接管 —— 如果按在最小化按钮上还把事件转发给标题栏，随后的
# MouseLeftButtonUp 就到不了按钮（这正是"最小化点了没反应"的根因；× 是 Down 绑定，
# 它在冒泡到标题栏之前就已经生效了，所以一直是好的）。
# 判据用两条：真鼠标点在按钮上（IsMouseOver），以及事件源在按钮子树里（OriginalSource
# 往上走）—— 后者在自检造合成事件时也成立，不依赖真实光标位置。
function Test-InTitleButton($src) {
    if ($n.MinBtn.IsMouseOver -or $n.CloseBtn.IsMouseOver) { return $true }
    $cur = $src
    $guard = 0
    while ($cur -and $guard -lt 40) {
        $guard++
        if ($cur -eq $n.MinBtn -or $cur -eq $n.CloseBtn -or $cur -eq $n.TitleIcon) { return $true }
        try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { $cur = $null }
    }
    return $false
}
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
$n.CloseBtn.Add_MouseLeave({ $n.CloseBtn.Foreground = Get-Brush '#FF7C8598' })
$n.RevertBtn.Add_MouseEnter({ $n.RevertBtn.Background = Get-Brush '#FF30353F' })
$n.RevertBtn.Add_MouseLeave({ $n.RevertBtn.Background = Get-Brush '#FF262A33' })

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
# the 杂项 tab's state is read on a slower cadence than the sensors (once a second, and only
# while that tab is on screen): brightness goes through WMI and the touchpad through the
# registry, and neither is worth a query every 250 ms
$script:Sync.WantMisc = $false
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
try {
    . $script:DchuPath
    $t0 = Get-ClevoTelemetry
    $script:Sync.StartState = [pscustomobject]@{
        PowerMode = $t0.PowerMode; FanMode = $t0.FanMode; FanOffset = $t0.FanOffset
        GpuMode   = $(if ($script:GpuInfo) { $script:GpuInfo.Mode } else { 0 })
    }
    Write-Dbg ("panel start state: power={0} fan={1} offset={2} gpu={3}" -f `
        $t0.PowerMode, $t0.FanMode, $t0.FanOffset, $script:Sync.StartState.GpuMode)
    Write-Dbg ('dchu dll: ' + $script:DchuDll)
}
catch { $script:Sync.StartState = $null; Write-Dbg ('start state failed: ' + $_.Exception.Message) }

function Request-Write {
    param([int]$Mode, [string]$Kind)
    $script:Sync.Pending = [pscustomobject]@{ Mode = $Mode; Kind = $Kind; At = (Get-Date) }
    if ($Kind -eq 'restore') { $n.StatusText.Text = '正在恢复初始设置…' } else { $n.StatusText.Text = '正在切换…' }
}

for ($i = 0; $i -lt $script:PowerPills.Count; $i++) {
    $mode = $script:PowerPills[$i].Id
    $n["Pwr$i"].Add_MouseLeftButtonUp({ Request-Write -Mode $mode -Kind 'power' }.GetNewClosure())
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
function Set-GpuStage([int]$Mode) {
    $cur = $(if ($script:Sync.Snapshot) { [int]$script:Sync.Snapshot.GpuMode } else { -1 })
    $staged = [int]$(if ($script:Sync.Snapshot) { $script:Sync.Snapshot.GpuStaged } else { 0 })
    # 只有"既没暂存过、点的又是当前模式"才是真的没事可做。**一旦暂存过别的模式，点当前模式
    # 那一颗就是"撤销暂存"** —— 否则用户暂存了核显又反悔，就只能靠 [恢复初始] 才能拉回来
    # （自检就撞上了这个：想暂存回独显，点了没反应，最后 EC 里留着的还是核显）。
    if ($cur -eq $Mode -and $staged -eq 0) {
        $n.StatusText.Text = ('当前已经是「{0}」，无需切换' -f $script:GpuModeName[$Mode])
        $n.StatusText.Foreground = Get-Brush '#FF6B7385'
        return
    }
    $script:GpuStage = $Mode
    $n.GpuNow.Visibility = 'Collapsed'
    $n.GpuConfirm.Visibility = 'Visible'
    $n.GpuConfirmText.Text = $(if ($Mode -eq $cur) {
            ('撤销暂存、回到「{0}」？重启后生效' -f $script:GpuModeName[$Mode])
        }
        else { ('切到「{0}」？重启后生效' -f $script:GpuModeName[$Mode]) })
}
function Confirm-GpuStage {
    $m = [int]$script:GpuStage
    $script:GpuStage = 0
    $n.GpuConfirm.Visibility = 'Collapsed'
    $n.GpuNow.Visibility = 'Visible'
    if ($m -gt 0) { Request-Write -Mode $m -Kind 'gpu' }
}
function Cancel-GpuStage {
    $script:GpuStage = 0
    $n.GpuConfirm.Visibility = 'Collapsed'
    $n.GpuNow.Visibility = 'Visible'
    $n.StatusText.Text = '已取消，没有写入任何东西'
    $n.StatusText.Foreground = Get-Brush '#FF6B7385'
}
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
        $n.StatusText.Foreground = Get-Brush '#FF6B7385'
    }
})

function Request-Rgb {
    param([int]$R, [int]$G, [int]$B, [int]$Brightness = -1)
    $script:Sync.Pending = [pscustomobject]@{ Kind = 'rgb'; R = $R; G = $G; B = $B; Brightness = $Brightness; At = (Get-Date) }
    $n.StatusText.Text = '正在设置键盘灯…（整键盘重绘约 0.3 秒）'
}

# ---- 键盘灯：模式驱动 ------------------------------------------------------
# One "current selection" drives everything: picking a colour or a speed re-sends the whole
# selection, so the effect changes colour live instead of needing a "apply" button.
function Request-Led {
    $sel = $script:LedSel
    # The wheel's colour wins only while the user is in "custom" mode: clicking a preset
    # swatch clears UseCustom, so the two ways of choosing a colour never fight.
    if ($sel.UseCustom) {
        $c = [pscustomobject]@{ R = [int]$sel.Custom.R; G = [int]$sel.Custom.G; B = [int]$sel.Custom.B }
    }
    else {
        $c = $script:RgbPills[[int]$sel.Color]
    }
    $c2 = $script:RgbPills[[int]$sel.Color2]
    $script:Sync.Pending = [pscustomobject]@{
        Kind = 'led'
        Mode = [string]$sel.Mode
        ModeLabel = [string]$script:LedModePills[[int]$sel.ModeIdx].Label
        # No mode offered here is directional or two-coloured any more, so these stay at their
        # defaults and are never edited from the UI - they are still sent because the sampler's
        # frame builder takes them (kbled.ps1 keeps the full vendor protocol).
        Dir = [int]$sel.Dir
        R = [int]$c.R; G = [int]$c.G; B = [int]$c.B
        R2 = [int]$c2.R; G2 = [int]$c2.G; B2 = [int]$c2.B
        Rainbow = [bool]$sel.Rainbow
        Bright = [int]$script:RgbBrightness[[int]$sel.Bright].Level
        Speed = [int]$script:LedSpeedPills[[int]$sel.Speed].Level
        At = (Get-Date)
    }
    $n.StatusText.Text = ('正在应用键盘灯：{0} …' -f $script:LedModePills[[int]$sel.ModeIdx].Label)
}

# ---- 杂项：每一项都是「写 + 读回」 ------------------------------------------
# One request kind with a Sub field, because the four channels behind it are unrelated
# (DCHU byte frame, DCHU cmd 0x19, registry+hotkey, WMI). The sampler owns the write and
# the read-back, exactly like every other control in this panel.
function Request-Misc([string]$Sub, $Value) {
    $script:Sync.Pending = [pscustomobject]@{ Kind = 'misc'; Sub = $Sub; Value = $Value; At = (Get-Date) }
    $what = switch ($Sub) {
        'charger'  { '电池充电' }
        'start'    { '充电开始电量' }
        'stop'     { '充电停止电量' }
        'bright'   { '屏幕亮度' }
        'touchpad' { '触控板' }
        'winkey'   { 'Win 键' }
        'fnlock'   { 'FnLock' }
        'winfn'    { 'Win/Fn 交换' }
        'numlock'  { '数字键盘' }
        default    { $Sub }
    }
    $n.StatusText.Text = ('正在设置{0}…' -f $what)
    $n.StatusText.Foreground = Get-Brush '#FF6B7385'
}

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
        }
    }.GetNewClosure())
}
for ($i = 0; $i -lt $script:ChargerStartPills.Count; $i++) {
    $v = [int]$script:ChargerStartPills[$i].Id
    $n["ChgS$i"].Add_MouseLeftButtonUp({
        $script:MiscSel.Start = $v
        Request-Misc -Sub 'start' -Value ([pscustomobject]@{ Start = $v; Stop = [int]$script:MiscSel.Stop })
    }.GetNewClosure())
}
for ($i = 0; $i -lt $script:ChargerStopPills.Count; $i++) {
    $v = [int]$script:ChargerStopPills[$i].Id
    $n["ChgE$i"].Add_MouseLeftButtonUp({
        $script:MiscSel.Stop = $v
        Request-Misc -Sub 'stop' -Value ([pscustomobject]@{ Start = [int]$script:MiscSel.Start; Stop = $v })
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
# 选了颜色以后该做什么：当前模式用颜色就立刻写，不用（关闭/循环）就只记住并说清楚。
# 以前无论如何都发一次写入，模式是「关闭」时那就是"点了没反应" —— 现在两种情况都说得明白。
function Update-LedColorSelection {
    $mi = [int]$script:LedSel.ModeIdx
    $mp = $(if ($mi -ge 0 -and $mi -lt $script:LedModePills.Count) { $script:LedModePills[$mi] } else { $script:LedModePills[0] })
    if ([int]$mp.Colors -ge 1) { Request-Led }
    else {
        $n.StatusText.Text = ('已记住颜色；「{0}」不用颜色，切到 静态/波/呼吸 立刻生效' -f $mp.Label)
        $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
    }
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
function Set-LedFromWheel([double]$x, [double]$y) {
    $size = [int]$script:WheelSize
    $p = [ClevoHelper.ColorWheel]::Pick($x, $y, $size)
    if ($null -eq $p) { return }         # outside the circle: nothing to pick
    $script:LedSel.Custom = @{ R = [int]$p[0]; G = [int]$p[1]; B = [int]$p[2] }
    $script:LedSel.UseCustom = $true
    $script:LedSel.Rainbow = $false      # picking a colour means "not multi-colour"
    $script:WheelHue = [int]$p[3]; $script:WheelSat = [int]$p[4]
    Update-LedColorSelection
}
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
function Set-Autostart([bool]$On) {
    try {
        if ($On) {
            $r = Enable-Autostart
            $where = $(if ($r.Installed) { $r.Installed } else { '(没找到可复制的 exe，启动时会去候选路径里找)' })
            $n.StatusText.Text = ('开机自启已开启：程序已放到 {0}，下次登录从那里启动、直接进托盘' -f $where)
        }
        else {
            [void](Disable-Autostart)
            $n.StatusText.Text = '开机自启已关闭。'
        }
        $n.StatusText.Foreground = Get-Brush '#FF6FE38A'
    }
    catch {
        $n.StatusText.Text = '设置开机自启失败：' + $_.Exception.Message
        $n.StatusText.Foreground = Get-Brush '#FFE38A6F'
    }
    $script:AutostartOn = Get-AutostartState
}
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
$n.TabBtnMisc.Add_MouseLeftButtonUp({ $script:LedSel.Tab = 'misc' })
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

function Request-FanCurve {
    # sends the current 自定义 node values (percent) - no preset index any more
    $src = $script:FanCustom
    $script:Sync.Pending = [pscustomobject]@{
        Kind = 'curve'; Label = '自定义'
        T2 = [int]$src.T2; D2 = [int]$src.D2; T3 = [int]$src.T3; D3 = [int]$src.D3
        D1 = [int]$script:FixedFirstDuty; At = (Get-Date)
    }
    $script:LedSel.FanIdx = $script:FanCustomIndex
    # 你按下去的这一套就是"我的配置"：写进 settings.json，下次启动直接用它（不再读 EC 的当前值）
    Save-FanCurve
    $n.StatusText.Text = '正在写风扇曲线「自定义」…（约 1 秒）'
}
$script:FanCustomIndex = 2   # index of the 自定义 pill
for ($i = 0; $i -lt $script:FanPills.Count; $i++) {
    $p = $script:FanPills[$i]
    if ($p.ContainsKey('Curve')) {
        $n["Fan$i"].Add_MouseLeftButtonUp({ Request-FanCurve })
    }
    else {
        $mode = [int]$p.Mode
        $n["Fan$i"].Add_MouseLeftButtonUp({ Request-Write -Mode $mode -Kind 'fan' }.GetNewClosure())
    }
}

# ---- 自定义曲线的四个数字（两个可调节点） ------------------------------------
# Only editable while 自定义 is the selected fan mode - the rows grey out otherwise, so it is
# obvious that 自动/最大 ignore them.
function Step-FanCustom([string]$Field, [int]$Delta) {
    if ($script:Sync.Snapshot -and $script:Sync.Snapshot.FanMode -ne 6) { return }
    $lim = $script:FanLimits
    $v = [int]$script:FanCustom[$Field] + $Delta
    switch ($Field) {
        'T2' { $v = [Math]::Max($lim.TMin, [Math]::Min([int]$script:FanCustom.T3 - $lim.Step, $v)) }
        'T3' { $v = [Math]::Max([int]$script:FanCustom.T2 + $lim.Step, [Math]::Min($lim.TMax, $v)) }
        'D2' { $v = [Math]::Max($lim.DMin, [Math]::Min([int]$script:FanCustom.D3, $v)) }
        'D3' { $v = [Math]::Max([int]$script:FanCustom.D2, [Math]::Min($lim.DMax, $v)) }
    }
    $script:FanCustom[$Field] = $v
    Request-FanCurve
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
                        $S.LastWrite = [pscustomobject]@{ Ok = ($r1.Ok -and $r2.Ok); Msg = ('已恢复初始：电源={0} 风扇={1}{2}{3}' -f $r1.ReadBack, $r2.ReadBack, $g, $kb); At = (Get-Date) }
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

function Start-Sampler {
    <#
      .SYNOPSIS (Re)create the sampler runspace. Safe to call repeatedly.
      .NOTES    A runspace that faults or exits leaves the UI showing stale numbers
                forever, so Update-Panel watches the handle and restarts it.
    #>
    $script:Rs = [runspacefactory]::CreateRunspace()
    $script:Rs.ApartmentState = 'MTA'
    $script:Rs.ThreadOptions = 'ReuseThread'
    $script:Rs.Open()
    $script:Ps = [powershell]::Create()
    $script:Ps.Runspace = $script:Rs
    [void]$script:Ps.AddScript($sampler).AddArgument($script:Sync)
    $script:Handle = $script:Ps.BeginInvoke()
}

function Test-Sampler {
    param([switch]$Silent)
    if ($script:Sync.Stop) { return }
    if ($null -ne $script:Handle -and $script:Handle.IsCompleted) {
        if (-not $Silent) { Write-Dbg 'SAMPLER DIED - restarting it' }
        try { $script:Ps.Stop() } catch { }
        try { $script:Rs.Close() } catch { }
        $script:Sync.Snapshot = $null
        $script:Sync.Hist = @()
        Start-Sampler
        $script:Sync.Restarts = 1 + [int]$script:Sync.Restarts
        $script:Sync.LastWrite = [pscustomobject]@{
            Ok = $false; At = (Get-Date)
            Msg = ('采样器曾中断，已自动重启（第 {0} 次）' -f $script:Sync.Restarts)
        }
        return $true
    }
    return $false
}

Start-Sampler

# ------------------------------------------------------------------- paint ---
# Explicit brush conversion: do not rely on implicit string -> Brush coercion in
# property assignments, it can fail silently inside event handlers.
$script:BrushCache = @{}
function Get-Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $script:BrushCache[$hex] = [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    }
    return $script:BrushCache[$hex]
}

function Format-GB([double]$bytes) {
    $gb = $bytes / 1GB
    if ($gb -ge 1024) { return ('{0:N2} TB' -f ($gb / 1024)) }
    if ($gb -ge 100) { return ('{0:N0} GB' -f $gb) }
    return ('{0:N1} GB' -f $gb)
}
function Set-Pill($border, $text, [bool]$on, [string]$accent) {
    if ($on) {
        $border.Background = Get-Brush $accent
        $text.Foreground = Get-Brush '#FF11141A'
        $text.FontWeight = 'SemiBold'
    }
    else {
        $border.Background = Get-Brush '#FF262A33'
        $text.Foreground = Get-Brush '#FF98A1B3'
        $text.FontWeight = 'Normal'
    }
}

function Update-Panel {
  try {
    $s = $script:Sync.Snapshot
    if ($null -eq $s) {
        if ($script:Sync.Pending) { $n.StatusText.Text = '正在切换…' }
        else { $n.StatusText.Text = '等待首次采样…' }
        return
    }
    if ($s.CpuTemp) {
        $n.CpuTemp.Text = [string]$s.CpuTemp
        $n.CpuRpm.Text = '{0:N0} RPM' -f $s.CpuFanRpm
        $n.CpuDutyText.Text = '{0}%' -f $s.CpuFanDuty
        $n.CpuBar.Width = [Math]::Round(104 * $s.CpuFanDuty / 100)
        $n.GpuTemp.Text = [string]$s.GpuTemp
        $n.GpuRpm.Text = '{0:N0} RPM' -f $s.GpuFanRpm
        $n.GpuDutyText.Text = '{0}%' -f $s.GpuFanDuty
        $n.GpuBar.Width = [Math]::Round(104 * $s.GpuFanDuty / 100)
        $script:Win.Title = 'ClevoHelper - {0}C / {1}C' -f $s.CpuTemp, $s.GpuTemp
    }
    if ($s.CpuMhz) { $n.CpuFreq.Text = '{0:N2} GHz' -f ($s.CpuMhz / 1000) } else { $n.CpuFreq.Text = '--' }
    if ($null -ne $s.CpuWatts) { $n.CpuPower.Text = '{0:N0} W' -f $s.CpuWatts } else { $n.CpuPower.Text = '--' }
    if ($s.GpuMhz) { $n.GpuFreq.Text = '{0:N0} MHz' -f $s.GpuMhz } else { $n.GpuFreq.Text = '--' }
    if ($null -ne $s.GpuWatts) { $n.GpuPower.Text = '{0:N0} W' -f $s.GpuWatts } else { $n.GpuPower.Text = '--' }
    if ($null -ne $s.CpuUtil) { $n.CpuUtil.Text = '{0}%' -f $s.CpuUtil } else { $n.CpuUtil.Text = '--' }
    if ($null -ne $s.GpuUtil) { $n.GpuUtil.Text = '{0}%' -f $s.GpuUtil } else { $n.GpuUtil.Text = '--' }
    if ($s.GpuModeName) { $n.GpuHeader.Text = 'GPU · RTX 4080 Laptop   ·   显卡模式 ' + $s.GpuModeName }
    # say where the GPU numbers come from: NVML in-process, or the nvidia-smi fallback
    $n.GpuHeader.ToolTip = $(if ($s.GpuSensor -eq 'nvml') { 'GPU 数据来自 nvml.dll（进程内直读，不依赖 nvidia-smi 程序）' }
        elseif ($s.GpuSensor -eq 'smi') { 'GPU 数据来自 nvidia-smi（NVML 不可用时的备用通道）' }
        else { 'GPU 数据不可用' })

    # ---- 内存 ----
    $totMB = [int]$script:Sync.TotalRamMB
    if ($totMB -gt 0 -and $null -ne $s.RamFreeMB) {
        $usedMB = $totMB - [int]$s.RamFreeMB
        $pct = [Math]::Max(0, [Math]::Min(100, [Math]::Round(100.0 * $usedMB / $totMB)))
        $n.MemBar.Width = [Math]::Round($script:BarWidth * $pct / 100)
        # portrait: the long '已用 x / y GB · 可用 z GB' no longer fits on one line, so the
        # row shows the used/total part and keeps the whole sentence in the tooltip
        $n.MemText.Text = '已用 {0:N1} / {1:N1} GB' -f ($usedMB / 1024), ($totMB / 1024)
        $n.MemText.ToolTip = '已用 {0:N1} GB / 共 {1:N1} GB   ·   可用 {2:N1} GB' -f ($usedMB / 1024), ($totMB / 1024), ($s.RamFreeMB / 1024)
        $n.MemPct.Text = '{0}%' -f $pct
        # bar and percentage share one colour code: violet normally, amber >= 75%, orange >= 90%
        $memColor = if ($pct -ge 90) { '#FFE38A6F' } elseif ($pct -ge 75) { '#FFE3C86F' } else { '#FFB98BFF' }
        $n.MemBar.Background = Get-Brush $memColor
        $n.MemPct.Foreground = Get-Brush $memColor
    }
    else { $n.MemBar.Width = 0; $n.MemText.Text = '--'; $n.MemPct.Text = '' }

    # ---- 存储 ----
    $vols = @($s.Volumes)
    for ($i = 0; $i -lt $script:MaxVolumes; $i++) {
        $row = $n["Vol${i}Row"]
        if ($i -lt $vols.Count) {
            $v = $vols[$i]
            $row.Visibility = 'Visible'
            $lbl = if ($v.Label) { "$($v.Name)  $($v.Label)" } else { $v.Name }
            $n["Vol${i}Name"].Text = $lbl
            $n["Vol${i}Name"].ToolTip = $lbl
            $used = $v.Total - $v.Free
            $pct = if ($v.Total -gt 0) { [Math]::Round(100.0 * $used / $v.Total) } else { 0 }
            $n["Vol${i}Bar"].Width = [Math]::Round($script:BarWidth * $pct / 100)
            $barColor = if ($pct -ge 90) { '#FFE38A6F' } elseif ($pct -ge 75) { '#FFE3C86F' } else { '#FF57B0FF' }
            $n["Vol${i}Bar"].Background = Get-Brush $barColor
            # portrait form: '414 / 954 GB'; the sentence with 可用 is the tooltip
            $n["Vol${i}Size"].Text = '{0} / {1}' -f (Format-GB $used), (Format-GB $v.Total)
            $n["Vol${i}Size"].ToolTip = '已用 {0} / {1}   ·   可用 {2}' -f (Format-GB $used), (Format-GB $v.Total), (Format-GB $v.Free)
            $n["Vol${i}Type"].Text = '{0}%' -f $pct
            $n["Vol${i}Type"].Foreground = Get-Brush $barColor
        }
        else { $row.Visibility = 'Collapsed' }
    }
    $pd = @($script:Sync.PhysDisks)
    if ($pd.Count) {
        $n.PhysDiskText.Text = '物理磁盘 {0}: ' -f $pd.Count
        $n.PhysDiskText.Text += (($pd | ForEach-Object { '{0} {1}' -f $_.Model, (Format-GB ($_.GB * 1GB)) }) -join '   ·   ')
    }

    $powerActive = ''
    for ($i = 0; $i -lt $script:PowerPills.Count; $i++) {
        $on = ($null -ne $s.PowerMode -and $s.PowerMode -eq $script:PowerPills[$i].Id)
        if ($on) { $powerActive = $script:PowerPills[$i].Label }
        Set-Pill $n["Pwr$i"] $n["Pwr${i}T"] $on '#FF57B0FF'
    }
    $kbActive = ''
    $kbOffered = $false
    if ($s.LedMode) {
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            if ($script:LedModePills[$i].Key -eq $s.LedMode) { $kbActive = $script:LedModePills[$i].Label; $kbOffered = $true; break }
        }
        # the EC can hold a mode this panel no longer offers (e.g. 波浪 set by the factory
        # app) - name it from the full table rather than leaving the strip blank
        if (-not $kbOffered -and $script:LedModeLabelAll.ContainsKey([string]$s.LedMode)) {
            $kbActive = $script:LedModeLabelAll[[string]$s.LedMode]
        }
    }
    # Sync the keyboard-tab selection with the EC's persisted mode ONCE, on the first
    # snapshot. Without this the pills claimed 静态 while the strip (reading the real
    # AppSettings) said 波浪 - two different answers to the same question on one screen.
    # After the first sync our own clicks drive it; the strip keeps showing EC truth.
    if (-not $script:LedSynced -and $s.LedMode) {
        $found = $false
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            if ($script:LedModePills[$i].Key -eq $s.LedMode) { $script:LedSel.ModeIdx = $i; $script:LedSel.Mode = $s.LedMode; $found = $true; break }
        }
        # EC holds a mode this panel does not offer: light NO pill rather than lighting a
        # wrong one, and remember the real mode so the footer can say so
        if (-not $found) { $script:LedSel.ModeIdx = -1; $script:LedSel.Mode = [string]$s.LedMode }
        if ($s.LedColor) {
            for ($i = 0; $i -lt $script:RgbPills.Count; $i++) {
                $c = $script:RgbPills[$i]
                if ($c.R -eq $s.LedColor[0] -and $c.G -eq $s.LedColor[1] -and $c.B -eq $s.LedColor[2]) { $script:LedSel.Color = $i; break }
            }
        }
        $script:LedSynced = $true
    }
    # ---- 风扇：三颗按钮，自定义只在 EC 模式 6 时亮 ----
    # The curve presets are gone, so a pill no longer needs to be matched against block 13:
    # 自动 = mode 0, 最大 = mode 1, 自定义 = mode 6 (whatever table is loaded).
    $fanActive = ''
    for ($i = 0; $i -lt $script:FanPills.Count; $i++) {
        $p = $script:FanPills[$i]
        if ($p.ContainsKey('Curve')) {
            $on = ($s.FanMode -eq 6)
            if ($on) { $fanActive = $p.Label; if ([int]$script:LedSel.FanIdx -ne $i) { $script:LedSel.FanIdx = $i } }
        }
        else {
            $on = ($null -ne $s.FanMode -and $s.FanMode -eq [int]$p.Mode)
            if ($on) { $fanActive = $p.Label; if ([int]$script:LedSel.FanIdx -ne $i) { $script:LedSel.FanIdx = $i } }
        }
        Set-Pill $n["Fan$i"] $n["Fan${i}T"] $on '#FF6FE38A'
    }
    # 只有在"用户还没配过自己的曲线"时，才从 EC 的当前表读一次作为编辑器的起点 —— 而且
    # **吸附到 5 的倍数**（EC 里是 60/38、86/59 这种值，界面上点不出来）。
    # 用户配过的话，启动时就已经用他那份了（FanSeeded 早就是 $true）。
    if (-not $script:FanSeeded -and $s.RuntimeT) {
        [void](Set-FanCustomSafe @{
                T2 = [int]$s.RuntimeT[1]
                T3 = [int]$s.RuntimeT[2]
                D2 = [int][Math]::Round(100.0 * $s.RuntimeRaw[1] / 255)
                D3 = [int][Math]::Round(100.0 * $s.RuntimeRaw[2] / 255)
            })
        $script:FanSeeded = $true
        $script:FanCurveSource = 'ec'
        Write-Dbg ('fan curve seeded from EC then snapped to Step {0}: T2={1} D2={2} T3={3} D3={4}' -f `
            $script:FanLimits.Step, $script:FanCustom.T2, $script:FanCustom.D2, $script:FanCustom.T3, $script:FanCustom.D3)
    }

    # 启动时**按"我的配置"来**（用户要求：每次启动照我之前的配置，别读当前那份）。
    # 这一步只做一件事：如果 EC 现在跑的表和你的配置不一样，就把它写回去 —— 但**只在 EC 已经
    # 处于自定义模式（6）时**。你选了自动/最大，就说明你要它自己的逻辑，这时候绝不插手
    # （否则"重启一次风扇又变回自定义"会变成另一种烦人）。每次启动只做一次。
    if (-not $script:FanAppliedOnStart -and $script:FanCurveSource -eq 'settings' -and
        $s.FanMode -eq 6 -and $s.RuntimeT) {
        $script:FanAppliedOnStart = $true
        $same = ($s.RuntimeRaw[1] -eq (Convert-DutyPctToRaw $script:FanCustom.D2) -and
                 $s.RuntimeRaw[2] -eq (Convert-DutyPctToRaw $script:FanCustom.D3) -and
                 [int]$s.RuntimeT[1] -eq [int]$script:FanCustom.T2 -and
                 [int]$s.RuntimeT[2] -eq [int]$script:FanCustom.T3)
        if ($same) { Write-Dbg 'fan curve: EC 正在跑的就是你的配置，启动时无需写入' }
        else {
            Write-Dbg ('fan curve: 启动时按你的配置写回 EC（EC 现在是 {0}°C/{1}% {2}°C/{3}%，你的配置是 {4}°C/{5}% {6}°C/{7}%）' -f `
                $s.RuntimeT[1], $s.RuntimeD[1], $s.RuntimeT[2], $s.RuntimeD[2],
                $script:FanCustom.T2, $script:FanCustom.D2, $script:FanCustom.T3, $script:FanCustom.D3)
            Request-FanCurve
        }
    }
    # the node editor is only live while the EC is actually running a custom table (mode 6) -
    # greyed out and non-clickable in 自动/最大. Read from the EC, not from the last click:
    # the hardware state is the truth, and the pills are synced from it above.
    $customOn = ($s.FanMode -eq 6)
    $editOpacity = $(if ($customOn) { 1.0 } else { 0.35 })
    foreach ($pre in 'Ct2T', 'Ct2D', 'Ct3T', 'Ct3D') {
        $n["${pre}Minus"].IsEnabled = $customOn
        $n["${pre}Plus"].IsEnabled = $customOn
        $n["${pre}Val"].Opacity = $editOpacity
        $n["${pre}Unit"].Opacity = $editOpacity
    }
    $n.Ct2RowLabel.Opacity = $editOpacity
    $n.Ct3RowLabel.Opacity = $editOpacity

    # ---- 自定义曲线的四个数字 ----
    # number and unit live in separate fixed-width boxes; only the number changes
    $n.Ct2TVal.Text = '{0}' -f $script:FanCustom.T2
    $n.Ct2DVal.Text = '{0}' -f $script:FanCustom.D2
    $n.Ct3TVal.Text = '{0}' -f $script:FanCustom.T3
    $n.Ct3DVal.Text = '{0}' -f $script:FanCustom.D3
    $n.Ct2DUnit.Text = '%'; $n.Ct3DUnit.Text = '%'
    # 说清楚这两行到底是"谁的"曲线：用户自己配的那份（存 settings.json，重启面板也在）还是
    # 从 EC 当前表吸附来的。以前这里没写，用户看到 60/38、86/59 会以为"我配的丢了"。
    $n.CustHint.Text = $(if ($script:FanCurveSource -eq 'settings') {
            '节点 1 = 40°C/28%、节点 4 = 100°C/100% 由 EC 固定；这两行是你保存的曲线（存在 settings.json，重启面板也在），只能按 5 调'
        }
        else {
            '节点 1 = 40°C/28%、节点 4 = 100°C/100% 由 EC 固定；这两行暂时是"EC 当前表吸附到 5 的倍数"——你按一次自定义/加减就会存成你自己的配置'
        })

    # ---- 显卡 ----
    # No pills (probe failed / EC reports no switchable modes) => hide the whole row rather
    # than offer buttons that cannot work. When a mode has been staged but not rebooted, say
    # so next to the active mode - the two are different things and must not be conflated.
    if ($script:GpuPills.Count -gt 0 -and $null -ne $s.GpuMode) {
        $n.GpuRow.Visibility = 'Visible'
        for ($i = 0; $i -lt $script:GpuPills.Count; $i++) {
            Set-Pill $n["Gpu$i"] $n["Gpu${i}T"] ($s.GpuMode -eq $script:GpuPills[$i].Id) '#FFB98BFF'
        }
        $staged = [int]$s.GpuStaged
        if ($staged -gt 0 -and $staged -ne $s.GpuMode -and $script:GpuModeName.ContainsKey($staged)) {
            $n.GpuNow.Text = '当前 {0}   ·   已暂存 {1}，重启生效' -f $s.GpuModeName, $script:GpuModeName[$staged]
            $n.GpuNow.Foreground = Get-Brush '#FFE3C86F'
            # 有暂存就顺手给一个「立即重启」的入口：重启申请弹窗关掉之后（或者用户当时选了
            # "稍后"），想马上重启还能在这儿点一下，不必去开始菜单找。
            $n.GpuRebootBtn.Visibility = 'Visible'
        }
        else {
            $n.GpuNow.Text = '当前 {0}' -f $s.GpuModeName
            $n.GpuNow.Foreground = Get-Brush '#FF6B7385'
            $n.GpuRebootBtn.Visibility = 'Collapsed'
        }
    }
    else { $n.GpuRow.Visibility = 'Collapsed'; $n.GpuRebootBtn.Visibility = 'Collapsed' }

    # ---- 标签页 ----
    # FOUR tabs, and every one of them gets the same-sized box: 状态 lives in StatePanel and
    # the other three share ControlPanel, whose height/padding/margins are identical. So the
    # window never resizes when tabs are switched (user request: 四个界面长宽一样).
    $tab = [string]$script:LedSel.Tab
    $n.TabState.Visibility = $(if ($tab -eq 'state') { 'Visible' } else { 'Collapsed' })
    $n.StatePanel.Visibility = $(if ($tab -eq 'state') { 'Visible' } else { 'Collapsed' })
    $n.TabPerf.Visibility = $(if ($tab -eq 'perf') { 'Visible' } else { 'Collapsed' })
    $n.TabKb.Visibility = $(if ($tab -eq 'kb') { 'Visible' } else { 'Collapsed' })
    $n.TabMisc.Visibility = $(if ($tab -eq 'misc') { 'Visible' } else { 'Collapsed' })
    $n.TabAbout.Visibility = $(if ($tab -eq 'about') { 'Visible' } else { 'Collapsed' })
    $n.ControlPanel.Visibility = $(if ($tab -eq 'state') { 'Collapsed' } else { 'Visible' })
    Set-Pill $n.TabBtnState $n.TabBtnStateT ($tab -eq 'state') '#FFB98BFF'
    Set-Pill $n.TabBtnPerf $n.TabBtnPerfT ($tab -eq 'perf') '#FFB98BFF'
    Set-Pill $n.TabBtnKb $n.TabBtnKbT ($tab -eq 'kb') '#FFB98BFF'
    Set-Pill $n.TabBtnMisc $n.TabBtnMiscT ($tab -eq 'misc') '#FFB98BFF'
    Set-Pill $n.TabBtnAbout $n.TabBtnAboutT ($tab -eq 'about') '#FFB98BFF'
    # the sampler only reads the 杂项 channels while that page is the one on screen
    $script:Sync.WantMisc = ($tab -eq 'misc')
    # 状态页只要一个亮度值（滑杆在那里），所以单独给它一路轻量读取：没必要为了一个数字
    # 把触控板/电池/充电器都拉一遍，那会把采样周期拖慢。
    $script:Sync.WantBright = ($tab -eq 'state')
    # DCHU 通道坏了 → 托盘里的"修复 DCHU 驱动…"亮起来（正常时灰着，不干扰）
    if ($script:TrayFixItem) {
        try { $script:TrayFixItem.Enabled = [bool]$s.Err } catch { }
    }
    for ($i = 0; $i -lt $script:AutostartPills.Count; $i++) {
        # read the real state instead of a cached flag: the exe can toggle it from the CLI
        # while the panel is open, and a stale pill would be a lie
        Set-Pill $n["Auto$i"] $n["Auto${i}T"] ([bool]$script:AutostartPills[$i].On -eq (Get-AutostartState)) '#FF6FE38A'
    }

    # ---- 常显信息条 ----
    # Two lines that stay visible on every tab: the sensors, and the active choices. Both are
    # monospace with FIXED-WIDTH fields ({0,5} etc.). Proportional text made every later field
    # slide sideways whenever a digit count changed (4,998 -> 5,126 RPM), which reads as "the
    # text is not aligned". The two lines are also what made an 800px-wide strip possible;
    # in the portrait window the same text simply wraps into two shorter lines.
    $n.VitalsSensors.Text = 'CPU {0,3}°C {1,6:N0} RPM {2,3}% {3,5}W' -f `
        $s.CpuTemp, $s.CpuFanRpm, $(if ($null -ne $s.CpuUtil) { $s.CpuUtil } else { '--' }),
        $(if ($null -ne $s.CpuWatts) { '{0:N0}' -f $s.CpuWatts } else { '--' })
    $n.VitalsModes.Text = 'GPU {0,3}°C {1,6:N0} RPM {2,3}%   ·   {3} · {4} · {5} · {6}' -f `
        $s.GpuTemp, $s.GpuFanRpm, $(if ($null -ne $s.GpuUtil) { $s.GpuUtil } else { '--' }),
        $(if ($powerActive) { $powerActive } else { $s.PowerModeName }),
        $(if ($fanActive) { $fanActive } else { $s.FanModeName }),
        $s.GpuModeName,
        $(if ($kbActive) { $kbActive } else { '—' })

    if ($tab -eq 'kb') {
        $sel = $script:LedSel
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            Set-Pill $n["Led$i"] $n["Led${i}T"] ($i -eq [int]$sel.ModeIdx) '#FFB98BFF'
        }
        for ($i = 0; $i -lt $script:RgbBrightness.Count; $i++) {
            Set-Pill $n["RgbB$i"] $n["RgbB${i}T"] ($i -eq [int]$sel.Bright) '#FFB98BFF'
        }
        for ($i = 0; $i -lt $script:LedSpeedPills.Count; $i++) {
            Set-Pill $n["Spd$i"] $n["Spd${i}T"] ($i -eq [int]$sel.Speed) '#FFB98BFF'
        }
        # ---- colour row: ALWAYS visible ----
        # 以前按模式隐藏（关闭/循环 时不显示）。用户把灯设成「关闭」以后再进这一页，
        # 颜色和色盘整块不见了 —— 读起来就是"颜色选择没了"，而不是"这个模式不用颜色"。
        # 现在可见性和可用性分开：行一直在，只是当前模式用不到时变暗 + 说明原因，
        # 点色块/色盘仍然会记住选择（切到 静态/波/呼吸 立刻生效），但不会白发一次写入。
        # ModeIdx = -1 表示"EC 里是一个本面板不提供的模式"，此时按第一个模式（关闭）的
        # 属性来呈现，和上面 pill 全不亮是同一个道理。
        $mi = [int]$sel.ModeIdx
        $mp = $(if ($mi -ge 0 -and $mi -lt $script:LedModePills.Count) { $script:LedModePills[$mi] } else { $script:LedModePills[0] })
        $nColors = [int]$mp.Colors
        $colourUsable = ($nColors -ge 1)
        $n.LedColorRow.Visibility = 'Visible'
        $dim = $(if ($colourUsable) { 1.0 } else { 0.45 })
        $n.LedColorRow.Opacity = $dim
        $n.ColorWheelBox.Opacity = $dim
        # swatch rings: 彩虹 is a choice of its own, so it lights up instead of a colour
        $rainbowIdx = -1
        for ($i = 0; $i -lt $script:RgbPills.Count; $i++) {
            if ($script:RgbPills[$i].ContainsKey('Rainbow')) { $rainbowIdx = $i; continue }
            $sel1 = (-not $sel.Rainbow) -and ($i -eq [int]$sel.Color)
            $n["Rgb$i"].BorderThickness = $(if ($sel1) { 2 } else { 0 })
            $n["Rgb$i"].BorderBrush = Get-Brush '#FFEDF0F5'
        }
        if ($rainbowIdx -ge 0) {
            $n["Rgb$rainbowIdx"].BorderThickness = $(if ($sel.Rainbow) { 2 } else { 0 })
            $n["Rgb$rainbowIdx"].BorderBrush = Get-Brush '#FFEDF0F5'
            # 彩虹 is meaningless where the firmware has no multi-colour variant
            $n["Rgb$rainbowIdx"].Opacity = $(if ($mp.Rainbow) { 1.0 } else { 0.25 })
        }
        $c = $script:RgbPills[[int]$sel.Color]
        $n.LedColorHint.Text = $(if (-not $colourUsable) { '「{0}」不用颜色；选了会记住，切到 静态/波/呼吸 生效' -f $mp.Label }
            elseif ($sel.Rainbow -and $sel.Mode -eq 'static') { '彩虹：整键盘重绘（约 0.3 秒）' }
            elseif ($sel.Rainbow) { '彩虹：交给固件自己配色' }
            elseif ($sel.UseCustom) { '色盘自定义颜色' }
            elseif ($sel.Mode -eq 'static') { '整键盘重绘（约 0.3 秒）' }
            else { '当前 {0}' -f $c.Label })

        # ---- 方向行：只有「波」用得到（帧里 d0 = 0xA1/0x71 + 方向）----
        $dirMode = ($sel.Mode -eq 'wave')
        $n.LedDirRow.Visibility = $(if ($dirMode) { 'Visible' } else { 'Collapsed' })
        if ($dirMode) {
            for ($i = 0; $i -lt $script:LedDirPills.Count; $i++) {
                Set-Pill $n["Dir$i"] $n["Dir${i}T"] ([int]$script:LedDirPills[$i].Idx -eq [int]$sel.Dir) '#FFB98BFF'
            }
        }

        # ---- 色盘：和颜色行一样始终显示（不可用时只是变暗，见上）----
        $n.ColorWheelBox.Visibility = 'Visible'
        if ($true) {
            # marker position comes from the stored hue/sat, so it does not drift on repaint
            if ($sel.UseCustom -and $null -ne $script:WheelHue) {
                $rad = [double]$script:WheelHue * [Math]::PI / 180.0
                $r0 = $script:WheelSize / 2.0
                $sat = [double]$script:WheelSat / 100.0
                $mx = $r0 + [Math]::Cos($rad) * $sat * $r0
                $my = $r0 + [Math]::Sin($rad) * $sat * $r0
                [System.Windows.Controls.Canvas]::SetLeft($n.WheelMark, $mx - 7)
                [System.Windows.Controls.Canvas]::SetTop($n.WheelMark, $my - 7)
                $n.WheelMark.Visibility = 'Visible'
            }
            else { $n.WheelMark.Visibility = 'Collapsed' }
            if ($sel.UseCustom) { $cr = [int]$sel.Custom.R; $cg = [int]$sel.Custom.G; $cb = [int]$sel.Custom.B }
            else { $cr = [int]$c.R; $cg = [int]$c.G; $cb = [int]$c.B }
            $n.WheelPick.Background = Get-Brush ('#FF{0:X2}{1:X2}{2:X2}' -f $cr, $cg, $cb)
            $n.WheelText.Text = '#{0:X2}{1:X2}{2:X2}' -f $cr, $cg, $cb
            $n.WheelText2.Text = 'R{0,3} G{1,3} B{2,3}' -f $cr, $cg, $cb
            if ($sel.UseCustom -and $null -ne $script:WheelHue) {
                $n.WheelHint.Text = '色相 {0}° · 饱和 {1}%' -f [int]$script:WheelHue, [int]$script:WheelSat
            }
            else { $n.WheelHint.Text = '点/拖色盘取任意纯色，立即生效' }
        }
        $n.KbHint.Text = $(if (-not $kbOffered -and $kbActive) {
                'EC 里当前是「{0}」，本面板不提供该模式；点上面任意模式即可覆盖。' -f $kbActive
            } else { '' }) + $script:KbHintBase
    }

    if ($tab -eq 'about') {
        # 信息行的值全部来自真实来源：EXE 的构建时间取自 EXE 自己的时间戳，路径取自本次运行
        # 的实际位置，DCHU 通道状态取自 dchu.ps1 真的选中的那个 DLL。没有"写死的简介"。
        $exePath = $(if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) { $script:HostExe }
                     else { Join-Path $PSScriptRoot 'ClevoHelper.ps1' })
        $built = '--'
        try { $built = (Get-Item -LiteralPath $exePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } catch { }
        $portable = [bool]($script:HostExe -and (Test-Path -LiteralPath $script:HostExe))
        # 长路径只显示尾部几段（用户反馈"看起来较宽"），完整值在 tooltip 里 —— 显示的是真的，
        # 只是不把一整行都塞满
        $short = {
            param([string]$v, [int]$max = 44)
            if ($v.Length -le $max) { return $v }
            $parts = $v -split '\\'
            $out = $parts[-1]
            for ($i = $parts.Count - 2; $i -ge 0; $i--) {
                $try = $parts[$i] + '\' + $out
                if ($try.Length + 2 -gt $max) { break }
                $out = $try
            }
            return '…\' + $out
        }
        $vals = [ordered]@{
            Version   = 'v' + $script:AppVersion
            Built     = $built
            Mode      = $(if ($portable) { '单文件 EXE（自包含）' } else { '脚本运行（开发模式）' })
            ExePath   = (& $short $exePath)
            DataDir   = (& $short (Split-Path $script:LogPath -Parent))
            Serial    = [string]$script:SysInfo.Serial
            Bios      = [string]$script:SysInfo.Bios
            Windows   = [string]$script:SysInfo.Windows
        }
        # tooltip 永远是完整值
        $full = [ordered]@{
            ExePath = $exePath
            DataDir = (Split-Path $script:LogPath -Parent)
        }
        if ($n.AboutChannelWarn) { $n.AboutChannelWarn.Visibility = $(if ($s.Err) { 'Visible' } else { 'Collapsed' }) }
        foreach ($k in $vals.Keys) {
            $tb = $n[('About_' + $k)]
            if ($tb) {
                $tb.Text = [string]$vals[$k]
                $tb.ToolTip = $(if ($full.Contains($k)) { [string]$full[$k] } else { [string]$vals[$k] })
            }
        }
    }

    if ($tab -eq 'misc') {
        # Every row here shows the state that was READ BACK, never the last click: the whole
        # point of this tab is that the hardware is the answer. $s.Misc is null until the
        # sampler's first misc read (about a second after the tab is opened).
        $mi = $s.Misc
        $sel = $script:MiscSel

        # ---- 电池状态（系统读数，让充电限制的效果就在旁边）----
        $bt = $(if ($null -ne $mi) { $mi.Battery } else { $null })
        if ($null -ne $bt -and $bt.Supported) {
            $n.BattBar.Width = [Math]::Round(160 * [int]$bt.Percent / 100)
            $bc = if ([int]$bt.Percent -ge 90) { '#FF6FE38A' } elseif ([int]$bt.Percent -ge 30) { '#FF57B0FF' } else { '#FFE38A6F' }
            $n.BattBar.Background = Get-Brush $bc
            $n.BattText.Text = '{0,3}%   {1}' -f [int]$bt.Percent, $(if ($bt.OnAc) { '已接电源' } else { '电池供电' })
        }
        else { $n.BattBar.Width = 0; $n.BattText.Text = '--' }

        # ---- 电池充电 ----
        # The EC's own three states map onto the three pills: 不限制 = 最大电量,
        # 70/80 = 推荐（原厂值）, anything else = 自定义.
        # 优先级：用户刚点开自定义（CustomOpen）> 有写入在飞 > EC 的当前状态。
        # 少了第一档就会出现"点自定义 → 这一行一闪就被收回去"（因为 EC 此刻还是 70/80 =
        # 推荐，下一次重画就按推荐把行收起来）。
        $chgSel = ''
        if ($null -ne $mi) {
            $sel.Start = [int]$mi.ChargerStart
            $sel.Stop = [int]$mi.ChargerStop
            if ($sel.CustomOpen) { $chgSel = 'custom' }
            elseif ($script:Sync.Pending -and $script:Sync.Pending.Kind -eq 'misc') { $chgSel = [string]$sel.Charger }
            elseif (-not $mi.ChargerEnabled) { $chgSel = 'max' }
            elseif ($mi.ChargerStart -eq $script:ChargerRecommended.Start -and $mi.ChargerStop -eq $script:ChargerRecommended.Stop) { $chgSel = 'rec' }
            else { $chgSel = 'custom' }
            $sel.Charger = $chgSel
        }
        for ($i = 0; $i -lt $script:ChargerPills.Count; $i++) {
            Set-Pill $n["Chg$i"] $n["Chg${i}T"] ($script:ChargerPills[$i].Key -eq $chgSel) '#FF57B0FF'
        }
        if ($null -ne $mi) {
            $n.ChargerHint.Text = $(if ($mi.ChargerEnabled) { 'EC：{0}% 起 / {1}% 停' -f $mi.ChargerStart, $mi.ChargerStop }
                else { 'EC：不限制（充满 100%）' })
            if ($chgSel -ne 'custom') { $n.ChargerHint.Text += '   ·   点「自定义」可改阈值' }
        }
        # 自定义阈值行：**常驻**，但只有自定义档可选中。不可选时整体变暗 + 不接受点击
        # （和风扇节点行同一套做法：非自定义模式下就是"看得见、点不动"）。
        $editable = ($chgSel -eq 'custom')
        $n.ChgStartLabel.Opacity = $(if ($editable) { 1.0 } else { 0.35 })
        $n.ChgStopLabel.Opacity = $(if ($editable) { 1.0 } else { 0.35 })
        for ($i = 0; $i -lt $script:ChargerStartPills.Count; $i++) {
            $v = [int]$script:ChargerStartPills[$i].Id
            # 可点 = 在自定义档 且 组合合法（起始 < 停止）
            $clickable = $editable -and (($null -eq $mi) -or ($v -lt [int]$sel.Stop))
            Set-Pill $n["ChgS$i"] $n["ChgS${i}T"] ($v -eq [int]$sel.Start) '#FF57B0FF'
            $n["ChgS$i"].Opacity = $(if ($clickable) { 1.0 } else { 0.3 })
            $n["ChgS$i"].IsHitTestVisible = $clickable
        }
        for ($i = 0; $i -lt $script:ChargerStopPills.Count; $i++) {
            $v = [int]$script:ChargerStopPills[$i].Id
            $clickable = $editable -and (($null -eq $mi) -or ($v -gt [int]$sel.Start))
            Set-Pill $n["ChgE$i"] $n["ChgE${i}T"] ($v -eq [int]$sel.Stop) '#FF57B0FF'
            $n["ChgE$i"].Opacity = $(if ($clickable) { 1.0 } else { 0.3 })
            $n["ChgE$i"].IsHitTestVisible = $clickable
        }

        # ---- 五个开关：显示的是读回值 ----
        $switchState = @{
            Tp = $(if ($null -ne $mi) { $mi.TouchPad } else { $null })
            Wk = $(if ($null -ne $mi) { $mi.WinKey } else { $null })
            Fl = $(if ($null -ne $mi) { $mi.FnLock } else { $null })
            Ws = $(if ($null -ne $mi) { $mi.WinFnSwap } else { $null })
            Nl = $(if ($null -ne $mi) { $mi.NumLock } else { $null })
        }
        $switchPills = @{ Tp = $script:OnOffPills; Wk = $script:EnablePills; Fl = $script:OnOffPills; Ws = $script:SwapPills; Nl = $script:OnOffPills }
        foreach ($pre in 'Tp', 'Wk', 'Fl', 'Ws', 'Nl') {
            $cur = $switchState[$pre]
            for ($i = 0; $i -lt $switchPills[$pre].Count; $i++) {
                $want = [bool]$switchPills[$pre][$i].On
                $on = ($null -ne $cur) -and ([bool]$cur -eq $want)
                Set-Pill $n["$pre$i"] $n["${pre}${i}T"] $on '#FF6FE38A'
                # unknown state (no read yet) must not look like "off"
                $n["$pre$i"].Opacity = $(if ($null -eq $cur) { 0.4 } else { 1.0 })
            }
        }
        # 启动收进托盘：读的是设置文件（不是 EC，所以没有"未知"状态）
        for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) {
            Set-Pill $n["Tray$i"] $n["Tray${i}T"] ([bool]$script:OnOffPills[$i].On -eq [bool]$script:Settings.StartToTray) '#FF6FE38A'
        }
    }

    # ---- 屏幕亮度（滑杆在状态页）----
    # 这一块必须**在 misc 那个 if 之外**：它服务的是状态页。第一版手滑放进了 misc 块里面，
    # 结果状态页的滑杆永远拿不到值（只有切到杂项页才会被赋值）—— 是日志里
    # "没有 bright paint 这一行"暴露出来的。
    # 拖动中、或有亮度写入在飞时**不碰滑块**：读回值天生比手慢半拍，用它去纠正滑块会把
    # 滑块拽回去，看起来就是"一卡一卡"。松手并写入完成后，这里再按读回值对齐。
    if ($tab -eq 'state') {
        $pendingBright = ($null -ne $script:Sync.Pending -and $script:Sync.Pending.Kind -eq 'misc' -and $script:Sync.Pending.Sub -eq 'bright')
        $brightNow = $(if ($s.Misc) { $s.Misc.Bright } else { $null })
        if ($null -ne $brightNow) {
            if (-not $script:BrightDragging -and -not $pendingBright) {
                # 差 1 以内不纠正：驱动自己会取整，反复纠正就是白白多写几次。
                # 赋值期间用 BrightSyncing 压住 ValueChanged，否则"同步读回值"这件事本身
                # 会触发一次写入（每次切到状态页都白发一次）。
                if ([Math]::Abs([int][Math]::Round($n.BrightSlider.Value) - [int]$brightNow) -gt 1) {
                    $script:BrightSyncing = $true
                    try { $n.BrightSlider.Value = [int]$brightNow }
                    finally { $script:BrightSyncing = $false }
                }
                $n.BrightVal.Text = '{0}%' -f $brightNow
            }
        }
        elseif (-not $script:BrightDragging) { $n.BrightVal.Text = '--%' }
    }

    $n.ModeText.Text = '风扇偏移 {0,-2}  ·  实际采样 {1} Hz  ·  写入串行化' -f $s.FanOffset, $(if ($script:Sync.RateHz) { $script:Sync.RateHz } else { '--' })
    if ($s.CurveHealth -eq 'ok') {
        # a positive offset is normal (the EC controls on a higher internal temperature than
        # the one this panel reads), so it is reported as "生效中", not as an error
        if ($s.CurveErr -gt 12) {
            $n.CurveHealth.Text = '曲线生效中（实测比表高 {0:N0}%）' -f $s.CurveErr
        }
        else {
            $n.CurveHealth.Text = '曲线正常（偏差 {0:N1}%）' -f $s.CurveErr
        }
        $n.CurveHealth.Foreground = Get-Brush '#FF6FE38A'
    }
    elseif ($s.CurveHealth -eq 'bad') {
        $n.CurveHealth.Text = '⚠ 实测比表低 {0:N0}%，可能欠冷，建议先重启' -f [Math]::Abs($s.CurveErr)
        $n.CurveHealth.Foreground = Get-Brush '#FFE38A6F'
    }
    elseif ($s.CurveHealth -eq 'measuring') {
        $n.CurveHealth.Text = '健康检查采样中…'
        $n.CurveHealth.Foreground = Get-Brush '#FF6B7385'
    }
    else {
        $n.CurveHealth.Text = '自动/最大 模式不校验曲线'
        $n.CurveHealth.Foreground = Get-Brush '#FF6B7385'
    }
    # The block below shows the table the EC is executing RIGHT NOW (block 13). This is the
    # only honest answer to "did the curve write actually take effect?" - it replaced a line
    # that showed the persisted factory table, i.e. something that is not what the fans do.
    # Four rows instead of one long line: the data was always four nodes, and in the portrait
    # window the one-line form ran off the edge while leaving the page half empty.
    if ($s.RuntimeT -and @($s.RuntimeRaw).Count -ge 3) {
        # does the running table equal the current 自定义 values?
        $matchCustom = ($s.RuntimeRaw[1] -eq (Convert-DutyPctToRaw $script:FanCustom.D2) -and
                        $s.RuntimeRaw[2] -eq (Convert-DutyPctToRaw $script:FanCustom.D3) -and
                        [int]$s.RuntimeT[1] -eq [int]$script:FanCustom.T2 -and
                        [int]$s.RuntimeT[2] -eq [int]$script:FanCustom.T3)
        $srcs = @('EC 固定', $(if ($matchCustom -or $s.FanMode -eq 6) { '本面板曲线' } else { 'EC/其它' }),
                       $(if ($matchCustom -or $s.FanMode -eq 6) { '本面板曲线' } else { 'EC/其它' }), 'EC 固定')
        $lines = @('EC 正在执行的 4 节点表')
        for ($i = 0; $i -lt 4; $i++) {
            $lines += ('节点{0}  {1,3}°C  {2,3}%   {3}' -f ($i + 1), $s.RuntimeT[$i], $s.RuntimeD[$i], $srcs[$i])
        }
        $lines += $(if ($s.FanMode -ne 6) { '（当前是自动/最大，EC 用自己的表）' }
                    elseif ($matchCustom) { '（与上面两个自定义节点一致）' }
                    else { '（与当前自定义值不一致：是别处写的表）' })
        $n.CurveText.Text = ($lines -join "`n")
    }

    $lw = $script:Sync.LastWrite
    if ($lw) {
        $n.StatusText.Text = $lw.Msg
        if ($lw.Ok) { $n.StatusText.Foreground = Get-Brush '#FF6FE38A' } else { $n.StatusText.Foreground = Get-Brush '#FFE38A6F' }
    }
    elseif ($s.Err) { $n.StatusText.Text = $s.Err; $n.StatusText.Foreground = Get-Brush '#FFE38A6F' }
    else {
        $n.StatusText.Text = 'InsydeDCHU → AcpiBridge (ACPI\CLV0001)   ·   每次写入均读回校验'
        $n.StatusText.Foreground = Get-Brush '#FF6B7385'
    }
  }
  catch { Write-Dbg ('PAINT-ERR ' + $_.Exception.ToString()) }
}

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
function Get-IconBitmapSource([string]$path, [int]$size) {
    $ico = New-Object System.Drawing.Icon($path, $size, $size)
    try {
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        return $src
    }
    finally { $ico.Dispose() }
}
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
function Hide-ToTray {
    try {
        # 从"最小化"状态收进托盘时先把状态还原：否则下次 Show 出来的还是最小化的窗口
        if ($script:Win.WindowState -eq 'Minimized') { $script:Win.WindowState = 'Normal' }
        $script:Win.Hide()
    }
    catch { Write-Dbg ('Hide-ToTray failed: ' + $_.Exception.Message) }
    # 不给状态栏写"已收进托盘"那句话：窗口马上就隐藏了，而重画每 400ms 就会按 LastWrite
    # 把那行覆盖掉 —— 写了也是一句永远看不到的话（假装通知了，其实没有）。气泡才是看得见的反馈。
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        try {
            if ($script:Tray) {
                $script:Tray.ShowBalloonTip(3000, 'ClevoHelper 仍在运行',
                    '已收进托盘。要退出请用托盘右键菜单的「退出」（或按 Alt+F4）。', 'Info')
            }
        }
        catch { Write-Dbg ('balloon failed: ' + $_.Exception.Message) }
    }
    Write-Dbg 'window hidden to tray'
}
# 系统层面的最小化（Win+↓、任务栏右键菜单）也收进托盘，而不是留一个小标题条
$script:Win.Add_StateChanged({
    if ($script:Win.WindowState -eq 'Minimized') { Hide-ToTray }
})

$n.MinBtn.Add_MouseLeftButtonDown({ Hide-ToTray })
$n.MinBtn.Add_MouseEnter({ $n.MinBtn.Foreground = Get-Brush '#FFEDF0F5' })
$n.MinBtn.Add_MouseLeave({ $n.MinBtn.Foreground = Get-Brush '#FF7C8598' })

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

function Get-WiredEventNames($el) {
    $out = @()
    if (-not $el -or -not $script:WireStoreProp) { return $out }
    try { $store = $script:WireStoreProp.GetValue($el) } catch { return $out }
    if (-not $store) { return $out }
    foreach ($k in $script:WireEventMap.Keys) {
        try { if ($store.Contains($script:WireEventMap[$k])) { $out += $k } } catch { }
    }
    return $out
}

# 「应该接了什么」这份清单是手写的，遗漏风险由两点兜住：一是每条都对着上面的绑定代码抄，
# 二是自检里还有几个**真点**（Invoke-Click）会走完整链路。
function Get-ExpectedWiring {
    $w = New-Object System.Collections.ArrayList
    $one = { param([string]$nm, [string]$ev) [void]$w.Add([pscustomobject]@{ Name = $nm; Ev = $ev }) }
    $many = { param([string]$pre, [int]$cnt, [string]$ev)
        for ($i = 0; $i -lt $cnt; $i++) { [void]$w.Add([pscustomobject]@{ Name = "$pre$i"; Ev = $ev }) } }
    & $many 'Pwr' $script:PowerPills.Count 'Up'
    & $one 'RevertBtn' 'Up'
    & $many 'Gpu' $script:GpuPills.Count 'Up'
    & $one 'GpuOk' 'Up'
    & $one 'GpuCancel' 'Up'
    & $one 'GpuRebootBtn' 'Up'
    & $many 'Chg' $script:ChargerPills.Count 'Up'
    & $many 'ChgS' $script:ChargerStartPills.Count 'Up'
    & $many 'ChgE' $script:ChargerStopPills.Count 'Up'
    & $one 'BrightSlider' 'Value'
    foreach ($pre in 'Tp', 'Wk', 'Fl', 'Ws', 'Nl') { & $many $pre 2 'Up' }
    & $many 'Led' $script:LedModePills.Count 'Up'
    & $many 'Dir' $script:LedDirPills.Count 'Up'
    & $many 'Rgb' $script:RgbPills.Count 'Up'
    & $many 'RgbB' $script:RgbBrightness.Count 'Up'
    & $many 'Spd' $script:LedSpeedPills.Count 'Up'
    & $one 'ColorWheel' 'Up'
    & $many 'Auto' $script:AutostartPills.Count 'Up'
    & $many 'Tray' 2 'Up'
    foreach ($t in 'State', 'Perf', 'Kb', 'Misc', 'About') { & $one "TabBtn$t" 'Up' }
    & $many 'Fan' $script:FanPills.Count 'Up'
    foreach ($f in 'Ct2T', 'Ct2D', 'Ct3T', 'Ct3D') { & $one "${f}Minus" 'Up'; & $one "${f}Plus" 'Up' }
    & $one 'MinBtn' 'Down'
    & $one 'TitleBar' 'Down'
    & $one 'CloseBtn' 'Down'
    return $w
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

function Get-TrayMenuLeaves {
    # 叶子和"点一下就有反应的项"才算要接线；分隔线、纯下拉父项、禁用项不算
    $out = New-Object System.Collections.ArrayList
    if (-not $script:Tray -or -not $script:Tray.ContextMenuStrip) { return $out }
    $walk = {
        param($items)
        foreach ($it in $items) {
            if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
            if ($it.DropDownItems.Count -gt 0) { & $walk $it.DropDownItems; continue }
            if (-not $it.Enabled) { continue }
            [void]$out.Add($it)
        }
    }
    & $walk $script:Tray.ContextMenuStrip.Items
    return $out
}

function Get-WinFormsClickWired($item) {
    if (-not $script:TrayClickKey) { return $null }        # null = 查不了
    try {
        $f = [System.ComponentModel.Component].GetField('events',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        $list = $f.GetValue($item)
        if (-not $list) { return $false }
        return ($null -ne $list[$script:TrayClickKey])
    }
    catch { return $null }
}

function Test-PanelWiring {
    $missing = New-Object System.Collections.ArrayList
    $total = 0

    # 先验"探测器"本身：造两个不在可视树里的临时 Border，一个接事件、一个不接，看能不能分辨。
    # 不验的话，"应接 94 缺 0"也可能只是因为这个探测器永远返回"接了"——那就成了绿色的摆设。
    $detector = $false
    $detectorNote = ''
    try {
        $pb = New-Object System.Windows.Controls.Border
        $before = @(Get-WiredEventNames $pb)
        $pb.Add_MouseLeftButtonUp({ })
        $after = @(Get-WiredEventNames $pb)
        $detector = ($before.Count -eq 0) -and ($after -contains 'Up')
        $detectorNote = ('空控件=[{0}] 接过后=[{1}]' -f ($before -join '+'), ($after -join '+'))
    }
    catch { $detectorNote = '探测器抛异常: ' + $_.Exception.Message }
    if (-not $detector) { [void]$missing.Add('接线探测器失效（' + $detectorNote + '）——「缺 0 个」这个结论不可信') }

    foreach ($e in (Get-ExpectedWiring)) {
        $total++
        $el = $n[$e.Name]
        if (-not $el) { $el = $script:Win.FindName($e.Name) }
        if (-not $el) { [void]$missing.Add("$($e.Name)（控件不存在）"); continue }
        $has = @(Get-WiredEventNames $el)
        if ($has -notcontains $e.Ev) {
            [void]$missing.Add(('{0}（要 {1}；实际 {2}）' -f $e.Name, $e.Ev, $(if ($has.Count) { $has -join '+' } else { '一个事件都没接' })))
        }
    }
    $leaves = @(Get-TrayMenuLeaves)
    $trayChecked = 0
    foreach ($it in $leaves) {
        $total++
        $wired = Get-WinFormsClickWired $it
        if ($null -eq $wired) { [void]$missing.Add("托盘「$($it.Text)」（查不了：WinForms 反射不可用）"); continue }
        $trayChecked++
        if (-not $wired) { [void]$missing.Add("托盘「$($it.Text)」（没有 Click 处理器）") }
    }
    return [pscustomobject]@{
        Total = $total; Missing = $missing; TrayLeaves = $leaves.Count
        TrayChecked = $trayChecked; TrayReflect = $script:TrayClickKeyField
        Detector = $detector; DetectorNote = $detectorNote
    }
}

# 真·点一下：造一对鼠标消息打到控件上。**必须控件已经进了可视树**（窗口显示过）才有用——
# 没显示时 RaiseEvent 打了也不触发处理器（这条也是实测的，见 src\diag-wire6.ps1）。
# 打 MouseUp 而不是 MouseLeftButtonUp 的原因：WPF 在 MouseUp 上会把左键那一路提升出来，
# 一次消息就能同时喂到 Up 处理器，和真人按一下的行为一致；每次 Raised 只会触发一次。
function Invoke-Click([string]$name) {
    $el = $(if ($n[$name]) { $n[$name] } else { $script:Win.FindName($name) })
    if (-not $el) { return $false }
    try {
        $d = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $d.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
        $el.RaiseEvent($d)
        $u = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $u.RoutedEvent = [System.Windows.UIElement]::MouseUpEvent
        $el.RaiseEvent($u)
        return $true
    }
    catch {
        Write-Dbg ('Invoke-Click ' + $name + ' FAILED: ' + $_.Exception.Message)
        return $false
    }
}

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

# ------------------------------------------------------- 作用域自检（静态）---
# 第二类"接上了也不干活"的坑，就是显卡模式那次：处理块用 GetNewClosure() 生成，块里给
# `$script:某标量 = ...` 赋值 —— 那个赋值落进闭包自己的模块作用域，外面的脚本作用域看不到，
# 于是另一个处理块（读同一个变量）永远读到 0，**一条命令都不发**。属性赋值不受影响
# （`$script:LedSel.X = ...` 改的是对象），所以键盘灯一直是好的、这个坑只坑到显卡模式。
# 这类错误在运行时看不出来（点击有反应、界面有变化），只能用静态检查挡住。
# 这里直接解析**自己的源文件**，把 GetNewClosure() 的块里所有 `$script:标量 =` 找出来。
# 找不到自己的文件就如实写"没检查"，不假装通过。
function Test-ClosureScopeTrap([string]$Path) {
    $res = [pscustomobject]@{ Checked = $false; Blocks = 0; Hits = @(); Note = ''; DetectorOk = $false }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $res.Note = '拿不到自己的源文件路径，没检查'; return $res }
    try {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    }
    catch { $res.Note = '解析自己的源文件失败: ' + $_.Exception.Message; return $res }
    $hits = New-Object System.Collections.ArrayList
    $closures = $ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $a.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $a.Member.Value -eq 'GetNewClosure'
        }, $true)
    foreach ($c in $closures) {
        # `{ ... }.GetNewClosure()` 里那个脚本块是**被调用者**（Expression），不是参数 ——
        # 第一版按 Arguments 找，结果"闭包块数 = 0"，白扫一遍（18 个调用点一个都没看到）。
        $cands = @($c.Expression) + @($c.Arguments)
        foreach ($arg in $cands) {
            if ($arg -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $res.Blocks++
            $bad = $arg.ScriptBlock.FindAll({
                    param($a)
                    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.IsScript
                }, $true)
            foreach ($b in $bad) {
                [void]$hits.Add(('第 {0} 行：GetNewClosure 块里给 {1} 赋值（赋值会留在闭包自己的作用域，别处读不到）' -f `
                            $b.Extent.StartLineNumber, $b.Left.VariablePath.UserPath))
            }
        }
    }
    $res.Checked = $true
    $res.Hits = $hits
    # 探测器自检：拿一段**已知有坑**的代码扫一遍，扫不出来就说明这个检查是摆设
    # （第一版就因为找错了 AST 属性而"闭包块 = 0"，扫了个寂寞还照样报"没有坑"）。
    $res.DetectorOk = $false
    try {
        $te = $null
        $tast = [System.Management.Automation.Language.Parser]::ParseInput(
            '$probe = { $script:ProbeTrap = 1 }.GetNewClosure()', [ref]$null, [ref]$te)
        $tc = $tast.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $a.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $a.Member.Value -eq 'GetNewClosure'
            }, $true)
        foreach ($c in $tc) {
            foreach ($arg in (@($c.Expression) + @($c.Arguments))) {
                if ($arg -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
                $t = $arg.ScriptBlock.FindAll({
                        param($a)
                        $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $a.Left.VariablePath.IsScript
                    }, $true)
                if (@($t).Count -gt 0) { $res.DetectorOk = $true }
            }
        }
    }
    catch { $res.DetectorOk = $false }
    return $res
}
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
        foreach ($nm in 'StatePanel', 'ControlPanel', 'TabState', 'TabPerf', 'TabKb', 'TabMisc', 'TabAbout',
            'Vol0Row', 'Vol1Row', 'MemRow', 'BrightSlider', 'StatusText', 'VitalsSensors', 'UpdatedText') {
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
            8 {
                $lw = $script:Sync.LastWrite
                Write-Dbg ('SELFTEST power result: ok={0} msg={1}' -f $lw.Ok, $lw.Msg)
            }
            10 { Write-Dbg 'SELFTEST: simulating click on [恢复初始]'; Request-Write -Mode 0 -Kind 'restore' }
            15 {
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
                Request-Led
                Write-Dbg 'SELFTEST: restored the pre-test colour + mode selection'
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
            109 { Write-Dbg 'SELFTEST: done, closing'; $script:Win.Close() }
        }
    })
    $st.Start()
}

# ---------------------------------------------------------------- 重启申请 ---
# 显卡模式是开机前（pre-boot）值：**暂存完必须重启一次才生效**。原厂控制中心的做法是
# `shutdown -f -r -t 0` —— 直接替你重启；我们不做这种事，但也不能只把话写在状态栏里让用户
# 自己想起来。所以暂存成功后弹一张"重启申请"：
#   「立即重启」→ 安排 20 秒后重启（同一个窗口变成倒计时，期间可以「取消重启」，走 shutdown /a）
#   「稍后我自己重启」→ 关掉，什么都不做
#
# 两个实现上的注意：
#   1. **非模态**（Show 而不是 ShowDialog）：面板的采样/重画走的是 DispatcherTimer，弹模态
#      对话框会套一层嵌套消息循环，多一层就多一处出问题的机会；而且这张申请不该卡住面板。
#   2. 对话框里的状态一律放在一个**hashtable**里（$st）传给命名函数用。原因见显卡模式那个
#      作用域陷阱（README 3.40）：给对象赋属性跨作用域没问题，给 `$script:标量` 赋值才会丢。
#      这里所有处理块都只是 `函数 $st`，没有任何脚本作用域赋值 —— 面板启动时的静态扫描会盯着。
function New-RebootButton([string]$Text, [string]$Bg, [string]$Fg, [switch]$Accent) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $Bg
    $b.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 13
    $b.MinWidth = 104
    $b.Padding = New-Object System.Windows.Thickness -ArgumentList 0, 7, 0, 7
    $b.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 8, 0
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = Get-Brush $Fg
    $t.FontSize = 12
    $t.TextAlignment = 'Center'
    if ($Accent) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $b.Child = $t
    return $b
}

function Confirm-RebootNow($st) {
    # 只做"安排"：真正的重启由 Windows 在倒计时结束后执行，期间用户可以取消
    if ($st.Dry) {
        Write-Dbg 'REBOOT-PROMPT(dry): 点到「立即重启」——测试模式，不真的重启'
    }
    else {
        try {
            Start-Process -FilePath 'shutdown.exe' -WindowStyle Hidden -ArgumentList @(
                '/r', '/t', '20', '/c', 'ClevoHelper：重启以应用显卡模式')
            $st.Scheduled = $true
        }
        catch { $st.Note.Text = '安排重启失败：' + $_.Exception.Message }
    }
    $st.Ask.Visibility = 'Collapsed'
    $st.Count.Visibility = 'Visible'
    # dry（自检用）只走 5 秒，免得测试拖时间；真跑是 20 秒
    $st.Sec = $(if ($st.Dry) { 5 } else { 20 })
    $st.Note.Text = ('{0} 秒后重启…（点「取消重启」可以中止）' -f $st.Sec)
    if (-not $st.Timer) {
        $st.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $st.Timer.Interval = [TimeSpan]::FromSeconds(1)
        $st.Timer.Add_Tick({ Step-RebootCountdown $st }.GetNewClosure())
        $st.Timer.Start()
    }
}
function Step-RebootCountdown($st) {
    $st.Sec = [int]$st.Sec - 1
    if ($st.Sec -le 0) {
        try { $st.Timer.Stop() } catch { }
        try { $st.Win.Close() } catch { }
        return
    }
    $st.Note.Text = ('{0} 秒后重启…（点「取消重启」可以中止）' -f $st.Sec)
}
function Cancel-RebootNow($st) {
    if ($st.Dry) { Write-Dbg 'REBOOT-PROMPT(dry): 点到「取消重启」' }
    if ($st.Scheduled -and -not $st.Dry) {
        try {
            Start-Process -FilePath 'shutdown.exe' -WindowStyle Hidden -ArgumentList @('/a')
            $st.Note.Text = '已取消重启。想生效时自己重启一次即可。'
        }
        catch { $st.Note.Text = '取消失败：' + $_.Exception.Message }
    }
    else { $st.Note.Text = '已取消。想生效时自己重启一次即可。' }   # dry 也走这条，让自检能看到文案
    if ($st.Timer) { try { $st.Timer.Stop() } catch { } }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(1800)
    $t.Add_Tick({ $t.Stop(); $st.Win.Close() }.GetNewClosure())
    $t.Start()
}

function Show-RebootPrompt([int]$Mode, [switch]$DryRun) {
    $name = $(if ($script:GpuModeName.ContainsKey($Mode)) { $script:GpuModeName[$Mode] } else { "模式 $Mode" })
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.SizeToContent = 'WidthAndHeight'
    $w.Width = 380
    $w.ShowInTaskbar = $false
    $w.Topmost = $true
    $w.WindowStartupLocation = $(if ($script:Win.IsVisible) { 'CenterOwner' } else { 'CenterScreen' })
    if ($script:Win.IsVisible) { $w.Owner = $script:Win }

    $root = New-Object System.Windows.Controls.Border
    $root.Background = Get-Brush '#FF141619'
    $root.BorderBrush = Get-Brush '#FF2B303B'
    $root.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 1
    $root.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 14
    $root.Padding = New-Object System.Windows.Thickness -ArgumentList 20, 16, 20, 16
    $stack = New-Object System.Windows.Controls.StackPanel

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = '需要重启才能生效'
    $h.Foreground = Get-Brush '#FFEDF0F5'
    $h.FontSize = 15
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$stack.Children.Add($h)

    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = ('显卡模式已暂存为「{0}」。这是开机前的设置，重启后才会真正切换。' -f $name)
    $b.Foreground = Get-Brush '#FFD7DCE6'
    $b.FontSize = 12
    $b.TextWrapping = 'Wrap'
    $b.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 9, 0, 0
    [void]$stack.Children.Add($b)

    $ask = New-Object System.Windows.Controls.StackPanel
    $q = New-Object System.Windows.Controls.TextBlock
    $q.Text = '现在重启，还是你自己找时间重启？'
    $q.Foreground = Get-Brush '#FF8A93A6'
    $q.FontSize = 11
    $q.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 6, 0, 0
    [void]$ask.Children.Add($q)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 14, 0, 0
    $btnNow = New-RebootButton '立即重启' '#FF57B0FF' '#FF11141A' -Accent
    $btnLater = New-RebootButton '稍后我自己重启' '#FF262A33' '#FFD7DCE6'
    $btnLater.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 0
    [void]$row.Children.Add($btnNow)
    [void]$row.Children.Add($btnLater)
    [void]$ask.Children.Add($row)
    [void]$stack.Children.Add($ask)

    $cnt = New-Object System.Windows.Controls.StackPanel
    $cnt.Visibility = 'Collapsed'
    $note = New-Object System.Windows.Controls.TextBlock
    $note.Foreground = Get-Brush '#FFE3C86F'
    $note.FontSize = 12
    $note.TextWrapping = 'Wrap'
    $note.Text = ''
    [void]$cnt.Children.Add($note)
    $row2 = New-Object System.Windows.Controls.StackPanel
    $row2.Orientation = 'Horizontal'
    $row2.HorizontalAlignment = 'Right'
    $row2.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 14, 0, 0
    $btnCancel = New-RebootButton '取消重启' '#FF262A33' '#FFD7DCE6'
    $btnCancel.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 0
    [void]$row2.Children.Add($btnCancel)
    [void]$cnt.Children.Add($row2)
    [void]$stack.Children.Add($cnt)

    $root.Child = $stack
    $w.Content = $root

    $st = [hashtable]::Synchronized(@{
            Win = $w; Ask = $ask; Count = $cnt; Note = $note; Sec = 20
            Timer = $null; Scheduled = $false; Dry = [bool]$DryRun
        })
    # 处理块只调用命名函数，并把状态作为参数传进去 —— 不写任何脚本作用域变量（作用域自检会查）
    $btnNow.Add_MouseLeftButtonUp({ Confirm-RebootNow $st }.GetNewClosure())
    $btnLater.Add_MouseLeftButtonUp({ $st.Win.Close() }.GetNewClosure())
    $btnCancel.Add_MouseLeftButtonUp({ Cancel-RebootNow $st }.GetNewClosure())
    $w.Add_KeyDown({ if ($_.Key -eq 'Escape') { $st.Win.Close() } }.GetNewClosure())
    $w.Add_MouseLeftButtonDown({ $st.Win.DragMove() }.GetNewClosure())

    $w.Show()
    $w.Activate()
    $script:RebootDlg = $st
    Write-Dbg ('REBOOT-PROMPT: 已弹出（模式={0}「{1}」dry={2}；面板可见={3}）' -f $Mode, $name, [bool]$DryRun, $script:Win.IsVisible)
}

# 每次暂存都问一次：暂存是用户点「药丸 + 确认」两步做出来的，本来就是"我现在想切"的意思，
# 所以不存在"问过了就不再问"的道理（换回原来的模式也一样要重启才生效）。真正需要防的是
# 同一次暂存被问两遍 —— 那个由"读到就清空 RebootAsk"保证。
function Test-RebootAsk {
    $ra = $script:Sync.RebootAsk
    if (-not $ra) { return }
    $script:Sync.RebootAsk = $null
    if ($SelfTest -or $SizeProbe) {
        Write-Dbg ('REBOOT-ASK: 模式 {0} 已暂存（诊断模式下不弹窗）' -f $ra.Mode)
        return
    }
    try { Show-RebootPrompt -Mode ([int]$ra.Mode) }
    catch { Write-Dbg ('REBOOT-PROMPT FAILED: ' + $_.Exception.Message) }
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:Timer.Add_Tick({ $null = Test-Sampler; Update-Panel; Test-ShowRequest; Test-RebootAsk })
$script:Timer.Start()

# 第二次双击 EXE 时，启动器会写一个 show.request 文件（见 build-exe.ps1 的 ActivateExisting）。
# 面板在这里消费它：Show + Activate —— 这条对"最小化到托盘"（窗口真的被 Hide 了）也有效，
# 而从外面调 SetForegroundWindow 是叫不醒一个隐藏窗口的。
# 以前启动器遇到"已经在运行"就直接 return，用户双击桌面上的 EXE 时什么都不会发生，
# 看起来就是"这个 exe 用不了"。
$script:ShowFlag = Join-Path (Split-Path $PSScriptRoot -Parent) 'show.request'
function Test-ShowRequest {
    try {
        if (-not (Test-Path -LiteralPath $script:ShowFlag)) { return }
        Remove-Item -LiteralPath $script:ShowFlag -Force -ErrorAction SilentlyContinue
        $script:Win.Show()
        $script:Win.Activate()
        $n.StatusText.Text = '已有一个面板在运行，这是它（窗口已调到前面）'
        $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
        Write-Dbg 'show.request consumed -> window shown+activated'
    }
    catch { Write-Dbg ('show.request failed: ' + $_.Exception.Message) }
}

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






