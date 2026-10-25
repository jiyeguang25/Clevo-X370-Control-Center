# panel-reboot.ps1 —— 重启申请：显卡模式生效提示窗与倒计时
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

# ---------------------------------------------------------------- 重启申请 ---
# 显卡模式是开机前（pre-boot）值：**暂存完必须重启一次才生效**。原厂控制中心的做法是
# `shutdown -f -r -t 0` —— 直接替你重启；我们不做这种事，但也不能只把话写在状态栏里让用户
# 自己想起来。所以暂存成功后弹一张"重启申请"：
#   「立即重启」→ 安排 20 秒后重启（同一个窗口变成倒计时，期间可以「取消重启」，走 shutdown /a）
#   「稍后我自己重启」→ 关掉，什么都不做
#
# 两个实现上的注意：
#   1. **非模态**（Show 而不是 ShowDialog）：面板的采样/重画走的是 DispatcherTimer，弹模态
#      对话框会套一层嵌套消息循环，多一层就多一处出问题的机会；而且这张申请不该卡住面板。
#   2. 对话框里的状态一律放在一个**hashtable**里（$st）传给命名函数用。原因见显卡模式那个
#      作用域陷阱（README 3.40）：给对象赋属性跨作用域没问题，给 `$script:标量` 赋值才会丢。
#      这里所有处理块都只是 `函数 $st`，没有任何脚本作用域赋值 —— 面板启动时的静态扫描会盯着。
function New-RebootButton([string]$Text, [string]$Bg, [string]$Fg, [switch]$Accent) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $Bg
    $b.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 13
    $b.MinWidth = 104
    $b.Padding = New-Object System.Windows.Thickness -ArgumentList 0, 7, 0, 7
    $b.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 8, 0
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = Get-Brush $Fg
    $t.FontSize = 12
    $t.TextAlignment = 'Center'
    if ($Accent) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $b.Child = $t
    return $b
}

function Confirm-RebootNow($st) {
    # 只做"安排"：真正的重启由 Windows 在倒计时结束后执行，期间用户可以取消
    if ($st.Dry) {
        Write-Dbg 'REBOOT-PROMPT(dry): 点到「立即重启」——测试模式，不真的重启'
    }
    else {
        try {
            Start-Process -FilePath 'shutdown.exe' -WindowStyle Hidden -ArgumentList @(
                '/r', '/t', '20', '/c', 'ClevoHelper：重启以应用显卡模式')
            $st.Scheduled = $true
        }
        catch { $st.Note.Text = '安排重启失败：' + $_.Exception.Message }
    }
    $st.Ask.Visibility = 'Collapsed'
    $st.Count.Visibility = 'Visible'
    # dry（自检用）只走 5 秒，免得测试拖时间；真跑是 20 秒
    $st.Sec = $(if ($st.Dry) { 5 } else { 20 })
    $st.Note.Text = ('{0} 秒后重启…（点「取消重启」可以中止）' -f $st.Sec)
    if (-not $st.Timer) {
        $st.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $st.Timer.Interval = [TimeSpan]::FromSeconds(1)
        $st.Timer.Add_Tick({ Step-RebootCountdown $st }.GetNewClosure())
        $st.Timer.Start()
    }
}

function Step-RebootCountdown($st) {
    $st.Sec = [int]$st.Sec - 1
    if ($st.Sec -le 0) {
        try { $st.Timer.Stop() } catch { }
        try { $st.Win.Close() } catch { }
        return
    }
    $st.Note.Text = ('{0} 秒后重启…（点「取消重启」可以中止）' -f $st.Sec)
}

function Cancel-RebootNow($st) {
    if ($st.Dry) { Write-Dbg 'REBOOT-PROMPT(dry): 点到「取消重启」' }
    if ($st.Scheduled -and -not $st.Dry) {
        try {
            Start-Process -FilePath 'shutdown.exe' -WindowStyle Hidden -ArgumentList @('/a')
            $st.Note.Text = '已取消重启。想生效时自己重启一次即可。'
        }
        catch { $st.Note.Text = '取消失败：' + $_.Exception.Message }
    }
    else { $st.Note.Text = '已取消。想生效时自己重启一次即可。' }   # dry 也走这条，让自检能看到文案
    if ($st.Timer) { try { $st.Timer.Stop() } catch { } }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(1800)
    $t.Add_Tick({ $t.Stop(); $st.Win.Close() }.GetNewClosure())
    $t.Start()
}

