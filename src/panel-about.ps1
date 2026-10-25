# panel-about.ps1 —— 关于页：版本比较、GitHub Release 查询（只在用户点的时候发一次请求）
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

# ---- 关于页：检查更新（只在你点的时候发一次请求）--------------------------------
# 三条刻意不做的：不后台轮询、不静默下载、不自动替换自己的 exe。这里只管"告诉你有没有新版"，
# 装不装、怎么装仍然是用户的事 —— 一个会自己改写自己的控制中心，出事时没人能解释。
#
# 为什么是**同步**请求（会短暂卡住界面）而不是异步回调：
# PowerShell 的 .NET 事件回调跑在线程池上，回调里再 Dispatcher.Invoke 回到 UI 线程，
# 在这个"脚本自己就是 UI 线程"的结构里容易撞上 runspace 锁（死锁比卡 6 秒糟得多）。
# 折中办法：先把"正在检查…"刷到屏幕上再发请求，最多卡 6 秒，且用户看得见在干什么。
function Compare-AppVersion([string]$a, [string]$b) {
    # 只比数字段：本项目版本一直是 x.y 或 x.y.z，tag 可能带 v 前缀。
    $pa = @(($a -replace '^[vV]', '') -split '\.' | ForEach-Object {
        $d = ($_ -replace '[^0-9].*$', ''); if ($d -eq '') { $d = '0' }; [int]$d })
    $pb = @(($b -replace '^[vV]', '') -split '\.' | ForEach-Object {
        $d = ($_ -replace '[^0-9].*$', ''); if ($d -eq '') { $d = '0' }; [int]$d })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = $(if ($i -lt $pa.Count) { $pa[$i] } else { 0 })
        $y = $(if ($i -lt $pb.Count) { $pb[$i] } else { 0 })
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    return 0
}

# 网络那一段单独抽成函数，**只为了能在自检里跑**：点按钮的路径自检点不了，
# 但"发请求 + 解析 + 比版本"是纯逻辑，自检必须能覆盖（3.38 的教训：自检看不见的等于没验）。
# Kind 取值：new / same / older / norelease / timeout / error。
function Get-LatestRelease([int]$TimeoutMs = 6000) {
    $r = [pscustomobject]@{ Ok = $false; Tag = ''; Url = ''; Kind = 'error'; Message = '' }
    try {
        $api = 'https://api.github.com/repos/{0}/releases/latest' -f $script:UpdateRepo
        $req = [System.Net.WebRequest]::Create($api)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.UserAgent = 'ClevoHelper/' + $script:AppVersion
        $req.Accept = 'application/vnd.github+json'
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $json = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        $rel = $json | ConvertFrom-Json
        $r.Tag = [string]$rel.tag_name
        $r.Url = [string]$rel.html_url
        if (-not $r.Tag) { $r.Tag = [string]$rel.name }
        if (-not $r.Url) { $r.Url = 'https://github.com/{0}/releases' -f $script:UpdateRepo }
        $cmp = Compare-AppVersion $r.Tag $script:AppVersion
        $r.Ok = $true
        $r.Kind = $(if ($cmp -gt 0) { 'new' } elseif ($cmp -lt 0) { 'older' } else { 'same' })
        $r.Message = 'ok'
    }
    catch [System.Net.WebException] {
        $r.Message = $_.Exception.Message
        # 404 = 仓库还没有任何 Release，这不是"检查失败"，要说清区别。
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { $r.Kind = 'norelease' }
        elseif ($_.Exception.Status -eq 'Timeout') { $r.Kind = 'timeout' }
        else { $r.Kind = 'error' }
        Write-Dbg ('update check failed: ' + $_.Exception.ToString())
    }
    catch {
        $r.Kind = 'error'
        $r.Message = $_.Exception.Message
        Write-Dbg ('update check failed: ' + $_.Exception.ToString())
    }
    return $r
}

