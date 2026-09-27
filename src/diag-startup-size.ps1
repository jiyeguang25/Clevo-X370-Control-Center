# 量一下面板窗口在启动过程中到底变过几次尺寸 —— "UI 先从很长变成实际的"这种问题，
# 猜是没有用的：
#   一是从外面按 20ms 一次的频率读窗口矩形（GetWindowRect），窗口什么时候变、变成多少、当时可不可见，
#   全都记下来；这样看到的是用户看到的东西，不是我以为的东西。
#   二是两条路径都量：收进托盘后再叫出来（默认路径），以及启动就直接显示（临时 settings.json）。
#
# 用法：
#   diag-startup-size.ps1 -Mode tray   -ShowAt 4   # 先收托盘，4 秒时写 show.request 叫出来
#   diag-startup-size.ps1 -Mode cold               # 启动即显示（临时把 StartToTray 设成 false）
param(
    [ValidateSet('tray', 'cold')][string]$Mode = 'tray',
    [double]$ShowAt = 4,
    [double]$Seconds = 14
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'ClevoHelper.ps1'
$root = Split-Path $PSScriptRoot -Parent
$tmpSettings = Join-Path $root 'settings.json'
$showFlag = Join-Path $root 'show.request'
$madeSettings = $false

Add-Type -Namespace Sz -Name Api -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
'@

function Get-PanelWindow([int]$targetPid) {
    $found = [IntPtr]::Zero
    $cb = [Sz.Api+EnumProc]{
        param($h, $p)
        $winPid = 0
        [void][Sz.Api]::GetWindowThreadProcessId($h, [ref]$winPid)
        if ($winPid -eq $targetPid) {
            $r = New-Object Sz.Api+RECT
            if ([Sz.Api]::GetWindowRect($h, [ref]$r)) {
                if (($r.Right - $r.Left) -gt 200) { $script:foundHwnd = $h; return $false }
            }
        }
        return $true
    }
    $script:foundHwnd = [IntPtr]::Zero
    [void][Sz.Api]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:foundHwnd
}

# cold 模式：临时写一个 StartToTray=false 的 settings.json（跑完删掉，不动用户 AppData 里的那份）
if ($Mode -eq 'cold') {
    if (Test-Path -LiteralPath $tmpSettings) { throw "已经有 $tmpSettings，先处理它再跑 cold 模式" }
    '{ "StartToTray": false }' | Set-Content -LiteralPath $tmpSettings -Encoding UTF8
    $madeSettings = $true
}
Remove-Item -LiteralPath $showFlag -Force -ErrorAction SilentlyContinue

$args = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $src)
if ($Mode -eq 'tray') { $args += '-StartHidden' }
"启动面板（{0} 模式）…" -f $Mode
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
$t0 = Get-Date
$lastKey = ''
try {
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
        $el = ((Get-Date) - $t0).TotalSeconds
        if ($Mode -eq 'tray' -and -not (Test-Path -LiteralPath $showFlag) -and $el -ge $ShowAt) {
            Set-Content -LiteralPath $showFlag -Value (Get-Date).ToString('o') -Encoding ASCII
            "  {0,6:N2}s  << 写了 show.request（叫窗口出来）" -f $el
        }
        $h = Get-PanelWindow $proc.Id
        if ($h -ne [IntPtr]::Zero) {
            $r = New-Object Sz.Api+RECT
            if ([Sz.Api]::GetWindowRect($h, [ref]$r)) {
                $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
                $vis = [Sz.Api]::IsWindowVisible($h)
                $key = "$w x $hh vis=$vis"
                if ($key -ne $lastKey) {
                    "  {0,6:N2}s  窗口 {1}  left={2} top={3}" -f $el, $key, $r.Left, $r.Top
                    $lastKey = $key
                }
            }
        }
        Start-Sleep -Milliseconds 20
    }
}
finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process ClevoHelper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    # 面板是子进程起的 powershell，父进程退出不代表子进程退出，按命令行再杀一遍
    $kids = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -notmatch '-Command' -and $_.CommandLine -like "*$src*" })
    foreach ($k in $kids) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($madeSettings) { Remove-Item -LiteralPath $tmpSettings -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $showFlag -Force -ErrorAction SilentlyContinue
    "（已停掉面板{0}）" -f $(if ($madeSettings) { '，临时 settings.json 已删除' } else { '' })
}
