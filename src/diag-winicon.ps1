# 面板窗口自己挂的是什么图标？任务栏按钮画的就是这个（ICON_SMALL）。
# 光说"AUMID 设好了"不够 —— 图标要用眼睛确认是同一个来源。
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace WI -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr h, int msg, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="GetClassLongPtrW")]
public static extern System.IntPtr GetClassLongPtr(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetClassLongW(System.IntPtr h, int i);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
'@
$WM_GETICON = 0x007F
$ICON_SMALL = 0; $ICON_BIG = 1; $ICON_SMALL2 = 2

$panels = @(Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
if (-not $panels.Count) { '没有带主窗口的 powershell 进程'; return }
$proc = $panels[0]
$h = $proc.MainWindowHandle
"面板窗口: pid {0} hwnd {1}" -f $proc.Id, $h

$out = @()
foreach ($spec in @(@('WM_GETICON ICON_SMALL', $ICON_SMALL), @('WM_GETICON ICON_BIG', $ICON_BIG), @('WM_GETICON ICON_SMALL2', $ICON_SMALL2))) {
    $ic = [WI.Api]::SendMessage($h, $WM_GETICON, [IntPtr]$spec[1], [IntPtr]::Zero)
    "  {0} -> {1}" -f $spec[0], $(if ($ic -eq [IntPtr]::Zero) { '(空)' } else { $ic })
    if ($ic -ne [IntPtr]::Zero) { $out += [pscustomobject]@{ Label = $spec[0]; H = $ic } }
}
# GCLP_HICONSM = -34, GCLP_HICON = -14
$cls = [WI.Api]::GetClassLongPtr($h, -34)
"  GetClassLongPtr(GCLP_HICONSM) -> {0}" -f $cls
if ($cls -ne [IntPtr]::Zero) { $out += [pscustomobject]@{ Label = 'GCLP_HICONSM'; H = $cls } }

if (-not $out.Count) { '窗口没有任何图标句柄'; return }
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'
$scale = 4
$cell = 96
$bmp = New-Object System.Drawing.Bitmap -ArgumentList ($out.Count * ($cell + 10) + 10), ($cell + 40)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(30, 32, 36))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$font = New-Object System.Drawing.Font('Consolas', 11)
$x = 10
foreach ($o in $out) {
    try {
        $ico = [System.Drawing.Icon]::FromHandle($o.H)
        $b = $ico.ToBitmap()
        $g.DrawString($o.Label, $font, [System.Drawing.Brushes]::White, [single]$x, 4)
        $dw = [int]($b.Width * $scale); $dh = [int]($b.Height * $scale)
        $rect = New-Object System.Drawing.Rectangle -ArgumentList $x, 30, $dw, $dh
        $g.DrawImage($b, $rect)
        "  {0}: {1}x{2}" -f $o.Label, $b.Width, $b.Height
        $x += $cell + 10
    }
    catch { "  {0}: 取不出来: {1}" -f $o.Label, $_.Exception.Message }
}
$g.Dispose()
$f = Join-Path $dir 'window-icons.png'
$bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"窗口图标对照 -> {0}" -f $f
