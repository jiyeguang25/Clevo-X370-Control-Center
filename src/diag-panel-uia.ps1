# 从外面读面板当前显示的文字（UIA）—— 不碰你的鼠标，也不进面板进程。
# 用途：面板现在认为"显卡模式"是什么状态、状态栏最后一条消息是什么，一看就知道用户点了以后发生了什么。
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$panels = @(Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
if (-not $panels.Count) { '没有面板窗口'; return }
$proc = $panels[0]
$h = $proc.MainWindowHandle
"面板: pid {0} hwnd {1}" -f $proc.Id, $h
$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
"窗口标题: {0}" -f $root.Current.Name
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
"元素数: {0}" -f $all.Count
$i = 0
foreach ($e in $all) {
    $i++
    $n = $e.Current.Name
    if (-not $n) { continue }
    $r = $e.Current.BoundingRectangle
    $vis = $e.Current.IsOffscreen
    # 折叠/虚拟化的元素会给出 Infinity 的坐标，直接 [int] 转换会抛（第一次跑就刷了一屏红字）
    $rx = $(if ([double]::IsInfinity($r.X) -or [double]::IsNaN($r.X)) { 'inf' } else { [string][int]$r.X })
    $ry = $(if ([double]::IsInfinity($r.Y) -or [double]::IsNaN($r.Y)) { 'inf' } else { [string][int]$r.Y })
    $rw = $(if ([double]::IsInfinity($r.Width) -or [double]::IsNaN($r.Width)) { 'inf' } else { [string][int]$r.Width })
    $rh = $(if ([double]::IsInfinity($r.Height) -or [double]::IsNaN($r.Height)) { 'inf' } else { [string][int]$r.Height })
    "  [{0}] type={1} offscreen={2} @{3},{4} {5}x{6}  '{7}'" -f `
        $i, $e.Current.ControlType.ProgrammaticName, $vis, $rx, $ry, $rw, $rh, $n
}
