# 探针：用 ShowDialog 显示的窗口，Hide() 之后 ShowDialog 会不会返回？
# 背景：自检里点了「–」（= Win.Hide()）之后进程直接干净退出了（exit 0、没有后续日志）。
# 如果 ShowDialog 真的会被 Hide() 结束，那么"非托盘启动"那条路上的 – / × 就变成了退出程序，
# 而不是收进托盘 —— 这是个真 bug，得改成 Show() + Dispatcher.Run()。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$w = New-Object System.Windows.Window
$w.Width = 300; $w.Height = 160; $w.Title = 'probe'
$t = New-Object System.Windows.Controls.TextBlock
$t.Text = 'probe'
$w.Content = $t

$timeline = New-Object System.Collections.ArrayList
$tm = New-Object System.Windows.Threading.DispatcherTimer
$tm.Interval = [TimeSpan]::FromMilliseconds(600)
$script:step = 0
$tm.Add_Tick({
    $script:step++
    [void]$timeline.Add(('{0:N1}s step{1}' -f ((Get-Date) - $script:t0).TotalSeconds, $script:step))
    if ($script:step -eq 2) {
        [void]$timeline.Add('  -> 调 Hide()')
        $w.Hide()
    }
    if ($script:step -eq 4) {
        [void]$timeline.Add('  -> 调 Show()')
        $w.Show()
    }
    if ($script:step -eq 6) {
        [void]$timeline.Add('  -> 还没退出的话，说明 ShowDialog 没被 Hide 结束')
        $w.Close()
    }
})

$script:t0 = Get-Date
$tm.Start()
$timeline | ForEach-Object { $_ }   # 触发一次空输出（后面真正打印在下面）
[void]$timeline.Clear()
$tm.Start()
[void]$w.ShowDialog()
$el = ((Get-Date) - $script:t0).TotalSeconds
"ShowDialog 返回了：用时 {0:N1}s（step={1}）" -f $el, $script:step
foreach ($l in $timeline) { "  $l" }
if ($script:step -lt 6) { '>>> 结论：Hide() 把 ShowDialog 结束了（消息循环提前返回）' }
else { '>>> 结论：Hide() 不会结束 ShowDialog' }
