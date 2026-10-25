# panel-mode.ps1 —— 模式与杂项：显卡模式二次确认、杂项写读、开机自启
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Set-GpuStage([int]$Mode) {
    $cur = $(if ($script:Sync.Snapshot) { [int]$script:Sync.Snapshot.GpuMode } else { -1 })
    $staged = [int]$(if ($script:Sync.Snapshot) { $script:Sync.Snapshot.GpuStaged } else { 0 })
    # 只有"既没暂存过、点的又是当前模式"才是真的没事可做。**一旦暂存过别的模式，点当前模式
    # 那一颗就是"撤销暂存"** —— 否则用户暂存了核显又反悔，就只能靠 [恢复初始] 才能拉回来
    # （自检就撞上了这个：想暂存回独显，点了没反应，最后 EC 里留着的还是核显）。
    if ($cur -eq $Mode -and $staged -eq 0) {
        $n.StatusText.Text = ('当前已经是「{0}」，无需切换' -f $script:GpuModeName[$Mode])
        $n.StatusText.Foreground = Get-Brush '#FF6B7385'
        return
    }
    $script:GpuStage = $Mode
    $n.GpuNow.Visibility = 'Collapsed'
    $n.GpuConfirm.Visibility = 'Visible'
    $n.GpuConfirmText.Text = $(if ($Mode -eq $cur) {
            ('撤销暂存、回到「{0}」？重启后生效' -f $script:GpuModeName[$Mode])
        }
        else { ('切到「{0}」？重启后生效' -f $script:GpuModeName[$Mode]) })
}

function Confirm-GpuStage {
    $m = [int]$script:GpuStage
    $script:GpuStage = 0
    $n.GpuConfirm.Visibility = 'Collapsed'
    $n.GpuNow.Visibility = 'Visible'
    if ($m -gt 0) { Request-Write -Mode $m -Kind 'gpu' }
}

function Cancel-GpuStage {
    $script:GpuStage = 0
    $n.GpuConfirm.Visibility = 'Collapsed'
    $n.GpuNow.Visibility = 'Visible'
    $n.StatusText.Text = '已取消，没有写入任何东西'
    $n.StatusText.Foreground = Get-Brush '#FF6B7385'
}

# ---- 杂项：每一项都是「写 + 读回」 ------------------------------------------
# One request kind with a Sub field, because the four channels behind it are unrelated
# (DCHU byte frame, DCHU cmd 0x19, registry+hotkey, WMI). The sampler owns the write and
# the read-back, exactly like every other control in this panel.
function Request-Misc([string]$Sub, $Value, [switch]$Startup) {
    $script:Sync.Pending = [pscustomobject]@{ Kind = 'misc'; Sub = $Sub; Value = $Value; Startup = [bool]$Startup; At = (Get-Date) }
    $what = switch ($Sub) {
        'charger'  { '电池充电' }
        'start'    { '充电开始电量' }
        'stop'     { '充电停止电量' }
        'bright'   { '屏幕亮度' }
        'touchpad' { '触控板' }
        'winkey'   { 'Win 键' }
        'fnlock'   { 'FnLock' }
        'winfn'    { 'Win/Fn 交换' }
        'numlock'  { '数字键盘' }
        default    { $Sub }
    }
    $n.StatusText.Text = ('正在设置{0}…' -f $what)
    $n.StatusText.Foreground = Get-Brush '#FF6B7385'
}

function Set-Autostart([bool]$On) {
    try {
        if ($On) {
            $r = Enable-Autostart
            $where = $(if ($r.Installed) { $r.Installed } else { '(没找到可复制的 exe，启动时会去候选路径里找)' })
            $n.StatusText.Text = ('开机自启已开启：程序已放到 {0}，下次登录从那里启动、直接进托盘' -f $where)
        }
        else {
            [void](Disable-Autostart)
            $n.StatusText.Text = '开机自启已关闭。'
        }
        $n.StatusText.Foreground = Get-Brush '#FF6FE38A'
    }
    catch {
        $n.StatusText.Text = '设置开机自启失败：' + $_.Exception.Message
        $n.StatusText.Foreground = Get-Brush '#FFE38A6F'
    }
    $script:AutostartOn = Get-AutostartState
}

