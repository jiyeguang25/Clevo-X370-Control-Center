# 把屏幕的某一块拍下来（默认整屏，-TaskbarOnly 拍任务栏那一条）。
# 关键点：先 SetProcessDPIAware，否则 DPI-unaware 的进程只能看到被缩放过的桌面
# （这台机器上 2560x1440 会被报成 1707x960），截出来的图发虚、坐标也和 UIA 对不上。
# 用法：diag-screenshot.ps1 [-TaskbarOnly] [-Rect "x,y,w,h"] [-Scale 3] [-Out path]
param([switch]$TaskbarOnly, [string]$Rect, [double]$Scale = 1, [string]$Out)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Shot -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][Shot.Api]::SetProcessDPIAware()

$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$parts = @()
if ($Rect) { $parts = @($Rect -split ',' | ForEach-Object { [int]$_.Trim() }) }
if ($parts.Count -eq 4) { $bx = $parts[0]; $by = $parts[1]; $bw = $parts[2]; $bh = $parts[3] }
else {
    $bx = [int]$b.X; $by = [int]$b.Y; $bw = [int]$b.Width; $bh = [int]$b.Height
    if ($TaskbarOnly) { $strip = 48; $by = $by + $bh - $strip; $bh = $strip }
}
if (-not $Out) { $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\screen.png' }
$dir = Split-Path $Out -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$w = [int]($bw * $Scale); $hh = [int]($bh * $Scale)
$bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$src = New-Object System.Drawing.Rectangle -ArgumentList $bx, $by, $bw, $bh
$g.CopyFromScreen($src.Location, (New-Object System.Drawing.Point -ArgumentList 0, 0), $src.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"desktop {0}x{1}; captured {2},{3} {4}x{5} -> {6} ({7}x{8})" -f $b.Width, $b.Height, $bx, $by, $bw, $bh, $Out, $w, $hh
