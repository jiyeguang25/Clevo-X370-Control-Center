# panel-fan.ps1 —— 风扇曲线：四个数字的读写、EC 回写、曲线下发
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

# 曲线上的每个数都必须是 Step(5) 的倍数：界面上只能按 5 加减，所以**读进来的值一律先吸附**，
# 否则会冒出一个点不出来的数（比如 38%、59%、86°C）。
function Snap-FanValue([int]$Value, [int]$Min, [int]$Max) {
    $st = [int]$script:FanLimits.Step
    $v = [int]([Math]::Round($Value / $st) * $st)
    if ($v -lt $Min) { $v = [int]([Math]::Ceiling($Min / $st) * $st) }
    if ($v -gt $Max) { $v = [int]([Math]::Floor($Max / $st) * $st) }
    return [int]$v
}

function Set-FanCustomSafe([hashtable]$src) {
    # 四个数一起收，顺手保证 节点2温度 < 节点3温度、节点2转速 <= 节点3转速 ——
    # 这两种"界面点不出来"的状态如果被写进编辑器，加减按钮的夹取会让它卡住不动。
    $lim = $script:FanLimits
    $t2 = Snap-FanValue ([int]$src.T2) $lim.TMin $lim.TMax
    $t3 = Snap-FanValue ([int]$src.T3) $lim.TMin $lim.TMax
    $d2 = Snap-FanValue ([int]$src.D2) $lim.DMin $lim.DMax
    $d3 = Snap-FanValue ([int]$src.D3) $lim.DMin $lim.DMax
    if ($t3 -le $t2) {
        # 两个温度撞在一起时把 T3 抬上去；抬不动（T2 已经顶到上限）就把 T2 压下来 ——
        # 否则会留下"节点2 温度 == 节点3 温度"这种界面上点不出来的状态。
        $t3 = [Math]::Min($lim.TMax, $t2 + $lim.Step)
        if ($t3 -le $t2) { $t2 = [Math]::Max($lim.TMin, $t3 - $lim.Step) }
    }
    if ($d3 -lt $d2) { $d3 = $d2 }
    $script:FanCustom.T2 = $t2
    $script:FanCustom.D2 = $d2
    $script:FanCustom.T3 = $t3
    $script:FanCustom.D3 = $d3
    return $script:FanCustom
}

function Save-FanCurve {
    $script:Settings.FanCurve = @{
        T2 = [int]$script:FanCustom.T2; D2 = [int]$script:FanCustom.D2
        T3 = [int]$script:FanCustom.T3; D3 = [int]$script:FanCustom.D3
    }
    Save-Settings
    # 存下来了，界面上那行提示就该改口叫"你保存的曲线"（说的必须是真的）
    $script:FanCurveSource = 'settings'
}

function Request-FanCurve {
    param([switch]$Startup)
    # sends the current 自定义 node values (percent) - no preset index any more
    $src = $script:FanCustom
    $script:Sync.Pending = [pscustomobject]@{
        Kind = 'curve'; Label = '自定义'; Startup = [bool]$Startup
        T2 = [int]$src.T2; D2 = [int]$src.D2; T3 = [int]$src.T3; D3 = [int]$src.D3
        D1 = [int]$script:FixedFirstDuty; At = (Get-Date)
    }
    $script:LedSel.FanIdx = $script:FanCustomIndex
    # 你按下去的这一套就是"我的配置"：写进 settings.json，下次启动直接用它（不再读 EC 的当前值）
    Save-FanCurve
    Save-MyConfig 'FanMode' 6          # 「自定义」这个选择本身也要记住，否则重启后曲线不会被套用
    $n.StatusText.Text = '正在写风扇曲线「自定义」…（约 1 秒）'
}

# ---- 自定义曲线的四个数字（两个可调节点） ------------------------------------
# Only editable while 自定义 is the selected fan mode - the rows grey out otherwise, so it is
# obvious that 自动/最大 ignore them.
function Step-FanCustom([string]$Field, [int]$Delta) {
    if ($script:Sync.Snapshot -and $script:Sync.Snapshot.FanMode -ne 6) { return }
    $lim = $script:FanLimits
    $v = [int]$script:FanCustom[$Field] + $Delta
    switch ($Field) {
        'T2' { $v = [Math]::Max($lim.TMin, [Math]::Min([int]$script:FanCustom.T3 - $lim.Step, $v)) }
        'T3' { $v = [Math]::Max([int]$script:FanCustom.T2 + $lim.Step, [Math]::Min($lim.TMax, $v)) }
        'D2' { $v = [Math]::Max($lim.DMin, [Math]::Min([int]$script:FanCustom.D3, $v)) }
        'D3' { $v = [Math]::Max([int]$script:FanCustom.D2, [Math]::Min($lim.DMax, $v)) }
    }
    $script:FanCustom[$Field] = $v
    Request-FanCurve
}

