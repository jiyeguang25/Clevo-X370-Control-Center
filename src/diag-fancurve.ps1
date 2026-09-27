# 风扇曲线：独立读一遍 EC 现在到底在跑什么，并按"吸附到 5"给出面板会显示的值。
#
# 两个来源要分清（这是这块最容易搞混的地方）：
#   · block 13 = **EC 正在执行的运行时表**（面板"曲线健康度"和"正在执行的 4 节点表"看的就是它）
#   · page 4  = 原厂持久化的那份表（写曲线时**故意不镜像**它，见 README 里那段教训）
# 用法：diag-fancurve.ps1 [-Snap]
param([switch]$Snap)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

$lim = @{ TMin = 45; TMax = 95; DMin = 30; DMax = 100; Step = 5 }
function Snap([int]$v, [int]$min, [int]$max) {
    $st = $lim.Step
    $r = [int]([Math]::Round($v / $st) * $st)
    if ($r -lt $min) { $r = [int]([Math]::Ceiling($min / $st) * $st) }
    if ($r -gt $max) { $r = [int]([Math]::Floor($max / $st) * $st) }
    return $r
}

$b = (Get-WmiPackage 13).Bytes
'==== block 13（EC 正在执行的运行时表）===='
'  原始字节 [16..23]: ' + (($b[16..23] | ForEach-Object { '{0,3}' -f $_ }) -join ' ')
$t = @([int]$b[16], [int]$b[18], [int]$b[20])
$d = @([int]$b[17], [int]$b[19], [int]$b[21])
$pct = @($d | ForEach-Object { [int][Math]::Round(100.0 * $_ / 255) })
for ($i = 0; $i -lt 3; $i++) {
    '  节点{0}  {1,3}°C  raw={2,3}  = {3,3}%   {4}' -f ($i + 1), $t[$i], $d[$i], $pct[$i], $(if ($Snap) { '→ 吸附 ' + (Snap $pct[$i] $lim.DMin $lim.DMax) + '%' } else { '' })
}
'  节点4  100°C  100%（EC 固定）'

if ($Snap) {
    '==== 面板会显示的值（吸附到 5，节点 2/3 可调）===='
    $sT2 = Snap $t[1] $lim.TMin $lim.TMax
    $sD2 = Snap $pct[1] $lim.DMin $lim.DMax
    $sT3 = Snap $t[2] $lim.TMin $lim.TMax
    $sD3 = Snap $pct[2] $lim.DMin $lim.DMax
    if ($sT3 -le $sT2) { $sT3 = [Math]::Min($lim.TMax, $sT2 + $lim.Step) }
    if ($sD3 -lt $sD2) { $sD3 = $sD2 }
    '  T2={0}  D2={1}%' -f $sT2, $sD2
    '  T3={0}  D3={1}%' -f $sT3, $sD3
    '  （要写进 settings.json 的就是这四个数）'
}
