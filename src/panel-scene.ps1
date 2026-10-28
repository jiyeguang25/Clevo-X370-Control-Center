# panel-scene.ps1 —— 一键场景：把电源/风扇/键盘灯/亮度打包成一次点击
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。
#
# 为什么场景是"一个请求"而不是"连发四个请求"：
#   $script:Sync.Pending 只有一个槽，采样器每轮只取走一个（见 panel-core.ps1 里
#   Test-ReqSlotFree 那段注释）。在这里连发「电源」「风扇」「灯」「亮度」四条，
#   后三条会把前面的顶掉 —— 结果是"点了场景，只有亮度变了"，而且没人知道为什么。
#   所以场景的四个动作由采样器在**同一个请求里**顺序执行，最后一条 LastWrite 汇报结果。

# 请求的形状在这里只定义一份（New-SceneRequest）。采样器那边判断"插拔电源该自动切"时
# 是**另一个 runspace**，拿不到这里的 $script:ScenePills，所以它按 $S.SceneDefs 自己拼一条 ——
# 两处字段名必须一致（Kind/Index/Label/Power/Fan/Kb/R/G/B/Bright/Auto/Startup/At）。
# 改字段时两边一起改；只改一边的表现是"点了有效、自动切换没反应"，很难查。
function New-SceneRequest([int]$Index, [bool]$Auto) {
    if ($Index -lt 0 -or $Index -ge $script:ScenePills.Count) { return $null }
    $d = $script:ScenePills[$Index]
    [pscustomobject]@{
        Kind    = 'scene'
        Index   = $Index
        Label   = [string]$d.Label
        Power   = [int]$d.Power
        Fan     = [int]$d.Fan
        Kb      = [string]$d.Kb
        R       = [int]$d.R
        G       = [int]$d.G
        B       = [int]$d.B
        Bright  = [int]$d.Bright
        Auto    = [bool]$Auto
        Startup = $false
        At      = (Get-Date)
    }
}

function Invoke-Scene([int]$Index) {
    $req = New-SceneRequest $Index $false
    if ($null -eq $req) { return }
    # 上一发还没被取走就不顶掉它 —— 否则用户连点两档，第一档会静默地从不执行
    if (-not (Test-ReqSlotFree)) {
        $n.StatusText.Text = '上一个请求还在执行，稍等一下再点'
        $n.StatusText.Foreground = Get-Brush '#FFE3C86F'
        return
    }
    $script:SceneSel = $Index
    $script:Sync.SceneIndex = $Index
    $script:Sync.Pending = $req
    $n.StatusText.Text = ('正在套用场景「{0}」：{1} …' -f $req.Label, $script:ScenePills[$Index].Tip)
    $n.StatusText.Foreground = Get-Brush '#FF6B7385'
}

function Set-SceneAuto([bool]$On) {
    $script:SceneAuto = $On
    $script:Settings.SceneAuto = $On
    Save-Settings
    $script:Sync.SceneAuto = $On
    # 打开时先把"上次看到的供电状态"清掉：否则一开就按当前状态立刻套一次，
    # 用户会觉得"我只是勾了个开关，它把机器改了"。清掉之后第一轮只记基线，
    # 真的发生插拔时才动手。
    $script:Sync.OnAcLast = $null
    if ($On) {
        $acLabel = $script:ScenePills[[int]$script:Sync.SceneOnAc].Label
        $batLabel = $script:ScenePills[[int]$script:Sync.SceneOnBat].Label
        $n.StatusText.Text = ('已开启自动切换：插电套用「{0}」，用电池套用「{1}」' -f $acLabel, $batLabel)
    }
    else {
        $n.StatusText.Text = '已关闭自动切换（当前档位保持不变）'
    }
    $n.StatusText.Foreground = Get-Brush '#FF6FE38A'
    Write-Dbg ('scene auto = {0}（ac→{1} bat→{2}）' -f $On, $script:Sync.SceneOnAc, $script:Sync.SceneOnBat)
}
