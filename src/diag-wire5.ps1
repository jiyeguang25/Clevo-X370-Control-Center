# 探针 5：两件事
#   A. Contains(RoutedEvent) 是不是真的按事件区分（只接了 Up，问 Down 必须 False）—— 这是接线
#      自检成立的前提，否则"Contains 返回 True"只能说明"这控件随便接了个事件"。
#   B. 能不能按 GlobalIndex 从 FrugalMap 里捞出真委托（捞到就能在自检里真的"点"按钮）。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$flags = [System.Reflection.BindingFlags]'Instance,NonPublic,Public,Static'
function Get-Store($el) { [System.Windows.UIElement].GetProperty('EventHandlersStore', $flags).GetValue($el) }

$b = New-Object System.Windows.Controls.Border
$script:hits = 0
$b.Add_MouseLeftButtonUp({ $script:hits++; Write-Host 'HANDLER RAN' })
$b2 = New-Object System.Windows.Controls.Border
$b2.Add_MouseLeftButtonDown({ })
$b3 = New-Object System.Windows.Controls.Border      # 完全没接线

$up = [System.Windows.UIElement]::MouseLeftButtonUpEvent
$down = [System.Windows.UIElement]::MouseLeftButtonDownEvent
$wheel = [System.Windows.UIElement]::MouseWheelEvent

foreach ($pair in @(@('only-Up', $b), @('only-Down', $b2), @('nothing', $b3))) {
    $s = Get-Store $pair[1]
    if (-not $s) { Write-Host ("[{0}] store=null -> Up={1} Down={2} Wheel={3}" -f $pair[0], 'n/a', 'n/a', 'n/a'); continue }
    $r = @()
    foreach ($e in @(@('Up', $up), @('Down', $down), @('Wheel', $wheel))) {
        try { $r += ('{0}={1}' -f $e[0], $s.Contains($e[1])) } catch { $r += ('{0}=THREW({1})' -f $e[0], $_.Exception.InnerException.GetType().Name) }
    }
    Write-Host ("[{0}] store=present  {1}" -f $pair[0], ($r -join '  '))
}

Write-Host '--- B: FrugalMap 取值 ---'
$store = Get-Store $b
$fm = $store.GetType().GetField('_entries', $flags).GetValue($store)
$ft = $fm.GetType()
foreach ($p in $ft.GetProperties($flags)) { Write-Host ("  prop {0} {1}" -f $p.PropertyType.Name, $p.Name) }
foreach ($m in $ft.GetMethods($flags)) {
    if ($m.Name -in @('get_Item', 'get_Count', 'Contains', 'GetKeyValuePair')) {
        Write-Host ("  method {0} {1}({2})" -f $m.ReturnType.Name, $m.Name, (($m.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ', '))
    }
}
$gi = [int]$up.GlobalIndex
Write-Host ("MouseLeftButtonUp GlobalIndex = {0}" -f $gi)
foreach ($k in @($gi, 0, 1, 2, 3)) {
    try {
        $v = $ft.GetProperty('Item', $flags).GetValue($fm, @($k))
        Write-Host ("  _entries[{0}] = {1}" -f $k, $(if ($v) { $v.GetType().FullName } else { 'null' }))
        if ($v) { Write-Host ("     count={0}" -f @($v).Count); @($v)[0].DynamicInvoke($null, $null); Write-Host ("     hits={0}" -f $script:hits) }
    }
    catch { Write-Host ("  _entries[{0}] THREW {1}" -f $k, $_.Exception.Message) }
}
