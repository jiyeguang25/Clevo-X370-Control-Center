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
. ([scriptblock]::Create($head))
Write-Host ('头部已执行：xaml {0} 字符' -f $xaml.Length)

# ---- 2) 解析 XAML（不 Show） ----
$win = [Windows.Markup.XamlReader]::Parse($xaml)
Write-Host ('XAML 解析成功：Window "{0}"  {1}x{2}  子元素 {3}' -f $win.Title, $win.Width, $win.Height, $win.Content.ChildCount)

# ---- 3) 取 $names 定义并建表 ----
$n0 = $text.IndexOf('$names = @(', $i1)
if ($n0 -lt 0) { throw '没找到 $names 定义' }
$nEnd = $text.IndexOf('foreach ($k in $names)', $n0)
if ($nEnd -lt 0) { throw '没找到 FindName 循环' }
. ([scriptblock]::Create($text.Substring($n0, $nEnd - $n0)))
Write-Host ('$names 共 {0} 个' -f $names.Count)

$missing = @()
$dup = @()
$seen = @{}
foreach ($k in $names) {
    $c = $win.FindName($k)
    if ($null -eq $c) { $missing += $k }
    if ($seen.ContainsKey($k)) { $dup += $k } else { $seen[$k] = 1 }
}
Write-Host ('FindName 命中 {0} / {1}' -f ($names.Count - $missing.Count), $names.Count)
if ($missing.Count) { Write-Host ('✘ 找不到的控件: ' + ($missing -join ', ')) } else { Write-Host '✔ 所有名字都能 FindName' }
if ($dup.Count) { Write-Host ('✘ 重复登记: ' + ($dup -join ', ')) }

# ---- 4) 源码里重复的 x:Name（WPF 会静默只保留第一个） ----
$all = [regex]::Matches($xaml, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$g = $all | Group-Object | Where-Object { $_.Count -gt 1 }
if ($g) { Write-Host ('✘ XAML 里重复的 x:Name: ' + (($g | ForEach-Object { $_.Name + '×' + $_.Count }) -join ', ')) }
else { Write-Host ('✔ XAML 里 {0} 个 x:Name 无重复' -f $all.Count) }

# ---- 5) 每页可见性与内容数 ----
foreach ($t in 'State', 'Perf', 'Cool', 'Kb', 'Batt', 'Misc', 'Sys', 'About') {
    $el = $win.FindName("Tab$t")
    if ($null -eq $el) { Write-Host ("✘ Tab$t 不存在"); continue }
    $kids = 0
    if ($el -is [System.Windows.Controls.ScrollViewer]) { $kids = $el.Content.Children.Count }
    Write-Host ('  Tab{0,-5} 可见={1,-9} 直接子元素={2}' -f $t, $el.Visibility, $kids)
}

# ---- 6) 页框高度一致性（切换页不该改变窗口高） ----
$sp = $win.FindName('StatePanel'); $cp = $win.FindName('ControlPanel')
Write-Host ('页框: StatePanel={0} / ControlPanel={1}  {2}' -f $sp.Height, $cp.Height,
    $(if ($sp.Height -eq $cp.Height -and $sp.Height -ne [double]::NaN) { '✔ 等高（窗口不会因切页跳动）' } else { '✘ 不等高' }))

# ---- 7) 新加控件的实测 ----
foreach ($k in 'Dev_Model', 'Dev_Serial', 'Dev_Bios', 'Dev_Windows', 'RunUp', 'RunFreq', 'RunLogSize', 'RunLogPath', 'DevKb', 'DevTp', 'CoolCpuTemp', 'CoolGpuDuty', 'BhHealth', 'NowPower', 'TitleTemps') {
    $c = $win.FindName($k)
    if ($null -eq $c) { Write-Host ("✘ 新控件 {0} 缺失" -f $k) }
    else { Write-Host ('  {0,-12} 就位  Text="{1}"' -f $k, $c.Text) }
}
Write-Host 'XAML-PROBE DONE'
