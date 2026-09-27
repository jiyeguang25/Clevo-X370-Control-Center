# 等"重启申请"弹出来，然后把那张窗口拍下来 —— 界面这种东西还是得看。
# 做法：盯日志里的 REBOOT-PROMPT 行，出现后在面板进程的可见窗口里挑**小的那个**（=弹窗；
# 面板本身是 468x662），按它的矩形截图放大 3 倍。
# 用法：diag-shot-prompt.ps1 [-WaitSeconds 150] [-Out path]
param([int]$WaitSeconds = 150, [string]$Out)
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace SP -Name Api -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][SP.Api]::SetProcessDPIAware()

$log = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\monitor-debug.log'
if (-not $Out) { $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\reboot-prompt.png' }

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    $hit = Select-String -Path $log -Pattern 'REBOOT-PROMPT: 已弹出' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($hit) { break }
    Start-Sleep -Milliseconds 400
}
if (-not $hit) { "等了 $WaitSeconds 秒也没等到重启申请弹出来"; return }
"日志里看到了：{0}" -f $hit.Line.Trim()
Start-Sleep -Milliseconds 800   # 让它画完

# 找面板进程 → 它名下可见窗口里最小的那个
$proc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -notmatch '-Command' -and $_.CommandLine -match 'ClevoHelper' })[0]
if (-not $proc) { '没有面板进程'; return }
$script:cands = New-Object System.Collections.ArrayList
$cb = [SP.Api+EnumProc]{
    param($h, $p)
    $winPid = 0
    [void][SP.Api]::GetWindowThreadProcessId($h, [ref]$winPid)
    if ($winPid -eq $proc.ProcessId -and [SP.Api]::IsWindowVisible($h)) {
        $r = New-Object SP.Api+RECT
        if ([SP.Api]::GetWindowRect($h, [ref]$r)) {
            $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
            if ($w -gt 100 -and $hh -gt 60) {
                [void]$script:cands.Add([pscustomobject]@{ H = $h; W = $w; Hh = $hh; R = $r })
            }
        }
    }
    return $true
}
[void][SP.Api]::EnumWindows($cb, [IntPtr]::Zero)
"面板进程可见窗口: " + $script:cands.Count
foreach ($c in $script:cands) { "  {0}x{1} @{2},{3}" -f $c.W, $c.Hh, $c.R.Left, $c.R.Top }
$win = $script:cands | Sort-Object W | Select-Object -First 1
if (-not $win) { '没找到弹窗'; return }
$scale = 3
$bw = [int](($win.R.Right - $win.R.Left) * $scale)
$bh = [int](($win.R.Bottom - $win.R.Top) * $scale)
$bmp = New-Object System.Drawing.Bitmap -ArgumentList $bw, $bh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$src = New-Object System.Drawing.Rectangle -ArgumentList $win.R.Left, $win.R.Top, ($win.R.Right - $win.R.Left), ($win.R.Bottom - $win.R.Top)
$g.CopyFromScreen($src.Location, (New-Object System.Drawing.Point -ArgumentList 0, 0), $src.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"截图 -> {0}（{1}x{2}）" -f $Out, $bw, $bh
