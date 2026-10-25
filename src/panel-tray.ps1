# panel-tray.ps1 —— 托盘：图标生成、收进托盘
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Get-IconBitmapSource([string]$path, [int]$size) {
    $ico = New-Object System.Drawing.Icon($path, $size, $size)
    try {
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        return $src
    }
    finally { $ico.Dispose() }
}

function Hide-ToTray {
    try {
        # 从"最小化"状态收进托盘时先把状态还原：否则下次 Show 出来的还是最小化的窗口
        if ($script:Win.WindowState -eq 'Minimized') { $script:Win.WindowState = 'Normal' }
        $script:Win.Hide()
    }
    catch { Write-Dbg ('Hide-ToTray failed: ' + $_.Exception.Message) }
    # 不给状态栏写"已收进托盘"那句话：窗口马上就隐藏了，而重画每 400ms 就会按 LastWrite
    # 把那行覆盖掉 —— 写了也是一句永远看不到的话（假装通知了，其实没有）。气泡才是看得见的反馈。
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        try {
            if ($script:Tray) {
                $script:Tray.ShowBalloonTip(3000, 'ClevoHelper 仍在运行',
                    '已收进托盘。要退出请用托盘右键菜单的「退出」（或按 Alt+F4）。', 'Info')
            }
        }
        catch { Write-Dbg ('balloon failed: ' + $_.Exception.Message) }
    }
    Write-Dbg 'window hidden to tray'
}

