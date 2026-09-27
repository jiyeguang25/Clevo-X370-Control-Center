# 图标对照：把 dist\ClevoHelper.exe 里真的嵌进去的图标、app.ico 里各档、以及托盘会用的那一档
# 画在一张图上，放大后我自己看 —— "任务栏图标和托盘不一样"这种事只能用眼睛确认。
Add-Type -AssemblyName System.Drawing

$exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\ClevoHelper.exe'
$ico = Join-Path $PSScriptRoot 'app.ico'
$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\icon-compare.png'

$tiles = @()
function Add-Tile([string]$label, $img) {
    $script:tiles += [pscustomobject]@{ Label = $label; Img = $img }
}
if (Test-Path -LiteralPath $exe) {
    try {
        $i = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        Add-Tile 'exe (ExtractAssociatedIcon)' $i.ToBitmap()
        "exe icon size: {0}x{1}" -f $i.Width, $i.Height
    }
    catch { "exe icon 提取失败: $($_.Exception.Message)" }
}
else { "没有 $exe" }
if (Test-Path -LiteralPath $ico) {
    foreach ($sz in 16, 32, 48, 64, 128, 256) {
        try {
            $ic = New-Object System.Drawing.Icon($ico, $sz, $sz)
            Add-Tile ("app.ico {0}" -f $sz) $ic.ToBitmap()
        }
        catch { "app.ico $sz 读不了: $($_.Exception.Message)" }
    }
}

if (-not $tiles.Count) { '没有可对照的图标'; return }
$scale = 3
$pad = 12
$cell = [int](256 * $scale)
$w = $tiles.Count * ($cell + $pad) + $pad
$h = $cell + 60
$bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(30, 32, 36))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixel
$font = New-Object System.Drawing.Font('Consolas', 13)
$brush = [System.Drawing.Brushes]::White
$x = $pad
foreach ($t in $tiles) {
    $iw = [int]($t.Img.Width * $scale); $ih = [int]($t.Img.Height * $scale)
    $g.DrawString($t.Label, $font, $brush, [single]$x, 8)
    $g.DrawImage($t.Img, (New-Object System.Drawing.Rectangle -ArgumentList $x, 40, $iw, $ih))
    $x += $cell + $pad
}
$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"对照图 -> {0} ({1}x{2})" -f $out, $w, $h
