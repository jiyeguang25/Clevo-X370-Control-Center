# panel-selftest.ps1 —— 自检：接线核查、真点、作用域静态检查
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Get-WiredEventNames($el) {
    $out = @()
    if (-not $el -or -not $script:WireStoreProp) { return $out }
    try { $store = $script:WireStoreProp.GetValue($el) } catch { return $out }
    if (-not $store) { return $out }
    foreach ($k in $script:WireEventMap.Keys) {
        try { if ($store.Contains($script:WireEventMap[$k])) { $out += $k } } catch { }
    }
    return $out
}

# 「应该接了什么」这份清单是手写的，遗漏风险由两点兜住：一是每条都对着上面的绑定代码抄，
# 二是自检里还有几个**真点**（Invoke-Click）会走完整链路。
function Get-ExpectedWiring {
    $w = New-Object System.Collections.ArrayList
    $one = { param([string]$nm, [string]$ev) [void]$w.Add([pscustomobject]@{ Name = $nm; Ev = $ev }) }
    $many = { param([string]$pre, [int]$cnt, [string]$ev)
        for ($i = 0; $i -lt $cnt; $i++) { [void]$w.Add([pscustomobject]@{ Name = "$pre$i"; Ev = $ev }) } }
    & $many 'Pwr' $script:PowerPills.Count 'Up'
    & $one 'RevertBtn' 'Up'
    & $many 'Gpu' $script:GpuPills.Count 'Up'
    & $one 'GpuOk' 'Up'
    & $one 'GpuCancel' 'Up'
    & $one 'GpuRebootBtn' 'Up'
    & $many 'Chg' $script:ChargerPills.Count 'Up'
    & $many 'ChgS' $script:ChargerStartPills.Count 'Up'
    & $many 'ChgE' $script:ChargerStopPills.Count 'Up'
    & $one 'BrightSlider' 'Value'
    foreach ($pre in 'Tp', 'Wk', 'Fl', 'Ws', 'Nl') { & $many $pre 2 'Up' }
    & $many 'Led' $script:LedModePills.Count 'Up'
    & $many 'Dir' $script:LedDirPills.Count 'Up'
    & $many 'Rgb' $script:RgbPills.Count 'Up'
    & $many 'RgbB' $script:RgbBrightness.Count 'Up'
    & $many 'Spd' $script:LedSpeedPills.Count 'Up'
    & $one 'ColorWheel' 'Up'
    & $many 'Auto' $script:AutostartPills.Count 'Up'
    & $many 'Tray' 2 'Up'
    foreach ($t in 'State', 'Perf', 'Cool', 'Kb', 'Batt', 'Misc', 'Sys', 'About') { & $one "TabBtn$t" 'Up' }
    & $many 'Fan' $script:FanPills.Count 'Up'
    foreach ($f in 'Ct2T', 'Ct2D', 'Ct3T', 'Ct3D') { & $one "${f}Minus" 'Up'; & $one "${f}Plus" 'Up' }
    & $one 'MinBtn' 'Down'
    & $one 'TitleBar' 'Down'
    & $one 'CloseBtn' 'Down'
    return $w
}

