# diag-aumid.ps1 - read the AppUserModelID the taskbar actually sees for the panel window.
#
# 为什么需要这个：任务栏不总是用窗口图标（WM_SETICON）。Windows 7+ 按进程的
# AppUserModelID 决定"这是哪个程序、用哪个图标、和谁分在一组"。面板跑在 powershell.exe 里，
# 默认 AUMID 是 Microsoft.Windows.PowerShell —— 于是任务栏显示 PowerShell 的图标并和其它
# PowerShell 窗口分在一组，跟我们给窗口设的图标无关。
# 面板启动时调用 SetCurrentProcessExplicitAppUserModelID('Yeguang.ClevoHelper') 覆盖它；
# 这个脚本把那个值**读回来**确认生效（而不是"应该生效"）。
#
# 读取整个在 C# 里完成：IPropertyStore 是 COM 接口，从 PowerShell 侧拿到的只会是
# __ComObject，方法名都看不到（第一版就栽在这儿）。
#
# Usage: powershell -STA -File diag-aumid.ps1
[CmdletBinding()]
param()

Add-Type -Namespace Aumid -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);

[System.Runtime.InteropServices.DllImport("shell32.dll")]
static extern int SHGetPropertyStoreForWindow(System.IntPtr hwnd, ref System.Guid iid, out IPropertyStore store);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
static extern int PSGetPropertyKeyFromName(string name, out PROPERTYKEY k);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
static extern int PropVariantToStringAlloc(ref PROPVARIANT v, out System.IntPtr s);
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

/// 返回窗口的 AppUserModelID；没有设置时返回空字符串，出错返回 "(err 0x…)"
public static string GetWindowAumid(System.IntPtr hwnd) {
    PROPERTYKEY key;
    if (PSGetPropertyKeyFromName("System.AppUserModel.ID", out key) != 0) return "(PKEY 取不到)";
    System.Guid iid = new System.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore store;
    int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
    if (hr != 0) return string.Format("(属性库 0x{0:X8})", hr);
    PROPVARIANT pv;
    hr = store.GetValue(ref key, out pv);
    if (hr != 0) return "";                       // 属性不存在 = 没设过
    try {
        System.IntPtr s;
        if (PropVariantToStringAlloc(ref pv, out s) == 0 && s != System.IntPtr.Zero)
            return System.Runtime.InteropServices.Marshal.PtrToStringUni(s);
        return string.Format("(vt={0})", pv.vt);
    } finally { PropVariantClear(ref pv); }
}
'@

$script:hits = @()
$cb = [Aumid.Api+EnumProc]{
    param($h, $p)
    $pid2 = 0
    [void][Aumid.Api]::GetWindowThreadProcessId($h, [ref]$pid2)
    $sb = New-Object Text.StringBuilder 200
    [void][Aumid.Api]::GetWindowTextW($h, $sb, 200)
    $t = $sb.ToString()
    if ($t -like 'ClevoHelper*') {
        $proc = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
        $script:hits += [pscustomobject]@{
            Pid   = $pid2
            Exe   = $(if ($proc) { $proc.ProcessName } else { '?' })
            Title = $t
            Aumid = [Aumid.Api]::GetWindowAumid($h)
        }
    }
    return $true
}
[void][Aumid.Api]::EnumWindows($cb, [IntPtr]::Zero)

if (-not $script:hits.Count) { '（没有找到 ClevoHelper 窗口 —— 面板可能在托盘里没显示）'; exit 0 }
'任务栏看到的身份（AppUserModelID）：'
$script:hits | Format-Table -AutoSize
''
foreach ($h in $script:hits) {
    # 注意：窗口属性 System.AppUserModel.ID **本来就是空的** —— 设的是**进程**身份，
    # 任务栏在没有窗口属性时用的就是进程 AUMID。所以这里空着不算错，别再报假阴性
    # （第一版就在这里说了"没有 AUMID"，而其实进程身份是设好的）。
    if ($h.Aumid -eq 'Yeguang.ClevoHelper') {
        "  [OK]   pid {0}: 窗口自己声明了 AUMID" -f $h.Pid
    }
    elseif (-not $h.Aumid) {
        "  [--]   pid {0}: 窗口属性为空（正常）—— 真正的身份是进程 AUMID，见下面日志行" -f $h.Pid
    }
    else { "  [?]    pid {0}: 窗口属性 = {1}" -f $h.Pid, $h.Aumid }
}

# 进程 AUMID 只能在进程内读，所以直接看面板自己写的那行日志（启动时一行）。
# 两个日志都要看：开发模式写在仓库的 artifacts 下，打包版写在 %LOCALAPPDATA% 下。
''
'面板自报的进程身份（来自它的日志）：'
$logs = @(
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\monitor-debug.log'),
    (Join-Path $env:LOCALAPPDATA 'ClevoHelper\artifacts\monitor-debug.log')
)
$found = $false
foreach ($log in $logs) {
    if (-not (Test-Path -LiteralPath $log)) { continue }
    $line = Get-Content -LiteralPath $log | Select-String -Pattern 'AUMID check' | Select-Object -Last 1
    if ($line) { '  ' + $line.Line.Trim(); '      ← ' + $log; $found = $true }
}
if (-not $found) { '  （两份日志里都没有 AUMID 那行 —— 面板可能是旧版本启动的）' }

''
'该 AUMID 的注册项（任务栏显示的**名字和图标**就是从这儿来的）：'
$key = 'HKCU:\SOFTWARE\Classes\AppUserModelId\Yeguang.ClevoHelper'
if (-not (Test-Path -LiteralPath $key)) {
    '  [BAD]  没有注册项 —— 任务栏会显示进程映像的名字（Windows PowerShell），不是 ClevoHelper'
}
else {
    $v = Get-ItemProperty -LiteralPath $key
    $okName = ($v.DisplayName -eq 'ClevoHelper')
    $okIcon = [bool]($v.IconUri -and (Test-Path -LiteralPath ([string]$v.IconUri)))
    "  DisplayName : {0}   {1}" -f $v.DisplayName, $(if ($okName) { '[OK]' } else { '[BAD]' })
    "  IconUri     : {0}   {1}" -f $v.IconUri, $(if ($okIcon) { '[OK]' } else { '[BAD] 路径不存在' })
    "  RelaunchCommand : {0}" -f $v.RelaunchCommand
    ''
    if ($okName -and $okIcon) { '  → 任务栏应显示 "ClevoHelper" + 自己的图标（若仍是旧名字，重启一次 explorer.exe 刷新缓存）' }
}
