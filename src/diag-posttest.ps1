# 自检跑完以后，机器上的设置有没有被留在"测试值"上？——独立读一遍 EC（不是自检自己报的那份）。
# 期望：电源/风扇回到自检前（面板启动状态是 power=2 fan=6）、充电窗口 70/80、显卡模式不变。
. (Join-Path $PSScriptRoot 'dchu.ps1')

$t = Get-ClevoTelemetry
if ($t) {
    "电源模式 : {0}" -f $t.PowerMode
    "风扇模式 : {0}" -f $t.FanMode
}
else { 'Get-ClevoTelemetry 读不到' }

$c = Get-FlexiCharger
"充电限制 : {0}" -f $(if ($c) { "启用=$($c.Enabled)  $($c.Start)-$($c.Stop)%" } else { '读不到' })

$g = Get-GpuMode
"显卡模式 : {0}" -f $(if ($g) { "生效=$($g.Mode)($($g.ModeName))  支持=0x{0:X}  暂存项=$($g.Persisted)" -f [int]$g.Mask } else { '读不到' })

$k = Get-KeyboardSetting
"键盘设置 : {0}" -f $(if ($k) { "FnLock=$($k.FnLock) WinKey=$($k.WinKey) WinFn=$($k.WinFnSwap)" } else { '读不到' })