function Get-TrayMenuLeaves {
    # 叶子和"点一下就有反应的项"才算要接线；分隔线、纯下拉父项、禁用项不算
    $out = New-Object System.Collections.ArrayList
    if (-not $script:Tray -or -not $script:Tray.ContextMenuStrip) { return $out }
    $walk = {
        param($items)
        foreach ($it in $items) {
            if ($it -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
            if ($it.DropDownItems.Count -gt 0) { & $walk $it.DropDownItems; continue }
            if (-not $it.Enabled) { continue }
            [void]$out.Add($it)
        }
    }
    & $walk $script:Tray.ContextMenuStrip.Items
    return $out
}

function Get-WinFormsClickWired($item) {
    if (-not $script:TrayClickKey) { return $null }        # null = 查不了
    try {
        $f = [System.ComponentModel.Component].GetField('events',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        $list = $f.GetValue($item)
        if (-not $list) { return $false }
        return ($null -ne $list[$script:TrayClickKey])
    }
    catch { return $null }
}

function Test-PanelWiring {
    $missing = New-Object System.Collections.ArrayList
    $total = 0

    # 先验"探测器"本身：造两个不在可视树里的临时 Border，一个接事件、一个不接，看能不能分辨。
    # 不验的话，"应接 94 缺 0"也可能只是因为这个探测器永远返回"接了"——那就成了绿色的摆设。
    $detector = $false
    $detectorNote = ''
    try {
        $pb = New-Object System.Windows.Controls.Border
        $before = @(Get-WiredEventNames $pb)
        $pb.Add_MouseLeftButtonUp({ })
        $after = @(Get-WiredEventNames $pb)
        $detector = ($before.Count -eq 0) -and ($after -contains 'Up')
        $detectorNote = ('空控件=[{0}] 接过后=[{1}]' -f ($before -join '+'), ($after -join '+'))
    }
    catch { $detectorNote = '探测器抛异常: ' + $_.Exception.Message }
    if (-not $detector) { [void]$missing.Add('接线探测器失效（' + $detectorNote + '）——「缺 0 个」这个结论不可信') }

    foreach ($e in (Get-ExpectedWiring)) {
        $total++
        $el = $n[$e.Name]
        if (-not $el) { $el = $script:Win.FindName($e.Name) }
        if (-not $el) { [void]$missing.Add("$($e.Name)（控件不存在）"); continue }
        $has = @(Get-WiredEventNames $el)
        if ($has -notcontains $e.Ev) {
            [void]$missing.Add(('{0}（要 {1}；实际 {2}）' -f $e.Name, $e.Ev, $(if ($has.Count) { $has -join '+' } else { '一个事件都没接' })))
        }
    }
    $leaves = @(Get-TrayMenuLeaves)
    $trayChecked = 0
    foreach ($it in $leaves) {
        $total++
        $wired = Get-WinFormsClickWired $it
        if ($null -eq $wired) { [void]$missing.Add("托盘「$($it.Text)」（查不了：WinForms 反射不可用）"); continue }
        $trayChecked++
        if (-not $wired) { [void]$missing.Add("托盘「$($it.Text)」（没有 Click 处理器）") }
    }
    return [pscustomobject]@{
        Total = $total; Missing = $missing; TrayLeaves = $leaves.Count
        TrayChecked = $trayChecked; TrayReflect = $script:TrayClickKeyField
        Detector = $detector; DetectorNote = $detectorNote
    }
}

# 真·点一下：造一对鼠标消息打到控件上。**必须控件已经进了可视树**（窗口显示过）才有用——
# 没显示时 RaiseEvent 打了也不触发处理器（这条也是实测的，见 src\diag-wire6.ps1）。
# 打 MouseUp 而不是 MouseLeftButtonUp 的原因：WPF 在 MouseUp 上会把左键那一路提升出来，
# 一次消息就能同时喂到 Up 处理器，和真人按一下的行为一致；每次 Raised 只会触发一次。
function Invoke-Click([string]$name) {
    $el = $(if ($n[$name]) { $n[$name] } else { $script:Win.FindName($name) })
    if (-not $el) { return $false }
    try {
        $d = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $d.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
        $el.RaiseEvent($d)
        $u = New-Object System.Windows.Input.MouseButtonEventArgs(
            [System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $u.RoutedEvent = [System.Windows.UIElement]::MouseUpEvent
        $el.RaiseEvent($u)
        return $true
    }
    catch {
        Write-Dbg ('Invoke-Click ' + $name + ' FAILED: ' + $_.Exception.Message)
        return $false
    }
}

# ------------------------------------------------------- 作用域自检（静态）---
# 第二类"接上了也不干活"的坑，就是显卡模式那次：处理块用 GetNewClosure() 生成，块里给
# `$script:某标量 = ...` 赋值 —— 那个赋值落进闭包自己的模块作用域，外面的脚本作用域看不到，
# 于是另一个处理块（读同一个变量）永远读到 0，**一条命令都不发**。属性赋值不受影响
# （`$script:LedSel.X = ...` 改的是对象），所以键盘灯一直是好的、这个坑只坑到显卡模式。
# 这类错误在运行时看不出来（点击有反应、界面有变化），只能用静态检查挡住。
# 这里直接解析**自己的源文件**，把 GetNewClosure() 的块里所有 `$script:标量 =` 找出来。
# 找不到自己的文件就如实写"没检查"，不假装通过。
function Test-ClosureScopeTrap([string]$Path) {
    $res = [pscustomobject]@{ Checked = $false; Blocks = 0; Hits = @(); Note = ''; DetectorOk = $false }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $res.Note = '拿不到自己的源文件路径，没检查'; return $res }
    try {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    }
    catch { $res.Note = '解析自己的源文件失败: ' + $_.Exception.Message; return $res }
    $hits = New-Object System.Collections.ArrayList
    $closures = $ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $a.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $a.Member.Value -eq 'GetNewClosure'
        }, $true)
    foreach ($c in $closures) {
        # `{ ... }.GetNewClosure()` 里那个脚本块是**被调用者**（Expression），不是参数 ——
        # 第一版按 Arguments 找，结果"闭包块数 = 0"，白扫一遍（18 个调用点一个都没看到）。
        $cands = @($c.Expression) + @($c.Arguments)
        foreach ($arg in $cands) {
            if ($arg -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $res.Blocks++
            $bad = $arg.ScriptBlock.FindAll({
                    param($a)
                    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.IsScript
                }, $true)
            foreach ($b in $bad) {
                [void]$hits.Add(('第 {0} 行：GetNewClosure 块里给 {1} 赋值（赋值会留在闭包自己的作用域，别处读不到）' -f `
                            $b.Extent.StartLineNumber, $b.Left.VariablePath.UserPath))
            }
        }
    }
    $res.Checked = $true
    $res.Hits = $hits
    # 探测器自检：拿一段**已知有坑**的代码扫一遍，扫不出来就说明这个检查是摆设
    # （第一版就因为找错了 AST 属性而"闭包块 = 0"，扫了个寂寞还照样报"没有坑"）。
    $res.DetectorOk = $false
    try {
        $te = $null
        $tast = [System.Management.Automation.Language.Parser]::ParseInput(
            '$probe = { $script:ProbeTrap = 1 }.GetNewClosure()', [ref]$null, [ref]$te)
        $tc = $tast.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $a.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $a.Member.Value -eq 'GetNewClosure'
            }, $true)
        foreach ($c in $tc) {
            foreach ($arg in (@($c.Expression) + @($c.Arguments))) {
                if ($arg -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
                $t = $arg.ScriptBlock.FindAll({
                        param($a)
                        $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $a.Left.VariablePath.IsScript
                    }, $true)
                if (@($t).Count -gt 0) { $res.DetectorOk = $true }
            }
        }
    }
    catch { $res.DetectorOk = $false }
    return $res
}

# 每次暂存都问一次：暂存是用户点「药丸 + 确认」两步做出来的，本来就是"我现在想切"的意思，
# 所以不存在"问过了就不再问"的道理（换回原来的模式也一样要重启才生效）。真正需要防的是
# 同一次暂存被问两遍 —— 那个由"读到就清空 RebootAsk"保证。
function Test-RebootAsk {
    $ra = $script:Sync.RebootAsk
    if (-not $ra) { return }
    $script:Sync.RebootAsk = $null
    if ($SelfTest -or $SizeProbe) {
        Write-Dbg ('REBOOT-ASK: 模式 {0} 已暂存（诊断模式下不弹窗）' -f $ra.Mode)
        return
    }
    try { Show-RebootPrompt -Mode ([int]$ra.Mode) }
    catch { Write-Dbg ('REBOOT-PROMPT FAILED: ' + $_.Exception.Message) }
}

function Test-ResumeGap {
    $now = Get-Date
    $prev = $script:LastTickAt
    $script:LastTickAt = $now
    if ($null -eq $prev) { return }
    $gap = ($now - $prev).TotalSeconds
    if ($gap -lt $script:ResumeGapSeconds) { return }
    Write-Dbg ('RESUME: 系统停摆 {0:N0} 秒（睡眠/休眠恢复），重新注入键盘灯' -f $gap)
    $script:LedRestored = $false
    $script:LedRestoreWaited = $false
}

function Test-ShowRequest {
    try {
        if (-not (Test-Path -LiteralPath $script:ShowFlag)) { return }
        Remove-Item -LiteralPath $script:ShowFlag -Force -ErrorAction SilentlyContinue
        $script:Win.Show()
        $script:Win.Activate()
        $n.StatusText.Text = '已有一个面板在运行，这是它（窗口已调到前面）'
        $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
        Write-Dbg 'show.request consumed -> window shown+activated'
    }
    catch { Write-Dbg ('show.request failed: ' + $_.Exception.Message) }
}

