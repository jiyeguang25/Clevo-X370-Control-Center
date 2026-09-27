# 任务栏到底把我的窗口显示成什么？—— 用 UI Automation 问任务栏自己，别靠猜。
#
# 为什么要这么做：面板日志能证明"进程 AUMID 设了、窗口 AUMID 设了、注册项也写了"，但那都是
# 我这边的账。真正算数的是**任务栏按钮上写着什么名字、画着什么图标**。UIA 能读出按钮的 Name
# 和屏幕坐标，坐标再拿去截图，图标也就能看到了。
#
# 两个坑（都是实测踩出来的）：
#   1) 任务栏按钮挂在 Shell_TrayWnd -> MSTaskSwWClass（"运行中的应用程序"）下面，不是直接
#      挂在 Shell_TrayWnd 下；所以要从 MSTaskSwWClass 那个句柄再进 UIA。
#   2) 我的 powershell 进程默认是 DPI-unaware：屏幕 2560x1440 会被报成 1707x960，
#      CopyFromScreen 也只能拿到缩放后的画面（图标发虚）。先 SetProcessDPIAware 再截图，
#      坐标才和 UIA 给的对得上，图也才是原生的。
#
# 已知限制（本机就是这么个情况，写在这儿省得下次白折腾）：**任务栏是自动隐藏的**。
# 自动隐藏时 UIA 里 MSTaskSwWClass 下面一个按钮都拿不到（后代数 = 0），-TaskbarOnly 截图
# 拍到的也只是壁纸 —— 因为任务栏此刻根本没画出来。要拿到按钮得先把鼠标移到屏幕底边把任务栏
# 叫出来；而"移动用户的鼠标"不该我擅自做。所以本机的任务栏图标最终以肉眼确认为准
# （用户已确认：现在是和托盘一致的蓝色圆盘图标）。
param([switch]$Shot)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace Tb -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string cls, string win);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindowEx(System.IntPtr parent, System.IntPtr after, string cls, string win);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][Tb.Api]::SetProcessDPIAware()

$tray = [Tb.Api]::FindWindow('Shell_TrayWnd', $null)
if ($tray -eq [IntPtr]::Zero) { 'Shell_TrayWnd 找不到（explorer 没跑？）'; return }
# 任务栏那些按钮挂在 Shell_TrayWnd 里的 MSTaskSwWClass（"运行中的应用程序"）之下。它不是一个
# 直接子窗口（FindWindowEx 找不到），但在 UIA 树里是 Shell_TrayWnd 的后代，所以用 UIA 找它。
$trayEl = [System.Windows.Automation.AutomationElement]::FromHandle($tray)
$clsCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'MSTaskSwWClass')
$tb = $trayEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $clsCond)
if (-not $tb) { 'MSTaskSwWClass 找不到'; return }
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
$btns = $tb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
"任务栏按钮数: {0}" -f $btns.Count
$rows = @()
foreach ($b in $btns) {
    $r = $b.Current.BoundingRectangle
    $rows += [pscustomobject]@{
        Name = $b.Current.Name; Class = $b.Current.ClassName; Id = $b.Current.AutomationId
        X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 220

$hit = @($rows | Where-Object { $_.Name -match 'Clevo|PowerShell|控制' })
if (-not $hit.Count) { "没有名字里带 Clevo/PowerShell/控制 的按钮 —— 面板窗口现在可能是隐藏的（收在托盘里）"; return }
foreach ($h in $hit) { "命中的任务栏按钮: 名字=`"{0}`" 位置={1},{2} {3}x{4}" -f $h.Name, $h.X, $h.Y, $h.W, $h.H }

if ($Shot) {
    $h = $hit[0]
    $out = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\taskbar-button.png'
    $scale = 6
    $w = [int]($h.W * $scale); $hh = [int]($h.H * $scale)
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $src = New-Object System.Drawing.Rectangle -ArgumentList $h.X, $h.Y, $h.W, $h.H
    $g.CopyFromScreen($src.Location, (New-Object System.Drawing.Point -ArgumentList 0, 0), $src.Size)
    $g.Dispose()
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "按钮截图 -> {0}（{1}x{2}，放大 {3} 倍）" -f $out, $w, $hh, $scale
}
