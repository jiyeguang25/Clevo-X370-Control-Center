# 探针 6：把窗口真的显示出来、控件进了可视树以后，人工 RaiseEvent 能不能触发处理器？
# （探针 1 里窗口没显示，Border 不在可视树里，RaiseEvent 打了 0 次 —— 看看是不是这个原因）
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$w = New-Object System.Windows.Window
$w.Width = 200; $w.Height = 120
$b = New-Object System.Windows.Controls.Border
$b.Name = 'Probe'; $b.Background = [System.Windows.Media.Brushes]::Gray
$w.Content = $b
$script:hits = 0
$b.Add_MouseLeftButtonUp({ $script:hits++; Write-Host '  >>> MouseLeftButtonUp handler RAN' })
$script:upHits = 0
$b.AddHandler([System.Windows.UIElement]::MouseUpEvent, [System.Windows.RoutedEventHandler]{ $script:upHits++; Write-Host '  >>> MouseUp handler RAN' })

$w.Add_ContentRendered({
    $b.UpdateLayout()
    Write-Host ("IsLoaded={0} IsVisible={1}" -f $b.IsLoaded, $b.IsVisible)
    $tries = @(
        @{ N = 'MouseLeftButtonUp'; E = [System.Windows.UIElement]::MouseLeftButtonUpEvent },
        @{ N = 'MouseUp';           E = [System.Windows.UIElement]::MouseUpEvent }
    )
    foreach ($t in $tries) {
        try {
            $a = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
            $a.RoutedEvent = $t.E
            $b.RaiseEvent($a)
            Write-Host ("RaiseEvent({0}) ok -> upHits={1} upEventHits={2}" -f $t.N, $script:hits, $script:upHits)
        }
        catch { Write-Host ("RaiseEvent({0}) FAILED: {1}" -f $t.N, $_.Exception.Message) }
    }
    $w.Close()
})
[void]$w.ShowDialog()
Write-Host ("final: upHits={0} upEventHits={1}   <- 都 >=1 才说明能'真点'" -f $script:hits, $script:upHits)
