# panel-sampler.ps1 —— 采样：后台 runspace 的启动与自检
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Start-Sampler {
    <#
      .SYNOPSIS (Re)create the sampler runspace. Safe to call repeatedly.
      .NOTES    A runspace that faults or exits leaves the UI showing stale numbers
                forever, so Update-Panel watches the handle and restarts it.
    #>
    $script:Rs = [runspacefactory]::CreateRunspace()
    $script:Rs.ApartmentState = 'MTA'
    $script:Rs.ThreadOptions = 'ReuseThread'
    $script:Rs.Open()
    $script:Ps = [powershell]::Create()
    $script:Ps.Runspace = $script:Rs
    [void]$script:Ps.AddScript($sampler).AddArgument($script:Sync)
    $script:Handle = $script:Ps.BeginInvoke()
}

function Test-Sampler {
    param([switch]$Silent)
    if ($script:Sync.Stop) { return }
    if ($null -ne $script:Handle -and $script:Handle.IsCompleted) {
        if (-not $Silent) { Write-Dbg 'SAMPLER DIED - restarting it' }
        try { $script:Ps.Stop() } catch { }
        try { $script:Rs.Close() } catch { }
        $script:Sync.Snapshot = $null
        $script:Sync.Hist = @()
        Start-Sampler
        $script:Sync.Restarts = 1 + [int]$script:Sync.Restarts
        $script:Sync.LastWrite = [pscustomobject]@{
            Ok = $false; At = (Get-Date)
            Msg = ('采样器曾中断，已自动重启（第 {0} 次）' -f $script:Sync.Restarts)
        }
        return $true
    }
    return $false
}

