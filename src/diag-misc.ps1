# diag-misc.ps1 - LIVE round-trip test of the switches on the 杂项 tab.
#
# Every case writes a value, reads it back through the channel the panel uses, and (except
# for the NumLock case, which is left as-is) restores what it found. Prints one line per case.
#
# NOT verifiable by software (say so instead of pretending): whether the touchpad, the
# NumLock lamp or the panel brightness actually changed on the physical machine.
#
# Usage: powershell -STA -NoProfile -ExecutionPolicy Bypass -File diag-misc.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')
. (Join-Path $PSScriptRoot 'fancurve.ps1')   # Set-AppSettingByte (RMW)
. (Join-Path $PSScriptRoot 'misc.ps1')

$fail = 0
function Show([string]$status, [string]$what, [string]$detail) {
    '{0} {1,-14} {2}' -f $status, $what, $detail
}

'--- 电池充电 (DCHU cmd 4 sub 0x1E / 0x1F) ---'
$c0 = Get-FlexiCharger
'  before : enabled={0} start={1} stop={2}  rc={3}' -f $c0.Enabled, $c0.Start, $c0.Stop, $c0.Rc
'  EC 允许的起始电量 : {0}' -f ($c0.StartOptions -join ', ')
'  EC 允许的停止电量 : {0}' -f ($c0.StopOptions -join ', ')

# same values -> proves the write path without changing behaviour
$r = Set-FlexiCharger -Enabled $c0.Enabled -Start $c0.Start -Stop $c0.Stop -Apply
if ($r.Ok) { Show '[ OK ]' '写回原值' $r.After } else { $fail++; Show '[FAIL]' '写回原值' "$($r.Before) -> $($r.After)" }

# a different legal pair, then back
$altStart = $c0.StartOptions | Where-Object { $_ -lt $c0.Start } | Select-Object -Last 1
$altStop = $c0.StopOptions | Where-Object { $_ -lt $c0.Stop } | Select-Object -Last 1
if ($null -ne $altStart -and $null -ne $altStop -and $altStart -lt $altStop) {
    $r = Set-FlexiCharger -Enabled $true -Start $altStart -Stop $altStop -Apply
    if ($r.Ok) { Show '[ OK ]' '改阈值' ('{0}-{1}% 读回一致' -f $altStart, $altStop) } else { $fail++; Show '[FAIL]' '改阈值' "$($r.Before) -> $($r.After)" }
}
else { Show '[skip]' '改阈值' 'EC 没有更低的合法组合' }

# the vendor's 最大电池电量 = limit off; restore right after
$r = Set-FlexiCharger -Enabled $false -Apply
if ($r.Ok) { Show '[ OK ]' '不限制' '读回 enabled=False（= 原厂“最大电池电量”）' } else { $fail++; Show '[FAIL]' '不限制' "$($r.Before) -> $($r.After)" }
$r = Set-FlexiCharger -Enabled $c0.Enabled -Start $c0.Start -Stop $c0.Stop -Apply
if ($r.Ok) { Show '[ OK ]' '恢复' $r.After } else { $fail++; Show '[FAIL]' '恢复' "$($r.Before) -> $($r.After)" }

''
'--- 键盘设置 (DCHU cmd 4 sub 0x19 + 镜像 0x124-0x126) ---'
$k0 = Get-KeyboardSetting
'  before : raw={0}  FnLock={1} Win键={2} Win/Fn交换={3}' -f ($k0.Raw -join ','), $k0.FnLock, $k0.WinKey, $k0.WinFnSwap
# flip Win key off and back - the one switch whose effect the user can see immediately
$r = Set-KeyboardSetting -WinKey $false -Apply
if ($r.Ok) { Show '[ OK ]' '禁用 Win 键' "$($r.Frame) -> $($r.After)" } else { $fail++; Show '[FAIL]' '禁用 Win 键' $r.After }
Start-Sleep -Milliseconds 400
$r = Set-KeyboardSetting -WinKey $k0.WinKey -Apply
if ($r.Ok) { Show '[ OK ]' '恢复 Win 键' $r.After } else { $fail++; Show '[FAIL]' '恢复 Win 键' $r.After }

''
'--- 屏幕亮度 (WMI) ---'
$b0 = Get-ScreenBrightness
'  before : {0}%' -f $b0.Percent
$r = Set-ScreenBrightness -Percent $b0.Percent -Apply
if ($r.Ok) { Show '[ OK ]' '写回原值' ('{0}% -> {1}%' -f $r.Before, $r.After) } else { $fail++; Show '[FAIL]' '写回原值' ('{0}% -> {1}%' -f $r.Before, $r.After) }
$alt = [Math]::Max(10, $b0.Percent - 10)
$r = Set-ScreenBrightness -Percent $alt -Apply
if ($r.Ok) { Show '[ OK ]' '调暗 10%' ('{0}% -> {1}%' -f $r.Before, $r.After) } else { $fail++; Show '[FAIL]' '调暗 10%' ('{0}% -> {1}%' -f $r.Before, $r.After) }
Start-Sleep -Milliseconds 600
$r = Set-ScreenBrightness -Percent $b0.Percent -Apply
if ($r.Ok) { Show '[ OK ]' '恢复亮度' ('{0}%' -f $r.After) } else { $fail++; Show '[FAIL]' '恢复亮度' ('{0}%' -f $r.After) }

''
'--- 触控板 (注册表 Enabled + 原厂 Ctrl+Win+F24) ---'
$t0 = Get-TouchPadState
'  before : enabled={0}' -f $t0.Enabled
$r = Set-TouchPadState -Enabled $false -Apply
if ($r.Ok) { Show '[ OK ]' '关闭触控板' '注册表读回 0' } else { $fail++; Show '[FAIL]' '关闭触控板' '注册表读回不为 0' }
Start-Sleep -Milliseconds 800
$r = Set-TouchPadState -Enabled $true -Apply
if ($r.Ok) { Show '[ OK ]' '打开触控板' '注册表读回 1' } else { $fail++; Show '[FAIL]' '打开触控板' '注册表读回不为 1' }

''
'--- 数字键盘 (会话 NumLock) ---'
$n0 = Get-NumLockState
'  before : On={0}' -f $n0.On
$r = Set-NumLockState -On $n0.On -Apply
if ($r.Ok) { Show '[ OK ]' '写回原值' ('On={0}' -f $r.After) } else { $fail++; Show '[FAIL]' '写回原值' ('On={0}' -f $r.After) }

''
if ($fail) { "RESULT: $fail problem(s)" } else { 'RESULT: 全部读回一致（物理效果需肉眼/指尖确认）' }
exit $(if ($fail) { 1 } else { 0 })
