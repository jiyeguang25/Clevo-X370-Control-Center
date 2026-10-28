# 无窗口 XAML 校验探针：只解析 XAML + 建 FindName 表，不 Show 任何窗口、不写 EC。
# 必须在 src 目录下运行（头部代码用 $PSScriptRoot 找 misc.ps1 / model-guard.ps1）。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null

$src = Join-Path $PSScriptRoot 'ClevoHelper.ps1'
$text = Get-Content -LiteralPath $src -Raw -Encoding UTF8

# ---- 1) 截取到 $xaml 赋值结束为止的头部，执行它（定义设置/色板/辅助函数） ----
$hdr = '$xaml = @"'
$i0 = $text.IndexOf($hdr)
if ($i0 -lt 0) { throw '没找到 $xaml 赋值' }
$i1 = $text.IndexOf("`r`n`"@", $i0)
if ($i1 -lt 0) { $i1 = $text.IndexOf("`n`"@", $i0) }
$head = $text.Substring(0, $i1 + 4)
# $PSScriptRoot 在 Create() 出来的 scriptblock 里是空串，会把 Join-Path 打崩；先把路径写字面量替换进去。
$lit = "'" + ($PSScriptRoot -replace "'", "''") + "'"
$head = $head.Replace('$PSScriptRoot', $lit)
# 头部里带单实例守卫：已有面板在跑时它会 exit 0，探针就"什么都不输出地退出"。
# 探针不建窗口、不碰全局状态，把那一行去掉即可（只影响探针自己的副本）。
$head = [regex]::Replace($head, '(?m)^\s*exit 0\s*$', '# [probe] 抑制单实例 exit 0')
. ([scriptblock]::Create($head))
Write-Output ('头部已执行：xaml {0} 字符' -f $xaml.Length)

# ---- 2) 解析 XAML（不 Show） ----
$win = [Windows.Markup.XamlReader]::Parse($xaml)
Write-Output ('XAML 解析成功：Window "{0}"  {1}x{2}  子元素 {3}' -f $win.Title, $win.Width, $win.Height, $win.Content.ChildCount)

# ---- 3) 取 $names 定义并建表 ----
$n0 = $text.IndexOf('$names = @(', $i1)
if ($n0 -lt 0) { throw '没找到 $names 定义' }
$nEnd = $text.IndexOf('foreach ($k in $names)', $n0)
if ($nEnd -lt 0) { throw '没找到 FindName 循环' }
. ([scriptblock]::Create($text.Substring($n0, $nEnd - $n0)))
Write-Output ('$names 共 {0} 个' -f $names.Count)

$missing = @()
$dup = @()
$seen = @{}
foreach ($k in $names) {
    $c = $win.FindName($k)
    if ($null -eq $c) { $missing += $k }
    if ($seen.ContainsKey($k)) { $dup += $k } else { $seen[$k] = 1 }
}
Write-Output ('FindName 命中 {0} / {1}' -f ($names.Count - $missing.Count), $names.Count)
if ($missing.Count) { Write-Output ('✘ 找不到的控件: ' + ($missing -join ', ')) } else { Write-Output '✔ 所有名字都能 FindName' }
if ($dup.Count) { Write-Output ('✘ 重复登记: ' + ($dup -join ', ')) }

# ---- 4) 源码里重复的 x:Name（WPF 会静默只保留第一个） ----
$all = [regex]::Matches($xaml, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$g = $all | Group-Object | Where-Object { $_.Count -gt 1 }
if ($g) { Write-Output ('✘ XAML 里重复的 x:Name: ' + (($g | ForEach-Object { $_.Name + '×' + $_.Count }) -join ', ')) }
else { Write-Output ('✔ XAML 里 {0} 个 x:Name 无重复' -f $all.Count) }

# ---- 5) 每页可见性与内容数 ----
foreach ($t in 'State', 'Perf', 'Kb', 'Batt', 'Misc', 'Sys', 'About') {
    $el = $win.FindName("Tab$t")
    if ($null -eq $el) { Write-Output ("✘ Tab$t 不存在"); continue }
    $kids = 0
    if ($el -is [System.Windows.Controls.ScrollViewer]) { $kids = $el.Content.Children.Count }
    Write-Output ('  Tab{0,-5} 可见={1,-9} 直接子元素={2}' -f $t, $el.Visibility, $kids)
}

# ---- 6) 页框高度一致性（切换页不该改变窗口高） ----
$sp = $win.FindName('StatePanel'); $cp = $win.FindName('ControlPanel')
Write-Output ('页框: StatePanel={0} / ControlPanel={1}  {2}' -f $sp.Height, $cp.Height,
    $(if ($sp.Height -eq $cp.Height -and $sp.Height -ne [double]::NaN) { '✔ 等高（窗口不会因切页跳动）' } else { '✘ 不等高' }))

# ---- 7) 新加控件的实测 ----
foreach ($k in 'Dev_Model', 'Dev_Serial', 'Dev_Bios', 'Dev_Windows', 'RunUp', 'RunFreq', 'RunLogSize', 'RunLogPath', 'DevKb', 'DevTp', 'BhHealth', 'TitleTemps') {
    $c = $win.FindName($k)
    if ($null -eq $c) { Write-Output ("✘ 新控件 {0} 缺失" -f $k) }
    else { Write-Output ('  {0,-12} 就位  Text="{1}"' -f $k, $c.Text) }
}
Write-Output 'XAML-PROBE DONE'

# ---- 8) 每页内容实际需要的尺寸（纯测量，不 Show） ----
# 宽度链：窗口 468 − 根 Border 外边距 16×2 = 436；页框 Padding 20+20 = 396；页内 Padding 右边 6 → 390
Write-Output '--- 每页期望高度（宽 390，页框可用高 464）---'
foreach ($t2 in 'State', 'Perf', 'Kb', 'Batt', 'Misc', 'Sys', 'About') {
    $sv = $win.FindName("Tab$t2")
    if ($null -eq $sv) { continue }
    $panel = $sv.Content
    $panel.Measure((New-Object System.Windows.Size(390, [double]::PositiveInfinity)))
    $h = [Math]::Round($panel.DesiredSize.Height, 1)
    $mark = if ($h -le 464) { '✔ 放得下' } else { '✘ 超出 ' + [Math]::Round($h - 464, 1) + 'px' }
    Write-Output ('  Tab{0,-6} 需要 {1,7} px   {2}' -f $t2, $h, $mark)
}

# ---- 9) 离屏渲染每一页成 PNG（不 Show 窗口、不碰鼠标） -------------------
# 渲染的是 $win.Content（root Border），不是 Window：未显示的 Window 没有 PresentationSource，
# RenderTargetBitmap 直接 Render($win) 常常是空白；root Border 已经有背景色，排版也完整。
Write-Output 'OFFSCREEN-RENDER begin'
$rt = 1.5
$root = $win.Content
$outDir = 'C:\Users\yeguang\DSH\_probe\r11'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# 用真实长度的示例文字，才能看出"字被吞掉"这类问题
$sample = @{
    'About_Version' = 'v1.3'; 'About_Built' = '2026-10-28 23:58'
    'About_Mode' = '单文件 exe（已部署）'; 'About_ExePath' = 'C:\Users\yeguang\AppData\Local\ClevoHelper\ClevoHelper.exe'
    'About_DataDir' = 'C:\Users\yeguang\AppData\Local\ClevoHelper'
    'Dev_Model' = 'X17 Pro Max'; 'Dev_Serial' = 'NKX370SNVG0000003C00530'
    'Dev_Bios' = '1.07.10TCOLO'; 'Dev_Windows' = 'Microsoft Windows 11 家庭中文版 10.0.26100'
    'RunUp' = '2 小时 14 分'; 'RunFreq' = '1000 ms'; 'RunLogSize' = '412 KB'
    'RunLogPath' = '%LOCALAPPDATA%\ClevoHelper\artifacts\monitor-debug.log'
    'DevKb' = 'VID_048D / PID_8910 · ITE 829x'; 'DevTp' = 'HID-compliant mouse · HID'
    'BhHealth' = '88.6 %'; 'BhCycles' = '2024-06'; 'BhDesign' = '103,056 mWh'
    'BhFull' = '91,352 mWh'; 'BhNow' = '72,671 mWh'; 'BhVolt' = '16.31 V'
    'BhRate' = '-12.4 W'; 'BhTemp' = '28.6 ℃'; 'BhMfr' = 'SMP'; 'BhDev' = 'DELL 4K1VY42'; 'BhChem' = 'LiP'; 'BhLeft' = '接电源'
    'TitleTemps' = 'CPU 72° · GPU 37°'
    'BattText' = '72% · 放电中'; 'BattAdvice' = '建议：电量低于 20% 时接上电源，长期插电建议把充电上限设到 80%。'
    'ChargerHint' = '当前 70%–80%：插着也只在低于 70% 时充，到 80% 停。'
    'CurveHealth' = '曲线 60℃→45% / 85℃→65%，两段都在安全区内。'
    'CustHint' = '拖动节点改的是自定义曲线；要它生效需把上面的风扇模式选到「自定义」。'
    'ModeText' = '风扇 自定义'; 'CurveText' = '60℃ 45% · 85℃ 65%'
    'GpuNow' = '当前启动模式：dGPU 独显'
    'SceneHint' = '点一下同时改电源、风扇、键盘灯、亮度（自定义曲线不受影响）'
    'KbHint' = '键盘灯没有回读，改完请肉眼看一眼。'
    'MiscHint' = '这里的开关直接写 EC，重启后保持。摄像头没有对应命令字，所以本工具不提供摄像头开关。'
    'CoolHint' = '温度/转速来自 EC 与 NVML，1 秒刷新一次。'
    'AboutCheckUpdateT' = '检查更新'; 'AboutUpdateStatus' = '已是最新版（v1.3）'
}
foreach ($k in $sample.Keys) {
    $c = $win.FindName($k)
    if ($null -ne $c -and ($c -is [System.Windows.Controls.TextBlock])) { $c.Text = $sample[$k] }
}
foreach ($k in 'NowPower','NowFan','NowGpu','NowKb') {
    $c = $win.FindName($k); if ($null -ne $c) { $c.Text = '性能 / 自定义 / dGPU / 关闭' }
}

$pages = @(
    @{ Id = 'state'; Files = @('TabState', 'StatePanel'); Pill = 'TabBtnState'; Out = 'p1-overview.png' },
    @{ Id = 'perf';  Files = @('TabPerf');  Pill = 'TabBtnPerf';  Out = 'p2-perf.png' },
    @{ Id = 'kb';    Files = @('TabKb');    Pill = 'TabBtnKb';    Out = 'p3-led.png' },
    @{ Id = 'batt';  Files = @('TabBatt');  Pill = 'TabBtnBatt';  Out = 'p4-batt.png' },
    @{ Id = 'misc';  Files = @('TabMisc');  Pill = 'TabBtnMisc';  Out = 'p5-dev.png' },
    @{ Id = 'sys';   Files = @('TabSys');   Pill = 'TabBtnSys';   Out = 'p6-sys.png' },
    @{ Id = 'about'; Files = @('TabAbout'); Pill = 'TabBtnAbout'; Out = 'p7-about.png' }
)
$allPages = @('TabState', 'StatePanel', 'TabPerf', 'TabKb', 'TabBatt', 'TabMisc', 'TabSys', 'TabAbout')
$allPills = @('TabBtnState', 'TabBtnPerf', 'TabBtnKb', 'TabBtnBatt', 'TabBtnMisc', 'TabBtnSys', 'TabBtnAbout')

foreach ($pg in $pages) {
    foreach ($nm in $allPages) {
        $e = $win.FindName($nm)
        if ($null -eq $e) { continue }
        $e.Visibility = $(if ($pg.Files -contains $nm) { 'Visible' } else { 'Collapsed' })
    }
    $cpv = $win.FindName('ControlPanel')
    if ($null -ne $cpv) { $cpv.Visibility = $(if ($pg.Id -eq 'state') { 'Collapsed' } else { 'Visible' }) }
    foreach ($nm in $allPills) {
        $b = $win.FindName($nm); $bt = $win.FindName($nm + 'T')
        if ($null -eq $b) { continue }
        $on = ($nm -eq $pg.Pill)
        $b.Background = (New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(255, $(if ($on) { 0xB9 } else { 0x26 }), $(if ($on) { 0x8B } else { 0x2A }), $(if ($on) { 0xFF } else { 0x33 }))))
        if ($null -ne $bt) {
            $bt.Foreground = (New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.Color]::FromArgb(255, $(if ($on) { 0x14 } else { 0x98 }), $(if ($on) { 0x16 } else { 0xA1 }), $(if ($on) { 0x19 } else { 0xB3 }))))
        }
    }
    $root.Measure((New-Object System.Windows.Size(468, [double]::PositiveInfinity)))
    $root.Arrange((New-Object System.Windows.Rect(0, 0, 468, $root.DesiredSize.Height)))
    $root.UpdateLayout()
    $wpx = [int][Math]::Ceiling(468 * $rt)
    $hpx = [int][Math]::Ceiling($root.DesiredSize.Height * $rt)
    $rtb = New-Object -TypeName System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList @([int]$wpx, [int]$hpx, [double](96 * $rt), [double](96 * $rt), [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create((Join-Path $outDir $pg.Out))
    $enc.Save($fs); $fs.Close()
    Write-Output ('  {0,-14} {1}x{2}  {3}' -f $pg.Out, $wpx, $hpx, (Join-Path $outDir $pg.Out))
}
Write-Output 'OFFSCREEN-RENDER done'
