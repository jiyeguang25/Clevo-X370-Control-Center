# panel-paint.ps1 —— 重画：把采样快照刷到界面（Update-Panel 及其小工具）
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Get-Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $script:BrushCache[$hex] = [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    }
    return $script:BrushCache[$hex]
}

function Format-GB([double]$bytes) {
    $gb = $bytes / 1GB
    if ($gb -ge 1024) { return ('{0:N2} TB' -f ($gb / 1024)) }
    if ($gb -ge 100) { return ('{0:N0} GB' -f $gb) }
    return ('{0:N1} GB' -f $gb)
}

function Set-Pill($border, $text, [bool]$on, [string]$accent) {
    if ($on) {
        $border.Background = Get-Brush $accent
        $text.Foreground = Get-Brush '#FF11141A'
        $text.FontWeight = 'SemiBold'
    }
    else {
        $border.Background = Get-Brush '#FF272C36'
        $text.Foreground = Get-Brush '#FF98A1B3'
        $text.FontWeight = 'Normal'
    }
}

function Update-Panel {
  # 重画耗时：只在**慢于阈值**时落一行日志。
  # 为什么不是每次都记：这段每 400ms 跑一次，每次都写盘会把日志刷爆（3.51 那类坑）。
  # 为什么要有：面板"一卡一卡"时，第一件要确定的事是"卡在重画，还是卡在采样"。
  # 依据（2026-10-25 实测）：单次给 TextBlock.Text 赋值的成本约 0.011 ms，本函数约 200 处赋值
  # → 正常应远低于这个阈值。一旦越过 50ms，说明某处退化了（例如每帧新建 Brush、或意外触发了
  # 布局递归），日志会带着那一刻的快照年龄一起留下来，能直接对上采样器是不是跟不上。
  $paintSw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $s = $script:Sync.Snapshot
    if ($null -eq $s) {
        if ($script:Sync.Pending) { $n.StatusText.Text = '正在切换…' }
        else { $n.StatusText.Text = '等待首次采样…' }
        return
    }
    if ($s.CpuTemp) {
        $n.CpuTemp.Text = [string]$s.CpuTemp
        $n.CpuRpm.Text = '{0:N0} RPM' -f $s.CpuFanRpm
        $n.CpuDutyText.Text = '{0}%' -f $s.CpuFanDuty
        $n.CpuBar.Width = [Math]::Round(104 * $s.CpuFanDuty / 100)
        $n.GpuTemp.Text = [string]$s.GpuTemp
        $n.GpuRpm.Text = '{0:N0} RPM' -f $s.GpuFanRpm
        $n.GpuDutyText.Text = '{0}%' -f $s.GpuFanDuty
        $n.GpuBar.Width = [Math]::Round(104 * $s.GpuFanDuty / 100)
        $script:Win.Title = 'ClevoHelper - {0}C / {1}C' -f $s.CpuTemp, $s.GpuTemp
    }
    if ($s.CpuMhz) { $n.CpuFreq.Text = '{0:N2} GHz' -f ($s.CpuMhz / 1000) } else { $n.CpuFreq.Text = '--' }
    if ($null -ne $s.CpuWatts) { $n.CpuPower.Text = '{0:N0} W' -f $s.CpuWatts } else { $n.CpuPower.Text = '--' }
    if ($s.GpuMhz) { $n.GpuFreq.Text = '{0:N0} MHz' -f $s.GpuMhz } else { $n.GpuFreq.Text = '--' }
    if ($null -ne $s.GpuWatts) { $n.GpuPower.Text = '{0:N0} W' -f $s.GpuWatts } else { $n.GpuPower.Text = '--' }
    if ($null -ne $s.CpuUtil) { $n.CpuUtil.Text = '{0}%' -f $s.CpuUtil } else { $n.CpuUtil.Text = '--' }
    if ($null -ne $s.GpuUtil) { $n.GpuUtil.Text = '{0}%' -f $s.GpuUtil } else { $n.GpuUtil.Text = '--' }
    if ($s.GpuModeName) { $n.GpuHeader.Text = 'GPU · RTX 4080 Laptop   ·   显卡模式 ' + $s.GpuModeName }
    # say where the GPU numbers come from: NVML in-process, or the nvidia-smi fallback
    $n.GpuHeader.ToolTip = $(if ($s.GpuSensor -eq 'nvml') { 'GPU 数据来自 nvml.dll（进程内直读，不依赖 nvidia-smi 程序）' }
        elseif ($s.GpuSensor -eq 'smi') { 'GPU 数据来自 nvidia-smi（NVML 不可用时的备用通道）' }
        else { 'GPU 数据不可用' })

    # ---- 内存 ----
    $totMB = [int]$script:Sync.TotalRamMB
    if ($totMB -gt 0 -and $null -ne $s.RamFreeMB) {
        $usedMB = $totMB - [int]$s.RamFreeMB
        $pct = [Math]::Max(0, [Math]::Min(100, [Math]::Round(100.0 * $usedMB / $totMB)))
        $n.MemBar.Width = [Math]::Round($script:BarWidth * $pct / 100)
        # portrait: the long '已用 x / y GB · 可用 z GB' no longer fits on one line, so the
        # row shows the used/total part and keeps the whole sentence in the tooltip
        $n.MemText.Text = '已用 {0:N1} / {1:N1} GB' -f ($usedMB / 1024), ($totMB / 1024)
        $n.MemText.ToolTip = '已用 {0:N1} GB / 共 {1:N1} GB   ·   可用 {2:N1} GB' -f ($usedMB / 1024), ($totMB / 1024), ($s.RamFreeMB / 1024)
        $n.MemPct.Text = '{0}%' -f $pct
        # bar and percentage share one colour code: violet normally, amber >= 75%, orange >= 90%
        $memColor = if ($pct -ge 90) { '#FFE38A6F' } elseif ($pct -ge 75) { '#FFE3C86F' } else { '#FFB98BFF' }
        $n.MemBar.Background = Get-Brush $memColor
        $n.MemPct.Foreground = Get-Brush $memColor
    }
    else { $n.MemBar.Width = 0; $n.MemText.Text = '--'; $n.MemPct.Text = '' }

    # ---- 存储 ----
    $vols = @($s.Volumes)
    for ($i = 0; $i -lt $script:MaxVolumes; $i++) {
        $row = $n["Vol${i}Row"]
        if ($i -lt $vols.Count) {
            $v = $vols[$i]
            $row.Visibility = 'Visible'
            $lbl = if ($v.Label) { "$($v.Name)  $($v.Label)" } else { $v.Name }
            $n["Vol${i}Name"].Text = $lbl
            $n["Vol${i}Name"].ToolTip = $lbl
            $used = $v.Total - $v.Free
            $pct = if ($v.Total -gt 0) { [Math]::Round(100.0 * $used / $v.Total) } else { 0 }
            $n["Vol${i}Bar"].Width = [Math]::Round($script:BarWidth * $pct / 100)
            $barColor = if ($pct -ge 90) { '#FFE38A6F' } elseif ($pct -ge 75) { '#FFE3C86F' } else { '#FF57B0FF' }
            $n["Vol${i}Bar"].Background = Get-Brush $barColor
            # portrait form: '414 / 954 GB'; the sentence with 可用 is the tooltip
            $n["Vol${i}Size"].Text = '{0} / {1}' -f (Format-GB $used), (Format-GB $v.Total)
            $n["Vol${i}Size"].ToolTip = '已用 {0} / {1}   ·   可用 {2}' -f (Format-GB $used), (Format-GB $v.Total), (Format-GB $v.Free)
            $n["Vol${i}Type"].Text = '{0}%' -f $pct
            $n["Vol${i}Type"].Foreground = Get-Brush $barColor
        }
        else { $row.Visibility = 'Collapsed' }
    }
    $pd = @($script:Sync.PhysDisks)
    if ($pd.Count) {
        $n.PhysDiskText.Text = '物理磁盘 {0}: ' -f $pd.Count
        $n.PhysDiskText.Text += (($pd | ForEach-Object { '{0} {1}' -f $_.Model, (Format-GB ($_.GB * 1GB)) }) -join '   ·   ')
    }

    # ---- 一键场景 ----
    # 高亮**从硬件状态反推**，不记"我最后点了哪一档"：场景是四个量的组合，EC 里没有
    # "场景"这个概念，所以唯一的诚实判据是"电源、风扇、键盘灯这三样是否同时等于那一档"。
    # 用户随后手动改了其中一个（比如把电源拨到性能），下一次重画就该熄灭 —— 界面不能
    # 一边显示「安静」一边跑着性能。
    # 亮度不参与比对：读一次亮度要走 WMI，而这一页平时不读它（见 Sync.WantBright），
    # 为了给一个高亮去加一次每 400ms 的 WMI 查询不划算。亮度值仍写在 hint 里。
    $sceneHit = -1
    if ($null -ne $s.PowerMode -and $null -ne $s.FanMode) {
        for ($i = 0; $i -lt $script:ScenePills.Count; $i++) {
            $d = $script:ScenePills[$i]
            $kbOk = ([string]$d.Kb -eq '') -or ([string]$d.Kb -eq [string]$s.LedMode)
            if ([int]$s.PowerMode -eq [int]$d.Power -and [int]$s.FanMode -eq [int]$d.Fan -and $kbOk) { $sceneHit = $i; break }
        }
    }
    for ($i = 0; $i -lt $script:ScenePills.Count; $i++) {
        Set-Pill $n["Scn$i"] $n["Scn${i}T"] ($i -eq $sceneHit) '#FFB98BFF'
    }
    $autoOn = [bool]$script:Settings.SceneAuto
    for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) {
        Set-Pill $n["ScnA$i"] $n["ScnA${i}T"] ([bool]$script:OnOffPills[$i].On -eq $autoOn) '#FFB98BFF'
    }
    if ($sceneHit -ge 0) {
        $n.SceneHint.Text = ('当前「{0}」：{1}' -f $script:ScenePills[$sceneHit].Label, $script:ScenePills[$sceneHit].Tip)
    }
    else {
        $n.SceneHint.Text = '点一下同时改电源、风扇、键盘灯、亮度（自定义曲线不受影响）'
    }
    if ($autoOn) {
        $n.SceneHint.Text += ('   ·   插电→{0}，电池→{1}' -f `
                $script:ScenePills[[int]$script:Sync.SceneOnAc].Label, $script:ScenePills[[int]$script:Sync.SceneOnBat].Label)
    }

    $powerActive = ''
    for ($i = 0; $i -lt $script:PowerPills.Count; $i++) {
        $on = ($null -ne $s.PowerMode -and $s.PowerMode -eq $script:PowerPills[$i].Id)
        if ($on) { $powerActive = $script:PowerPills[$i].Label }
        Set-Pill $n["Pwr$i"] $n["Pwr${i}T"] $on '#FF57B0FF'
    }
    $kbActive = ''
    $kbOffered = $false
    if ($s.LedMode) {
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            if ($script:LedModePills[$i].Key -eq $s.LedMode) { $kbActive = $script:LedModePills[$i].Label; $kbOffered = $true; break }
        }
        # the EC can hold a mode this panel no longer offers (e.g. 波浪 set by the factory
        # app) - name it from the full table rather than leaving the strip blank
        if (-not $kbOffered -and $script:LedModeLabelAll.ContainsKey([string]$s.LedMode)) {
            $kbActive = $script:LedModeLabelAll[[string]$s.LedMode]
        }
    }
    # Sync the keyboard-tab selection with the EC's persisted mode ONCE, on the first
    # snapshot. Without this the pills claimed 静态 while the strip (reading the real
    # AppSettings) said 波浪 - two different answers to the same question on one screen.
    # After the first sync our own clicks drive it; the strip keeps showing EC truth.
    if (-not $script:LedSynced -and $s.LedMode) {
        $found = $false
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            if ($script:LedModePills[$i].Key -eq $s.LedMode) { $script:LedSel.ModeIdx = $i; $script:LedSel.Mode = $s.LedMode; $found = $true; break }
        }
        # EC holds a mode this panel does not offer: light NO pill rather than lighting a
        # wrong one, and remember the real mode so the footer can say so
        if (-not $found) { $script:LedSel.ModeIdx = -1; $script:LedSel.Mode = [string]$s.LedMode }
        if ($s.LedColor) {
            for ($i = 0; $i -lt $script:RgbPills.Count; $i++) {
                $c = $script:RgbPills[$i]
                if ($c.R -eq $s.LedColor[0] -and $c.G -eq $s.LedColor[1] -and $c.B -eq $s.LedColor[2]) { $script:LedSel.Color = $i; break }
            }
        }
        $script:LedSynced = $true
    }

    # ---- 启动时把上次的键盘灯**注入回键盘** --------------------------------------
    # 键盘灯是硬件会忘的东西：断电后灯控芯片里的状态没了，而 EC 的 AppSettings 镜像还在。
    # 面板以前只读镜像**显示**、从不发回键盘，所以每次开机灯都是灭的（用户报的"每次都会重置"）。
    # 取值顺序：settings.json 里你最后调的那套 → EC 镜像那套 → 都不动键盘。
    # 每个进程只做一次；模式必须是面板提供的五个之一（否则没有对应的 UI 状态，宁可不发）。
    # 等 KbReady：键盘灯那一层是采样器在启动时加载的，没加载就发不了（那时先等下一次重画，
    # 别把这个"只做一次"的机会浪费掉 —— 否则键盘会一直是灭的）。
    if (-not $script:LedRestored -and $null -ne $script:Sync.Snapshot) {
        if (-not $script:Sync.KbReady) {
            if (-not $script:LedRestoreWaited) {
                $script:LedRestoreWaited = $true
                Write-Dbg 'LED restore: 键盘灯层还没就绪，等下一次重画再注入'
            }
        }
        elseif (-not (Test-ReqSlotFree)) {
            # 请求槽被占（这一轮重画里已经有请求发出去了，开机时就是下面"风扇曲线写回"那块）：
            # 现在发会被顶掉，而 $script:LedRestored 一旦置位就再也不会重发 —— 见 Test-ReqSlotFree
            # 上面的说明。这里的正确动作是**什么都不做**，等下一轮重画（约 400ms 后）再发。
        }
        else {
            $script:LedRestored = $true
            $offered = @($script:LedModePills | ForEach-Object { $_.Key })
            $mode = ''; $from = ''
            if ($script:Settings.Led -and $script:Settings.Led.Mode) {
                $mode = [string]$script:Settings.Led.Mode
                $from = 'settings.json'
            }
            elseif ($s.LedMode) {
                $mode = [string]$s.LedMode
                $from = 'EC 镜像'
                # EC 镜像只给了模式和一个 RGB（没有色块下标），所以要**反推**用户当时选的是什么。
                # 关键一条：彩虹（多色）不是颜色值，帧里走的是固件自己的调色板（0xA1→0x71），
                # 而镜像里存的 R/G/B 就是当时传的值 —— 选彩虹时那个值是 0/0/0（彩虹色块本身没有 RGB）。
                # 所以：模式支持彩虹 + 镜像颜色是 0/0/0 → 那是"彩虹"，不能当"黑色单色"再发一遍
                # （我第一版就是那样，结果把键盘注入成"波动 + 纯黑"，等于没亮）。
                $pill = $(if ($script:LedSel.ModeIdx -ge 0) { $script:LedModePills[$script:LedSel.ModeIdx] } else { $null })
                $supportsRainbow = ($null -ne $pill -and [bool]$pill.Rainbow)
                $col = $s.LedColor
                $isBlack = ($null -eq $col) -or ([int]$col[0] -eq 0 -and [int]$col[1] -eq 0 -and [int]$col[2] -eq 0)
                if ($supportsRainbow -and $isBlack) {
                    $rainbowIdx = 0
                    for ($i = 0; $i -lt $script:RgbPills.Count; $i++) { if ($script:RgbPills[$i].ContainsKey('Rainbow')) { $rainbowIdx = $i; break } }
                    $script:LedSel.Rainbow = $true
                    $script:LedSel.UseCustom = $false
                    $script:LedSel.Color = $rainbowIdx
                    Write-Dbg 'LED restore: 镜像里是 0/0/0 + 该模式支持彩虹 → 按"彩虹"恢复（固件调色板）'
                }
                else {
                    $script:LedSel.Rainbow = $false
                    if ($col) {
                        Set-LedSelFromConfig @{
                            Mode = $mode; Rainbow = $false; UseCustom = $true
                            R = [int]$col[0]; G = [int]$col[1]; B = [int]$col[2]
                            Bright = $script:LedSel.Bright; Speed = $script:LedSel.Speed; Color = $null
                        }
                    }
                }
                $script:LedConfigSource = 'ec'
            }
            if ($mode -and ($offered -contains $mode)) {
                Write-Dbg ('LED restore: 把上次的键盘灯注入回键盘（来源={0} 模式={1} 亮度={2} 速度={3}）' -f `
                    $from, $mode, $script:LedSel.Bright, $script:LedSel.Speed)
                Request-Led -Startup
            }
            elseif ($mode) { Write-Dbg ('LED restore: EC/配置里的模式 {0} 面板不提供，跳过注入' -f $mode) }
            else { Write-Dbg 'LED restore: 没有任何可注入的键盘灯配置（键盘保持原样）' }
        }
    }
    # ---- 启动时把"我的配置"注入回去：电源模式 / 风扇模式 / 充电窗口 ------------------
    # 用户要求："每次我更改后保存，下次开机时自动注入我上次保存的东西"。
    # 规则：**只注入和 EC 现在不一样的那些**（一样的就不写，免得每次开机都无谓地写 EC）；
    # 每一项都走面板平时的写入通道（带读回校验）。你上次在面板里点的是什么，这里就套什么 ——
    # 所以想留在"自动"，就在面板里点一下「自动」，它就成了你的配置。
    if (-not $script:StartupConfigRestored -and $script:Settings.Saved -and $null -ne $script:Sync.Snapshot) {
        $sv = $script:Settings.Saved
        $did = New-Object System.Collections.ArrayList
        # 一轮重画最多发一个请求（请求槽只有一个）：发完 $slot 就变 $false，剩下的条目下一轮再发
        $slot = Test-ReqSlotFree
        if (-not $script:StartupPowerIssued -and $null -ne $sv.PowerMode -and $null -ne $s.PowerMode) {
            if ([int]$sv.PowerMode -eq [int]$s.PowerMode) { $script:StartupPowerIssued = $true }   # EC 已经是你要的
            elseif ($slot) {
                Write-Dbg ('STARTUP config: 电源模式 EC={0} 你的配置={1} → 按配置写回' -f $s.PowerMode, $sv.PowerMode)
                Request-Write -Mode ([int]$sv.PowerMode) -Kind 'power' -Startup
                $script:StartupPowerIssued = $true
                $slot = $false
                [void]$did.Add(('电源→{0}' -f $sv.PowerMode))
            }
        }
        if (-not $script:StartupFanModeIssued -and $null -ne $sv.FanMode -and $null -ne $s.FanMode) {
            if ([int]$sv.FanMode -eq [int]$s.FanMode) { $script:StartupFanModeIssued = $true }      # EC 已经是你要的
            elseif ($slot) {
                Write-Dbg ('STARTUP config: 风扇模式 EC={0} 你的配置={1} → 按配置写回' -f $s.FanMode, $sv.FanMode)
                Request-Write -Mode ([int]$sv.FanMode) -Kind 'fan' -Startup
                $script:StartupFanModeIssued = $true
                $slot = $false
                [void]$did.Add(('风扇→{0}' -f $sv.FanMode))
            }
        }
        # 充电窗口要读一次 EC 才能比（那份状态平时只在杂项页可见时才读）—— 只点亮一次
        if ($null -ne $sv.ChargerEnabled -and -not $script:StartupMiscWanted) {
            $script:StartupMiscWanted = $true
            $script:Sync.NeedFullMisc = $true
        }
        if ($did.Count) { Write-Dbg ('STARTUP config: 已按你的配置注入 {0}' -f ($did -join '、')) }
        # 两条都定下来（按配置写过 / EC 本来就是你要的）才算这块做完，否则下一轮重画接着做
        $cfgDone = (($script:StartupPowerIssued -or $null -eq $sv.PowerMode) -and
                    ($script:StartupFanModeIssued -or $null -eq $sv.FanMode))
        if ($cfgDone) {
            $script:StartupConfigRestored = $true
            if (-not $did.Count -and $null -eq $sv.ChargerEnabled) { Write-Dbg 'STARTUP config: EC 和你保存的配置一致，无需注入' }
        }
    }
    # 充电窗口：等杂项那次读取回来（WantMisc 是上面为了比较才点亮的），不一致才写
    if (-not $script:StartupChargerChecked -and $script:Settings.Saved -and
        $null -ne $script:Settings.Saved.ChargerEnabled -and
        $null -ne $s.Misc -and $null -ne $s.Misc.ChargerStart -and (Test-ReqSlotFree)) {
        $script:StartupChargerChecked = $true
        $sv = $script:Settings.Saved
        $mi = $s.Misc
        $wantOn = ([int]$sv.ChargerEnabled -ne 0)
        $nowOn = ([int]$mi.ChargerStart -gt 0 -or [int]$mi.ChargerStop -gt 0)
        $same = ($wantOn -eq $nowOn)
        if ($wantOn -and $same) {
            $same = ([int]$mi.ChargerStart -eq [int]$sv.ChargerStart -and [int]$mi.ChargerStop -eq [int]$sv.ChargerStop)
        }
        if (-not $same) {
            Write-Dbg ('STARTUP config: 充电窗口 EC={0}/{1}（启用={2}）你的配置={3}/{4}（启用={5}）→ 按配置写回' -f `
                $mi.ChargerStart, $mi.ChargerStop, $nowOn, $sv.ChargerStart, $sv.ChargerStop, $wantOn)
            Request-Misc -Sub 'charger' -Value ([pscustomobject]@{
                    Mode = $(if ($wantOn) { 'custom' } else { 'max' })
                    Start = [int]$sv.ChargerStart; Stop = [int]$sv.ChargerStop
                }) -Startup
        }
        else { Write-Dbg ('STARTUP config: 充电窗口和你的配置一致（{0}-{1}%），无需注入' -f $mi.ChargerStart, $mi.ChargerStop) }
    }
    # ---- 风扇：三颗按钮，自定义只在 EC 模式 6 时亮 ----
    # The curve presets are gone, so a pill no longer needs to be matched against block 13:
    # 自动 = mode 0, 最大 = mode 1, 自定义 = mode 6 (whatever table is loaded).
    $fanActive = ''
    for ($i = 0; $i -lt $script:FanPills.Count; $i++) {
        $p = $script:FanPills[$i]
        if ($p.ContainsKey('Curve')) {
            $on = ($s.FanMode -eq 6)
            if ($on) { $fanActive = $p.Label; if ([int]$script:LedSel.FanIdx -ne $i) { $script:LedSel.FanIdx = $i } }
        }
        else {
            $on = ($null -ne $s.FanMode -and $s.FanMode -eq [int]$p.Mode)
            if ($on) { $fanActive = $p.Label; if ([int]$script:LedSel.FanIdx -ne $i) { $script:LedSel.FanIdx = $i } }
        }
        Set-Pill $n["Fan$i"] $n["Fan${i}T"] $on '#FF6FE38A'
    }
    # 只有在"用户还没配过自己的曲线"时，才从 EC 的当前表读一次作为编辑器的起点 —— 而且
    # **吸附到 5 的倍数**（EC 里是 60/38、86/59 这种值，界面上点不出来）。
    # 用户配过的话，启动时就已经用他那份了（FanSeeded 早就是 $true）。
    if (-not $script:FanSeeded -and $s.RuntimeT) {
        [void](Set-FanCustomSafe @{
                T2 = [int]$s.RuntimeT[1]
                T3 = [int]$s.RuntimeT[2]
                D2 = [int][Math]::Round(100.0 * $s.RuntimeRaw[1] / 255)
                D3 = [int][Math]::Round(100.0 * $s.RuntimeRaw[2] / 255)
            })
        $script:FanSeeded = $true
        $script:FanCurveSource = 'ec'
        Write-Dbg ('fan curve seeded from EC then snapped to Step {0}: T2={1} D2={2} T3={3} D3={4}' -f `
            $script:FanLimits.Step, $script:FanCustom.T2, $script:FanCustom.D2, $script:FanCustom.T3, $script:FanCustom.D3)
    }

    # 启动时**按"我的配置"来**（用户要求：每次启动照我之前的配置，别读当前那份）。
    # 这一步只做一件事：如果 EC 现在跑的表和你的配置不一样，就把它写回去 —— 但**只在 EC 已经
    # 处于自定义模式（6）时**。你选了自动/最大，就说明你要它自己的逻辑，这时候绝不插手
    # （否则"重启一次风扇又变回自定义"会变成另一种烦人）。每次启动只做一次。
    if (-not $script:FanAppliedOnStart -and $script:FanCurveSource -eq 'settings' -and
        $s.FanMode -eq 6 -and $s.RuntimeT -and (Test-ReqSlotFree)) {
        $script:FanAppliedOnStart = $true
        $same = ($s.RuntimeRaw[1] -eq (Convert-DutyPctToRaw $script:FanCustom.D2) -and
                 $s.RuntimeRaw[2] -eq (Convert-DutyPctToRaw $script:FanCustom.D3) -and
                 [int]$s.RuntimeT[1] -eq [int]$script:FanCustom.T2 -and
                 [int]$s.RuntimeT[2] -eq [int]$script:FanCustom.T3)
        if ($same) { Write-Dbg 'fan curve: EC 正在跑的就是你的配置，启动时无需写入' }
        else {
            Write-Dbg ('fan curve: 启动时按你的配置写回 EC（EC 现在是 {0}°C/{1}% {2}°C/{3}%，你的配置是 {4}°C/{5}% {6}°C/{7}%）' -f `
                $s.RuntimeT[1], $s.RuntimeD[1], $s.RuntimeT[2], $s.RuntimeD[2],
                $script:FanCustom.T2, $script:FanCustom.D2, $script:FanCustom.T3, $script:FanCustom.D3)
            Request-FanCurve -Startup
        }
    }
    # the node editor is only live while the EC is actually running a custom table (mode 6) -
    # greyed out and non-clickable in 自动/最大. Read from the EC, not from the last click:
    # the hardware state is the truth, and the pills are synced from it above.
    $customOn = ($s.FanMode -eq 6)
    $editOpacity = $(if ($customOn) { 1.0 } else { 0.35 })
    foreach ($pre in 'Ct2T', 'Ct2D', 'Ct3T', 'Ct3D') {
        $n["${pre}Minus"].IsEnabled = $customOn
        $n["${pre}Plus"].IsEnabled = $customOn
        $n["${pre}Val"].Opacity = $editOpacity
        $n["${pre}Unit"].Opacity = $editOpacity
    }
    $n.Ct2RowLabel.Opacity = $editOpacity
    $n.Ct3RowLabel.Opacity = $editOpacity

    # ---- 自定义曲线的四个数字 ----
    # number and unit live in separate fixed-width boxes; only the number changes
    $n.Ct2TVal.Text = '{0}' -f $script:FanCustom.T2
    $n.Ct2DVal.Text = '{0}' -f $script:FanCustom.D2
    $n.Ct3TVal.Text = '{0}' -f $script:FanCustom.T3
    $n.Ct3DVal.Text = '{0}' -f $script:FanCustom.D3
    $n.Ct2DUnit.Text = '%'; $n.Ct3DUnit.Text = '%'
    # 说清楚这两行到底是"谁的"曲线：用户自己配的那份（存 settings.json，重启面板也在）还是
    # 从 EC 当前表吸附来的。以前这里没写，用户看到 60/38、86/59 会以为"我配的丢了"。
    # 这两行到底是谁的曲线：用户存的那份（settings.json）还是从 EC 当前表吸附来的。
    # 原来有一块 CustHint 专门讲这件事，本轮为了腾高度把它合并进 PerfProto（同页、同样两行高）。
    $n.PerfProto.Text = '· 节点 1/4 由 EC 固定；这两行' + $(if ($script:FanCurveSource -eq 'settings') {
            '是你保存的曲线（存 settings.json，重启面板也在）'
        }
        else {
            '暂时是 EC 吸附值，按一次加减就存成你的'
        })

    # ---- 显卡 ----
    # No pills (probe failed / EC reports no switchable modes) => hide the whole row rather
    # than offer buttons that cannot work. When a mode has been staged but not rebooted, say
    # so next to the active mode - the two are different things and must not be conflated.
    if ($script:GpuPills.Count -gt 0 -and $null -ne $s.GpuMode) {
        $n.GpuRow.Visibility = 'Visible'
        for ($i = 0; $i -lt $script:GpuPills.Count; $i++) {
            Set-Pill $n["Gpu$i"] $n["Gpu${i}T"] ($s.GpuMode -eq $script:GpuPills[$i].Id) '#FFB98BFF'
        }
        $staged = [int]$s.GpuStaged
        if ($staged -gt 0 -and $staged -ne $s.GpuMode -and $script:GpuModeName.ContainsKey($staged)) {
            $n.GpuNow.Text = '当前 {0}   ·   已暂存 {1}，重启生效' -f $s.GpuModeName, $script:GpuModeName[$staged]
            $n.GpuNow.Foreground = Get-Brush '#FFE3C86F'
            # 有暂存就顺手给一个「立即重启」的入口：重启申请弹窗关掉之后（或者用户当时选了
            # "稍后"），想马上重启还能在这儿点一下，不必去开始菜单找。
            $n.GpuRebootBtn.Visibility = 'Visible'
        }
        else {
            $n.GpuNow.Text = '当前 {0}' -f $s.GpuModeName
            $n.GpuNow.Foreground = Get-Brush '#FF98A1B3'
            $n.GpuRebootBtn.Visibility = 'Collapsed'
        }
    }
    else { $n.GpuRow.Visibility = 'Collapsed'; $n.GpuRebootBtn.Visibility = 'Collapsed' }

    # ---- 标签页 ----
    # 七个页面，盒子尺寸相同：概览住在 StatePanel，其余六个共用 ControlPanel（高/内边距/外边距
    # 完全一致），所以切页签时窗口不会变大小。
    $tab = [string]$script:LedSel.Tab
    $n.TabState.Visibility = $(if ($tab -eq 'state') { 'Visible' } else { 'Collapsed' })
    $n.StatePanel.Visibility = $(if ($tab -eq 'state') { 'Visible' } else { 'Collapsed' })
    $n.TabPerf.Visibility = $(if ($tab -eq 'perf') { 'Visible' } else { 'Collapsed' })
    $n.TabKb.Visibility = $(if ($tab -eq 'kb') { 'Visible' } else { 'Collapsed' })
    $n.TabBatt.Visibility = $(if ($tab -eq 'batt') { 'Visible' } else { 'Collapsed' })
    $n.TabMisc.Visibility = $(if ($tab -eq 'misc') { 'Visible' } else { 'Collapsed' })
    $n.TabSys.Visibility = $(if ($tab -eq 'sys') { 'Visible' } else { 'Collapsed' })
    $n.TabAbout.Visibility = $(if ($tab -eq 'about') { 'Visible' } else { 'Collapsed' })
    $n.ControlPanel.Visibility = $(if ($tab -eq 'state') { 'Collapsed' } else { 'Visible' })
    Set-Pill $n.TabBtnState $n.TabBtnStateT ($tab -eq 'state') '#FFB98BFF'
    Set-Pill $n.TabBtnPerf $n.TabBtnPerfT ($tab -eq 'perf') '#FFB98BFF'
    Set-Pill $n.TabBtnKb $n.TabBtnKbT ($tab -eq 'kb') '#FFB98BFF'
    Set-Pill $n.TabBtnBatt $n.TabBtnBattT ($tab -eq 'batt') '#FFB98BFF'
    Set-Pill $n.TabBtnMisc $n.TabBtnMiscT ($tab -eq 'misc') '#FFB98BFF'
    Set-Pill $n.TabBtnSys $n.TabBtnSysT ($tab -eq 'sys') '#FFB98BFF'
    Set-Pill $n.TabBtnAbout $n.TabBtnAboutT ($tab -eq 'about') '#FFB98BFF'
    # the sampler only reads the 杂项通道 while 设备/电池 页在看
    # （启动时若还欠一次完整杂项读 —— 为了跟"我的配置"比充电窗口 —— 就一直要点着它，
    #   读完那次由采样器把 NeedFullMisc 清掉，见采样器里那行）
    $script:Sync.WantMisc = ($tab -eq 'misc' -or $tab -eq 'batt') -or [bool]$script:Sync.NeedFullMisc
    # 状态页只要一个亮度值（滑杆在那里），所以单独给它一路轻量读取：没必要为了一个数字
    # 把触控板/电池/充电器都拉一遍，那会把采样周期拖慢。
    $script:Sync.WantBright = ($tab -eq 'state')
    # DCHU 通道坏了 → 托盘里的"修复 DCHU 驱动…"亮起来（正常时灰着，不干扰）
    if ($script:TrayFixItem) {
        try { $script:TrayFixItem.Enabled = [bool]$s.Err } catch { }
    }
    for ($i = 0; $i -lt $script:AutostartPills.Count; $i++) {
        # read the real state instead of a cached flag: the exe can toggle it from the CLI
        # while the panel is open, and a stale pill would be a lie
        Set-Pill $n["Auto$i"] $n["Auto${i}T"] ([bool]$script:AutostartPills[$i].On -eq (Get-AutostartState)) '#FF6FE38A'
    }

    # ---- 标题栏温度 ----
    # 原来这里有两条常显信息（传感器一行、当前档位一行），每个页面顶部都占一条。用户直接问了
    # 「为什么每个页面上都要有概览这一栏」—— 因为概览页本来就把同样的数字放大显示了一遍。
    # 现在只留最该随时看见的一个数：CPU / GPU 温度，放进标题栏；档位信息搬去性能页的
    # 「当前生效」卡（就在它上面那些按钮旁边，比放在标题下面更符合"点了有没有生效"的疑问）。
    $n.TitleTemps.Text = 'CPU {0}° · GPU {1}°' -f `
        $(if ($null -ne $s.CpuTemp) { [int]$s.CpuTemp } else { '--' }),
        $(if ($null -ne $s.GpuTemp) { [int]$s.GpuTemp } else { '--' })

    if ($tab -eq 'kb') {
        $sel = $script:LedSel
        for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
            Set-Pill $n["Led$i"] $n["Led${i}T"] ($i -eq [int]$sel.ModeIdx) '#FFB98BFF'
        }
        for ($i = 0; $i -lt $script:RgbBrightness.Count; $i++) {
            Set-Pill $n["RgbB$i"] $n["RgbB${i}T"] ($i -eq [int]$sel.Bright) '#FFB98BFF'
        }
        for ($i = 0; $i -lt $script:LedSpeedPills.Count; $i++) {
            Set-Pill $n["Spd$i"] $n["Spd${i}T"] ($i -eq [int]$sel.Speed) '#FFB98BFF'
        }
        # ---- colour row: ALWAYS visible ----
        # 以前按模式隐藏（关闭/循环 时不显示）。用户把灯设成「关闭」以后再进这一页，
        # 颜色和色盘整块不见了 —— 读起来就是"颜色选择没了"，而不是"这个模式不用颜色"。
        # 现在可见性和可用性分开：行一直在，只是当前模式用不到时变暗 + 说明原因，
        # 点色块/色盘仍然会记住选择（切到 静态/波/呼吸 立刻生效），但不会白发一次写入。
        # ModeIdx = -1 表示"EC 里是一个本面板不提供的模式"，此时按第一个模式（关闭）的
        # 属性来呈现，和上面 pill 全不亮是同一个道理。
        $mi = [int]$sel.ModeIdx
        $mp = $(if ($mi -ge 0 -and $mi -lt $script:LedModePills.Count) { $script:LedModePills[$mi] } else { $script:LedModePills[0] })
        $nColors = [int]$mp.Colors
        $colourUsable = ($nColors -ge 1)
        $n.LedColorRow.Visibility = 'Visible'
        $dim = $(if ($colourUsable) { 1.0 } else { 0.45 })
        $n.LedColorRow.Opacity = $dim
        $n.ColorWheelBox.Opacity = $dim
        # swatch rings: 彩虹 is a choice of its own, so it lights up instead of a colour
        $rainbowIdx = -1
        for ($i = 0; $i -lt $script:RgbPills.Count; $i++) {
            if ($script:RgbPills[$i].ContainsKey('Rainbow')) { $rainbowIdx = $i; continue }
            $sel1 = (-not $sel.Rainbow) -and ($i -eq [int]$sel.Color)
            $n["Rgb$i"].BorderThickness = $(if ($sel1) { 2 } else { 0 })
            $n["Rgb$i"].BorderBrush = Get-Brush '#FFEDF0F5'
        }
        if ($rainbowIdx -ge 0) {
            $n["Rgb$rainbowIdx"].BorderThickness = $(if ($sel.Rainbow) { 2 } else { 0 })
            $n["Rgb$rainbowIdx"].BorderBrush = Get-Brush '#FFEDF0F5'
            # 彩虹 is meaningless where the firmware has no multi-colour variant
            $n["Rgb$rainbowIdx"].Opacity = $(if ($mp.Rainbow) { 1.0 } else { 0.25 })
        }
        $c = $script:RgbPills[[int]$sel.Color]
        $n.LedColorHint.Text = $(if (-not $colourUsable) { '「{0}」不用颜色；选了会记住，切到 静态/波/呼吸 生效' -f $mp.Label }
            elseif ($sel.Rainbow -and $sel.Mode -eq 'static') { '彩虹：整键盘重绘（约 0.3 秒）' }
            elseif ($sel.Rainbow) { '彩虹：交给固件自己配色' }
            elseif ($sel.UseCustom) { '色盘自定义颜色' }
            elseif ($sel.Mode -eq 'static') { '整键盘重绘（约 0.3 秒）' }
            else { '当前 {0}' -f $c.Label })

        # ---- 方向行：只有「波」用得到（帧里 d0 = 0xA1/0x71 + 方向）----
        $dirMode = ($sel.Mode -eq 'wave')
        # 方向行改常显：用户反馈"有些东西没有显示出来"。不隐藏、只在模式用不到它时变暗，
        # 这样用户知道这项存在；能用到时（波动/循环）才是亮的、可点的。
        $n.LedDirRow.Opacity = $(if ($dirMode) { 1.0 } else { 0.45 })
        $n.LedDirHint.Text = $(if ($dirMode) { '色带滚过方向' } else { '（当前模式不用方向）' })
        if ($dirMode) {
            for ($i = 0; $i -lt $script:LedDirPills.Count; $i++) {
                Set-Pill $n["Dir$i"] $n["Dir${i}T"] ([int]$script:LedDirPills[$i].Idx -eq [int]$sel.Dir) '#FFB98BFF'
            }
        }

        # ---- 色盘：和颜色行一样始终显示（不可用时只是变暗，见上）----
        $n.ColorWheelBox.Visibility = 'Visible'
        if ($true) {
            # marker position comes from the stored hue/sat, so it does not drift on repaint
            if ($sel.UseCustom -and $null -ne $script:WheelHue) {
                $rad = [double]$script:WheelHue * [Math]::PI / 180.0
                $r0 = $script:WheelSize / 2.0
                $sat = [double]$script:WheelSat / 100.0
                $mx = $r0 + [Math]::Cos($rad) * $sat * $r0
                $my = $r0 + [Math]::Sin($rad) * $sat * $r0
                [System.Windows.Controls.Canvas]::SetLeft($n.WheelMark, $mx - 7)
                [System.Windows.Controls.Canvas]::SetTop($n.WheelMark, $my - 7)
                $n.WheelMark.Visibility = 'Visible'
            }
            else { $n.WheelMark.Visibility = 'Collapsed' }
            if ($sel.UseCustom) { $cr = [int]$sel.Custom.R; $cg = [int]$sel.Custom.G; $cb = [int]$sel.Custom.B }
            else { $cr = [int]$c.R; $cg = [int]$c.G; $cb = [int]$c.B }
            $n.WheelPick.Background = Get-Brush ('#FF{0:X2}{1:X2}{2:X2}' -f $cr, $cg, $cb)
            $n.WheelText.Text = '#{0:X2}{1:X2}{2:X2}' -f $cr, $cg, $cb
            $n.WheelText2.Text = 'R{0,3} G{1,3} B{2,3}' -f $cr, $cg, $cb
            if ($sel.UseCustom -and $null -ne $script:WheelHue) {
                $n.WheelHint.Text = '色相 {0}° · 饱和 {1}%' -f [int]$script:WheelHue, [int]$script:WheelSat
            }
            else { $n.WheelHint.Text = '点/拖色盘取任意纯色，立即生效' }
        }
        $n.KbHint.Text = $(if (-not $kbOffered -and $kbActive) {
                'EC 里当前是「{0}」，本面板不提供该模式；点上面任意模式即可覆盖。' -f $kbActive
            } else { '' }) + $script:KbHintBase
    }

    if ($tab -eq 'sys') {
        # 信息行的值全部来自真实来源：EXE 的构建时间取自 EXE 自己的时间戳，路径取自本次运行
        # 的实际位置，DCHU 通道状态取自 dchu.ps1 真的选中的那个 DLL。没有"写死的简介"。
        $exePath = $(if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) { $script:HostExe }
                     else { Join-Path $PSScriptRoot 'ClevoHelper.ps1' })
        $built = '--'
        try { $built = (Get-Item -LiteralPath $exePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } catch { }
        $portable = [bool]($script:HostExe -and (Test-Path -LiteralPath $script:HostExe))
        # 长路径只显示尾部几段（用户反馈"看起来较宽"），完整值在 tooltip 里 —— 显示的是真的，
        # 只是不把一整行都塞满
        $short = {
            param([string]$v, [int]$max = 44)
            if ($v.Length -le $max) { return $v }
            $parts = $v -split '\\'
            $out = $parts[-1]
            for ($i = $parts.Count - 2; $i -ge 0; $i--) {
                $try = $parts[$i] + '\' + $out
                if ($try.Length + 2 -gt $max) { break }
                $out = $try
            }
            return '…\' + $out
        }
        $vals = [ordered]@{
            Version   = 'v' + $script:AppVersion
            Built     = $built
            Mode      = $(if ($portable) { '单文件 EXE（自包含）' } else { '脚本运行（开发模式）' })
            ExePath   = (& $short $exePath)
            DataDir   = (& $short (Split-Path $script:LogPath -Parent))
            Model     = [string]$script:SysInfo.Model
            Serial    = [string]$script:SysInfo.Serial
            Bios      = [string]$script:SysInfo.Bios
            Windows   = [string]$script:SysInfo.Windows
        }
        # tooltip 永远是完整值
        $full = [ordered]@{
            ExePath = $exePath
            DataDir = (Split-Path $script:LogPath -Parent)
        }
        if ($n.AboutChannelWarn) { $n.AboutChannelWarn.Visibility = $(if ($s.Err) { 'Visible' } else { 'Collapsed' }) }
        # 机型守卫：拦下写入时，关于页必须说清"为什么点按钮没反应"。
        # 平时不显示（本机是 X370SN，永远不显示），只有判定不通过或走了逃生门才出现。
        if ($n.AboutGuardWarn) {
            $gw = $script:Sync.GuardWarn
            $n.AboutGuardWarn.Visibility = $(if ($gw) { 'Visible' } else { 'Collapsed' })
            if ($gw) { $n.AboutGuardWarn.Text = $gw }
        }
        foreach ($k in $vals.Keys) {
            # 硬件身份行（机型/序列号/BIOS/系统）现在画在设备页，名字前缀是 Dev_。
            $tb = $n[('About_' + $k)]
            if (-not $tb) { $tb = $n[('Dev_' + $k)] }
            if ($tb) {
                $tb.Text = [string]$vals[$k]
                $tb.ToolTip = $(if ($full.Contains($k)) { [string]$full[$k] } else { [string]$vals[$k] })
            }
        }

        # 运行记录：四个只读值，当场算完就写，不进采样通道。
        if ($n.RunUp) {
            $up = $(if ($script:PanelStartAt) { (Get-Date) - $script:PanelStartAt } else { [TimeSpan]::Zero })
            $n.RunUp.Text = $(if ($up.TotalHours -ge 1) {
                    '{0} 小时 {1} 分' -f [int]$up.TotalHours, $up.Minutes
                } elseif ($up.TotalMinutes -ge 1) {
                    '{0} 分 {1} 秒' -f [int]$up.TotalMinutes, $up.Seconds
                } else { '{0} 秒' -f [int]$up.TotalSeconds })
            $n.RunFreq.Text = '每 1 秒 · 重画每 400 毫秒'
            $n.RunLogSize.Text = $(if (Test-Path -LiteralPath $script:LogPath) {
                    '{0:N0} KB' -f ((Get-Item -LiteralPath $script:LogPath).Length / 1KB)
                } else { '—' })
            $n.RunLogPath.Text = & $short $script:LogPath
            $n.RunLogPath.ToolTip = $script:LogPath
        }
    }

    if ($tab -eq 'batt') {
        # 电池页（从原「杂项」拆出来的）：电池条 + 原厂充电三选一 + 自定义阈值窗口。
        # 每一行显示的都是读回值，不是刚才点的那个——这一页的意义就在于硬件说什么。
        $mi = $s.Misc
        $sel = $script:MiscSel

        # ---- 电池状态（系统读数，让充电限制的效果就在旁边）----
        $bt = $(if ($null -ne $mi) { $mi.Battery } else { $null })
        if ($null -ne $bt -and $bt.Supported) {
            $n.BattBar.Width = [Math]::Round(160 * [int]$bt.Percent / 100)
            $bc = if ([int]$bt.Percent -ge 90) { '#FF6FE38A' } elseif ([int]$bt.Percent -ge 30) { '#FF57B0FF' } else { '#FFE38A6F' }
            $n.BattBar.Background = Get-Brush $bc
            $n.BattText.Text = '{0,3}%   {1}' -f [int]$bt.Percent, $(if ($bt.OnAc) { '已接电源' } else { '电池供电' })
        }
        else { $n.BattBar.Width = 0; $n.BattText.Text = '--' }

        # ---- 电池充电 ----
        # The EC's own three states map onto the three pills: 不限制 = 最大电量,
        # 70/80 = 推荐（原厂值）, anything else = 自定义.
        # 优先级：用户刚点开自定义（CustomOpen）> 有写入在飞 > EC 的当前状态。
        # 少了第一档就会出现"点自定义 → 这一行一闪就被收回去"（因为 EC 此刻还是 70/80 =
        # 推荐，下一次重画就按推荐把行收起来）。
        $chgSel = ''
        if ($null -ne $mi) {
            $sel.Start = [int]$mi.ChargerStart
            $sel.Stop = [int]$mi.ChargerStop
            if ($sel.CustomOpen) { $chgSel = 'custom' }
            elseif ($script:Sync.Pending -and $script:Sync.Pending.Kind -eq 'misc') { $chgSel = [string]$sel.Charger }
            elseif (-not $mi.ChargerEnabled) { $chgSel = 'max' }
            elseif ($mi.ChargerStart -eq $script:ChargerRecommended.Start -and $mi.ChargerStop -eq $script:ChargerRecommended.Stop) { $chgSel = 'rec' }
            else { $chgSel = 'custom' }
            $sel.Charger = $chgSel
        }
        for ($i = 0; $i -lt $script:ChargerPills.Count; $i++) {
            Set-Pill $n["Chg$i"] $n["Chg${i}T"] ($script:ChargerPills[$i].Key -eq $chgSel) '#FF57B0FF'
        }
        if ($null -ne $mi) {
            $n.ChargerHint.Text = $(if ($mi.ChargerEnabled) { 'EC：{0}% 起 / {1}% 停' -f $mi.ChargerStart, $mi.ChargerStop }
                else { 'EC：不限制（充满 100%）' })
            if ($chgSel -ne 'custom') { $n.ChargerHint.Text += '   ·   点「自定义」可改阈值' }
        }
        # 自定义阈值行：**常驻**，但只有自定义档可选中。不可选时整体变暗 + 不接受点击
        # （和风扇节点行同一套做法：非自定义模式下就是"看得见、点不动"）。
        $editable = ($chgSel -eq 'custom')
        $n.ChgStartLabel.Opacity = $(if ($editable) { 1.0 } else { 0.35 })
        $n.ChgStopLabel.Opacity = $(if ($editable) { 1.0 } else { 0.35 })
        for ($i = 0; $i -lt $script:ChargerStartPills.Count; $i++) {
            $v = [int]$script:ChargerStartPills[$i].Id
            # 可点 = 在自定义档 且 组合合法（起始 < 停止）
            $clickable = $editable -and (($null -eq $mi) -or ($v -lt [int]$sel.Stop))
            Set-Pill $n["ChgS$i"] $n["ChgS${i}T"] ($v -eq [int]$sel.Start) '#FF57B0FF'
            $n["ChgS$i"].Opacity = $(if ($clickable) { 1.0 } else { 0.3 })
            $n["ChgS$i"].IsHitTestVisible = $clickable
        }
        for ($i = 0; $i -lt $script:ChargerStopPills.Count; $i++) {
            $v = [int]$script:ChargerStopPills[$i].Id
            $clickable = $editable -and (($null -eq $mi) -or ($v -gt [int]$sel.Start))
            Set-Pill $n["ChgE$i"] $n["ChgE${i}T"] ($v -eq [int]$sel.Stop) '#FF57B0FF'
            $n["ChgE$i"].Opacity = $(if ($clickable) { 1.0 } else { 0.3 })
            $n["ChgE$i"].IsHitTestVisible = $clickable
        }

        # ---- 电池健康（启动时读一次；读不到就显示「—」，不编数字）----
        $bh = $script:BattHealth
        if ($bh -and $bh.Supported) {
            $n.BhDesign.Text = ('{0:N1} Wh' -f ($bh.Design / 1000.0))
            $n.BhFull.Text = $(if ($bh.Full) { '{0:N1} Wh' -f ($bh.Full / 1000.0) } else { '—' })
            $n.BhHealth.Text = $(if ($bh.Health) { '{0:N1}%' -f $bh.Health } else { '—' })
            # 这台机器的 ManufactureDate 被 BIOS 遮蔽（实测返回 **************.**********），
            # 循环次数又恒为 0，所以这一格改显示「损耗」= 100 - 健康度：两个数都是实测的。
            $n.BhCycles.Text = $(if ($bh.Health) { '{0:N1}%' -f (100.0 - [double]$bh.Health) } else { '—' })
            $n.BhMfr.Text  = $(if ($bh.Mfr)  { [string]$bh.Mfr }  else { '—' })
            $n.BhDev.Text  = $(if ($bh.Dev)  { [string]$bh.Dev }  else { '—' })
            $n.BhChem.Text = $(if ($bh.Chem) { [string]$bh.Chem } else { '—' })
            # 预计可用：Win32_Battery.EstimatedRunTime 单位分钟；接电源时是 71582788（无效值）→ 显示"接电源"。
            $runMin = 0
            try {
                $wb = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($wb -and $wb.EstimatedRunTime -and [int]$wb.EstimatedRunTime -lt 100000) { $runMin = [int]$wb.EstimatedRunTime }
            } catch { }
            $n.BhLeft.Text = $(if ($runMin -gt 0) { $(if ($runMin -ge 60) { '{0} 小时 {1} 分' -f [int]($runMin / 60), ($runMin % 60) } else { '{0} 分钟' -f $runMin }) } else { '接电源' })
            $n.BhNow.Text = $(if ($bh.Now) { '{0:N1} Wh' -f ($bh.Now / 1000.0) } else { '—' })
            $n.BhVolt.Text = $(if ($bh.VoltMv) { '{0:N2} V' -f ($bh.VoltMv / 1000.0) } else { '—' })
            # 充放功率：接电源时看充电功率，电池供电时看放电功率；两者都是 0 就显示 0.0 W（真的静置）。
            $rateMw = $(if ($null -ne $bh.ChargeMw -and [int]$bh.ChargeMw -gt 0) { [int]$bh.ChargeMw }
                        elseif ($null -ne $bh.DischargeMw -and [int]$bh.DischargeMw -gt 0) { -[int]$bh.DischargeMw }
                        else { 0 })
            # 放电写成「放电 48.8 W」而不写「-48.8 W」：负号在界面上会被读成"是不是接反了"。
            if ($null -ne $bh.ChargeMw -or $null -ne $bh.DischargeMw) {
                $n.BhRate.Text = $(if ($rateMw -gt 0) { '充电 {0:N1} W' -f ($rateMw / 1000.0) }
                                  elseif ($rateMw -lt 0) { '放电 {0:N1} W' -f ([Math]::Abs($rateMw) / 1000.0) }
                                  else { '0.0 W' })
            }
            else { $n.BhRate.Text = '—' }
            # 温度字段是十分之一开尔文（2982 = 25.05 ℃）；0 表示不报。
            $n.BhTemp.Text = $(if ($bh.TempK10 -and [int]$bh.TempK10 -gt 1000) { '{0:N1} ℃' -f ([int]$bh.TempK10 / 10.0 - 273.15) } else { '—' })

        }
        else {
            foreach ($k in 'BhHealth', 'BhCycles', 'BhDesign', 'BhFull', 'BhNow', 'BhVolt', 'BhRate', 'BhTemp', 'BhMfr', 'BhDev', 'BhChem', 'BhLeft') { $n[$k].Text = '—' }
        }
        # ---- 保养建议（刻意放在健康度判断之外：读不到健康度也要给建议）----
        # 每条都由当前读数或设置推出来，没有写死的文案；电池状态变量是 $bt（= $mi.Battery）。
        $advLines = @()
        $pct = $(if ($bt -and $bt.Supported) { [int]$bt.Percent } else { -1 })
        $online = [bool]($bt -and $bt.OnAc)
        $hp = $(if ($bh -and $bh.Health) { [double]$bh.Health } else { 0 })
        if ($hp -and $hp -lt 80) { $advLines += ('健康度只有 {0:N1}%，续航会明显缩水，可以考虑换电池' -f $hp) }
        if ($mi -and $mi.ChargerEnabled -and [int]$mi.ChargerStop -ge 95) {
            $advLines += ('充电上限现在是 {0}%，长期插电建议降到 70-80%' -f [int]$mi.ChargerStop)
        }
        if ($online -and $pct -ge 90) {
            $advLines += ('当前已充到 {0}%，满电长时间插着会加速老化；插电为主就把上限设低一点' -f $pct)
        }
        if (-not $online -and $pct -ge 0 -and $pct -le 20) {
            $advLines += ('电量只剩 {0}%，该插电了（省电模式会把独显程序关掉）' -f $pct)
        }
        if ($online -and $pct -ge 0 -and $pct -lt 90 -and $mi -and $mi.ChargerEnabled) {
            $advLines += ('现在 {0}%，上限 {1}%：到这个点就停充，属于正常，不用管' -f $pct, [int]$mi.ChargerStop)
        }
        if ($bh -and -not $bh.Cycles) { $advLines += '本机不报循环次数，寿命只能按容量比（满充/设计）判断' }
        if ($advLines.Count -eq 0) { $advLines += '没有发现需要提醒的地方' }
        $n.BattAdvice.Text = (($advLines | ForEach-Object { '· ' + $_ }) -join [Environment]::NewLine)
    }

    if ($tab -eq 'misc') {
        # 设备页（原「杂项」剩下的部分）：五个开关，显示的都是读回值。
        $mi = $s.Misc

        # ---- 五个开关：显示的是读回值 ----
        $switchState = @{
            Tp = $(if ($null -ne $mi) { $mi.TouchPad } else { $null })
            Wk = $(if ($null -ne $mi) { $mi.WinKey } else { $null })
            Fl = $(if ($null -ne $mi) { $mi.FnLock } else { $null })
            Ws = $(if ($null -ne $mi) { $mi.WinFnSwap } else { $null })
            Nl = $(if ($null -ne $mi) { $mi.NumLock } else { $null })
        }
        $switchPills = @{ Tp = $script:OnOffPills; Wk = $script:EnablePills; Fl = $script:OnOffPills; Ws = $script:SwapPills; Nl = $script:OnOffPills }
        foreach ($pre in 'Tp', 'Wk', 'Fl', 'Ws', 'Nl') {
            $cur = $switchState[$pre]
            for ($i = 0; $i -lt $switchPills[$pre].Count; $i++) {
                $want = [bool]$switchPills[$pre][$i].On
                $on = ($null -ne $cur) -and ([bool]$cur -eq $want)
                Set-Pill $n["$pre$i"] $n["${pre}${i}T"] $on '#FF6FE38A'
                # unknown state (no read yet) must not look like "off"
                $n["$pre$i"].Opacity = $(if ($null -eq $cur) { 0.4 } else { 1.0 })
            }
        }
        # ---- 输入设备（启动时读一次，值不会变）----
        $n.DevKb.Text = [string]$script:InputInfo.Keyboard
        $n.DevTp.Text = [string]$script:InputInfo.Touchpad
        $n.Dev_Cpu.Text = $(if ($script:SysInfo.Cpu) { [string]$script:SysInfo.Cpu } else { '--' })
        $n.Dev_Ram.Text = $(if ($script:SysInfo.RamGB -gt 0) { '{0:N0} GB' -f $script:SysInfo.RamGB } else { '--' })
        # 硬件身份（设备页）：这四行启动时查过一次（$script:SysInfo），这里只做格式化，
        # 不再每次重画都去问 CIM —— 序列号和 BIOS 版本运行期不会变。
        if ($n.Dev_Model) {
            $n.Dev_Model.Text = [string]$script:SysInfo.Model
            $n.Dev_Serial.Text = [string]$script:SysInfo.Serial
            $n.Dev_Bios.Text = [string]$script:SysInfo.Bios
            $n.Dev_Windows.Text = [string]$script:SysInfo.Windows
        }

        # 启动收进托盘那两颗药丸搬到了系统页（见下面 sys 块）：它读的是设置文件，
        # 不是 EC，和这五个硬件开关不是一回事。
    }

    if ($tab -eq 'sys') {
        for ($i = 0; $i -lt $script:OnOffPills.Count; $i++) {
            Set-Pill $n["Tray$i"] $n["Tray${i}T"] ([bool]$script:OnOffPills[$i].On -eq [bool]$script:Settings.StartToTray) '#FF6FE38A'
        }
    }

    # ---- 屏幕亮度（滑杆在状态页）----
    # 这一块必须**在 misc 那个 if 之外**：它服务的是状态页。第一版手滑放进了 misc 块里面，
    # 结果状态页的滑杆永远拿不到值（只有切到杂项页才会被赋值）—— 是日志里
    # "没有 bright paint 这一行"暴露出来的。
    # 拖动中、或有亮度写入在飞时**不碰滑块**：读回值天生比手慢半拍，用它去纠正滑块会把
    # 滑块拽回去，看起来就是"一卡一卡"。松手并写入完成后，这里再按读回值对齐。
    if ($tab -eq 'state') {
        $pendingBright = ($null -ne $script:Sync.Pending -and $script:Sync.Pending.Kind -eq 'misc' -and $script:Sync.Pending.Sub -eq 'bright')
        $brightNow = $(if ($s.Misc) { $s.Misc.Bright } else { $null })
        if ($null -ne $brightNow) {
            if (-not $script:BrightDragging -and -not $pendingBright) {
                # 差 1 以内不纠正：驱动自己会取整，反复纠正就是白白多写几次。
                # 赋值期间用 BrightSyncing 压住 ValueChanged，否则"同步读回值"这件事本身
                # 会触发一次写入（每次切到状态页都白发一次）。
                if ([Math]::Abs([int][Math]::Round($n.BrightSlider.Value) - [int]$brightNow) -gt 1) {
                    $script:BrightSyncing = $true
                    try { $n.BrightSlider.Value = [int]$brightNow }
                    finally { $script:BrightSyncing = $false }
                }
                $n.BrightVal.Text = '{0}%' -f $brightNow
            }
        }
        elseif (-not $script:BrightDragging) { $n.BrightVal.Text = '--%' }
    }

    if ($s.CurveHealth -eq 'ok') {
        # a positive offset is normal (the EC controls on a higher internal temperature than
        # the one this panel reads), so it is reported as "生效中", not as an error
        if ($s.CurveErr -gt 12) {
            $n.CurveHealth.Text = '曲线生效中（实测比表高 {0:N0}%）' -f $s.CurveErr
        }
        else {
            $n.CurveHealth.Text = '曲线正常（偏差 {0:N1}%）' -f $s.CurveErr
        }
        $n.CurveHealth.Foreground = Get-Brush '#FF6FE38A'
    }
    elseif ($s.CurveHealth -eq 'bad') {
        $n.CurveHealth.Text = '⚠ 实测比表低 {0:N0}%，可能欠冷，建议先重启' -f [Math]::Abs($s.CurveErr)
        $n.CurveHealth.Foreground = Get-Brush '#FFE38A6F'
    }
    elseif ($s.CurveHealth -eq 'measuring') {
        $n.CurveHealth.Text = '健康检查采样中…'
        $n.CurveHealth.Foreground = Get-Brush '#FF98A1B3'
    }
    else {
        $n.CurveHealth.Text = '自动/最大 模式不校验曲线'
        $n.CurveHealth.Foreground = Get-Brush '#FF98A1B3'
    }
    # The block below shows the table the EC is executing RIGHT NOW (block 13). This is the
    # only honest answer to "did the curve write actually take effect?" - it replaced a line
    # that showed the persisted factory table, i.e. something that is not what the fans do.
    # Four rows instead of one long line: the data was always four nodes, and in the portrait
    # window the one-line form ran off the edge while leaving the page half empty.
    if ($s.RuntimeT -and @($s.RuntimeRaw).Count -ge 3) {
        # does the running table equal the current 自定义 values?
        $matchCustom = ($s.RuntimeRaw[1] -eq (Convert-DutyPctToRaw $script:FanCustom.D2) -and
                        $s.RuntimeRaw[2] -eq (Convert-DutyPctToRaw $script:FanCustom.D3) -and
                        [int]$s.RuntimeT[1] -eq [int]$script:FanCustom.T2 -and
                        [int]$s.RuntimeT[2] -eq [int]$script:FanCustom.T3)
        $srcs = @('EC 固定', $(if ($matchCustom -or $s.FanMode -eq 6) { '本面板曲线' } else { 'EC/其它' }),
                       $(if ($matchCustom -or $s.FanMode -eq 6) { '本面板曲线' } else { 'EC/其它' }), 'EC 固定')
        $lines = @('EC 正在执行的 4 节点表')
        for ($i = 0; $i -lt 4; $i++) {
            $lines += ('节点{0}  {1,3}°C  {2,3}%   {3}' -f ($i + 1), $s.RuntimeT[$i], $s.RuntimeD[$i], $srcs[$i])
        }
        $lines += $(if ($s.FanMode -ne 6) { '（当前是自动/最大，EC 用自己的表）' }
                    elseif ($matchCustom) { '（与上面两个自定义节点一致）' }
                    else { '（与当前自定义值不一致：是别处写的表）' })
    }

    $lw = $script:Sync.LastWrite
    if ($lw) {
        $n.StatusText.Text = $lw.Msg
        if ($lw.Ok) { $n.StatusText.Foreground = Get-Brush '#FF6FE38A' } else { $n.StatusText.Foreground = Get-Brush '#FFE38A6F' }
    }
    elseif ($s.Err) { $n.StatusText.Text = $s.Err; $n.StatusText.Foreground = Get-Brush '#FFE38A6F' }
    else {
        $n.StatusText.Text = 'InsydeDCHU → AcpiBridge (ACPI\CLV0001)   ·   每次写入均读回校验'
        $n.StatusText.Foreground = Get-Brush '#FF98A1B3'
    }
  }
  catch { Write-Dbg ('PAINT-ERR ' + $_.Exception.ToString()) }
  finally {
    $paintSw.Stop()
    $ms = $paintSw.Elapsed.TotalMilliseconds
    if ($ms -gt 50) {
        $age = '--'
        if ($null -ne $script:Sync.Snapshot -and $script:Sync.Snapshot.At) {
            $age = '{0:N2}s' -f ((Get-Date) - $script:Sync.Snapshot.At).TotalSeconds
        }
        Write-Dbg ('PAINT-SLOW {0:N0}ms（快照年龄 {1}，标签页 {2}）' -f $ms, $age, $script:LedSel.Tab)
    }
  }
}