function Show-RebootPrompt([int]$Mode, [switch]$DryRun) {
    $name = $(if ($script:GpuModeName.ContainsKey($Mode)) { $script:GpuModeName[$Mode] } else { "模式 $Mode" })
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.SizeToContent = 'WidthAndHeight'
    $w.Width = 380
    $w.ShowInTaskbar = $false
    $w.Topmost = $true
    $w.WindowStartupLocation = $(if ($script:Win.IsVisible) { 'CenterOwner' } else { 'CenterScreen' })
    if ($script:Win.IsVisible) { $w.Owner = $script:Win }

    $root = New-Object System.Windows.Controls.Border
    $root.Background = Get-Brush '#FF141619'
    $root.BorderBrush = Get-Brush '#FF2B303B'
    $root.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 1
    $root.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 14
    $root.Padding = New-Object System.Windows.Thickness -ArgumentList 20, 16, 20, 16
    $stack = New-Object System.Windows.Controls.StackPanel

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = '需要重启才能生效'
    $h.Foreground = Get-Brush '#FFEDF0F5'
    $h.FontSize = 15
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$stack.Children.Add($h)

    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = ('显卡模式已暂存为「{0}」。这是开机前的设置，重启后才会真正切换。' -f $name)
    $b.Foreground = Get-Brush '#FFD7DCE6'
    $b.FontSize = 12
    $b.TextWrapping = 'Wrap'
    $b.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 9, 0, 0
    [void]$stack.Children.Add($b)

    $ask = New-Object System.Windows.Controls.StackPanel
    $q = New-Object System.Windows.Controls.TextBlock
    $q.Text = '现在重启，还是你自己找时间重启？'
    $q.Foreground = Get-Brush '#FF8A93A6'
    $q.FontSize = 11
    $q.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 6, 0, 0
    [void]$ask.Children.Add($q)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 14, 0, 0
    $btnNow = New-RebootButton '立即重启' '#FF57B0FF' '#FF11141A' -Accent
    $btnLater = New-RebootButton '稍后我自己重启' '#FF262A33' '#FFD7DCE6'
    $btnLater.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 0
    [void]$row.Children.Add($btnNow)
    [void]$row.Children.Add($btnLater)
    [void]$ask.Children.Add($row)
    [void]$stack.Children.Add($ask)

    $cnt = New-Object System.Windows.Controls.StackPanel
    $cnt.Visibility = 'Collapsed'
    $note = New-Object System.Windows.Controls.TextBlock
    $note.Foreground = Get-Brush '#FFE3C86F'
    $note.FontSize = 12
    $note.TextWrapping = 'Wrap'
    $note.Text = ''
    [void]$cnt.Children.Add($note)
    $row2 = New-Object System.Windows.Controls.StackPanel
    $row2.Orientation = 'Horizontal'
    $row2.HorizontalAlignment = 'Right'
    $row2.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 14, 0, 0
    $btnCancel = New-RebootButton '取消重启' '#FF262A33' '#FFD7DCE6'
    $btnCancel.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 0, 0, 0
    [void]$row2.Children.Add($btnCancel)
    [void]$cnt.Children.Add($row2)
    [void]$stack.Children.Add($cnt)

    $root.Child = $stack
    $w.Content = $root

    $st = [hashtable]::Synchronized(@{
            Win = $w; Ask = $ask; Count = $cnt; Note = $note; Sec = 20
            Timer = $null; Scheduled = $false; Dry = [bool]$DryRun
        })
    # 处理块只调用命名函数，并把状态作为参数传进去 —— 不写任何脚本作用域变量（作用域自检会查）
    $btnNow.Add_MouseLeftButtonUp({ Confirm-RebootNow $st }.GetNewClosure())
    $btnLater.Add_MouseLeftButtonUp({ $st.Win.Close() }.GetNewClosure())
    $btnCancel.Add_MouseLeftButtonUp({ Cancel-RebootNow $st }.GetNewClosure())
    $w.Add_KeyDown({ if ($_.Key -eq 'Escape') { $st.Win.Close() } }.GetNewClosure())
    $w.Add_MouseLeftButtonDown({ $st.Win.DragMove() }.GetNewClosure())

    $w.Show()
    $w.Activate()
    $script:RebootDlg = $st
    Write-Dbg ('REBOOT-PROMPT: 已弹出（模式={0}「{1}」dry={2}；面板可见={3}）' -f $Mode, $name, [bool]$DryRun, $script:Win.IsVisible)
}

