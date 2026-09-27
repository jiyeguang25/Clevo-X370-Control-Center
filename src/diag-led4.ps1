# diag-led4.ps1 - LIVE test of the four keyboard modes the panel offers (关闭/静态/循环/呼吸).
#
# Writes real feature reports to the keyboard and real bytes to AppSetting page 2, then reads
# the page back and compares. The mode/colour found on entry is restored at the end and the
# restore is verified, so running this leaves the machine as it was.
#
# What this can and cannot prove:
#   * read-back proves the setting was STORED (mode status byte + Effect byte)
#   * it can NOT prove what the keyboard looks like - the LED hardware reports nothing.
#     The script therefore prints, per mode, what the user should be seeing right now.
#
# Usage:  powershell -STA -NoProfile -ExecutionPolicy Bypass -File diag-led4.ps1
#         ... -KeepLast      leave the last mode applied instead of restoring
[CmdletBinding()]
param([switch]$KeepLast)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'dchu.ps1')
. (Join-Path $here 'fancurve.ps1')   # Set-AppSettingByte (read-modify-write on page 2)
. (Join-Path $here 'kbled.ps1')

# ---- what is set right now -------------------------------------------------
# Brightness is not part of Get-LedModeFromAppSettings, so read its byte directly: the test
# writes brightness 10, and putting the user's own value back is part of leaving no trace.
$pageBefore = (Get-AppSettingPage 2).Bytes
$beforeBright = [int]$pageBefore[0x23]
$before = Get-LedModeFromAppSettings
$beforeColor = if ($before.Color) { $before.Color } else { @(255, 255, 255) }
'before : mode={0} color=R{1} G{2} B{3} speed={4}/10 bright={5}/10' -f `
    $before.Mode, $beforeColor[0], $beforeColor[1], $beforeColor[2], $before.Speed, $beforeBright
''

# white for the single-colour variants, so a wrong colour is obvious to the eye
$R = 255; $G = 255; $B = 255
$cases = @(
    @{ Mode = 'static'; Rainbow = $false; Expect = '整键盘纯白常亮（无动画）' }
    @{ Mode = 'static'; Rainbow = $true;  Expect = '整键盘彩虹渐变常亮（约 0.3 秒重绘）' }
    @{ Mode = 'cycle';  Rainbow = $false; Expect = '全键盘自动循环变色（动画）' }
    @{ Mode = 'breath'; Rainbow = $false; Expect = '整键盘白色呼吸（渐亮渐暗）' }
    @{ Mode = 'breath'; Rainbow = $true;  Expect = '整键盘彩色呼吸（固件配色）' }
    # 波：帧里 d0 = 0xA1 + 方向（指定单色）或 0x71 + 方向（固件配色，即"色带滚过键盘"）
    @{ Mode = 'wave';   Rainbow = $false; Dir = 0; Expect = '白色波从右往左滚过（方向 右）' }
    @{ Mode = 'wave';   Rainbow = $false; Dir = 1; Expect = '白色波从左往右滚过（方向 左）' }
    @{ Mode = 'wave';   Rainbow = $true;  Dir = 0; Expect = '彩色色带滚过键盘（固件配色，方向 右）' }
)

$fail = 0
foreach ($c in $cases) {
    $label = $c.Mode + $(if ($c.Rainbow) { '+彩虹' } else { '' }) + $(if ($c.ContainsKey('Dir')) { ' 方向' + $c.Dir } else { '' })
    try {
        $dir = [int]$($c.Dir)
        if ($dir -lt 0) { $dir = 0 }
        [void](Set-LedMode -Mode $c.Mode -R $R -G $G -B $B -Direction $dir -Random:$c.Rainbow -Brightness 10 -Speed 5 -Apply)
    }
    catch {
        "[FAIL] {0,-12} 写入异常：{1}" -f $label, $_.Exception.Message
        $fail++
        continue
    }
    $back = Get-LedModeFromAppSettings
    $ok = ($back.Mode -eq $c.Mode)
    if (-not $ok) { $fail++ }
    "{0} {1,-12} 回读模式={2,-7} 速度={3}/10  期望看到：{4}" -f `
        $(if ($ok) { '[ OK ]' } else { '[FAIL]' }), $label, $(if ($back.Mode) { $back.Mode } else { '(无)' }), $back.Speed, $c.Expect
    Start-Sleep -Milliseconds 900   # let the user's eye catch up before the next one
}

'' 
if ($KeepLast) {
    "kept   : mode=$($cases[-1].Mode) (last case left applied)"
}
else {
    # Strict restore, in this order:
    #   1. put the original mode back on the hardware (HID frames)
    #   2. write the ORIGINAL page-2 bytes back over everything this test could have touched
    #      (0x20-0x4F). Step 1 also mirrors its own parameters into that range, so byte 2 must
    #      come after it - otherwise a mode the test never used could be left with the test's
    #      colour. The snapshot is what makes "leaves no trace" checkable instead of claimed.
    $failHere = $false
    try {
        [void](Set-LedMode -Mode $before.Mode -R $beforeColor[0] -G $beforeColor[1] -B $beforeColor[2] `
                -Brightness $beforeBright -Speed $before.Speed -Apply)
    }
    catch {
        "restore: hardware FAILED - $($_.Exception.Message)"
        $fail++; $failHere = $true
    }
    if (-not $failHere) {
        $patch = @{}
        for ($o = 0x20; $o -le 0x4F; $o++) { $patch[$o] = [int]$pageBefore[$o] }
        [void](Set-AppSettingByte -Page 2 -Patch $patch -Apply)
        $pageAfter = (Get-AppSettingPage 2).Bytes
        $diff = @()
        for ($o = 0x20; $o -le 0x4F; $o++) {
            if ([int]$pageAfter[$o] -ne [int]$pageBefore[$o]) {
                $diff += ('[{0:X2}] {1:X2}->{2:X2}' -f $o, [int]$pageBefore[$o], [int]$pageAfter[$o])
            }
        }
        $restored = Get-LedModeFromAppSettings
        if ($diff.Count -eq 0 -and $restored.Mode -eq $before.Mode) {
            "restore: OK -> $($restored.Mode), page 2 bytes 0x20-0x4F identical to the snapshot"
        }
        else {
            "restore: MISMATCH mode=$($restored.Mode) (wanted $($before.Mode)) diff=$($diff -join ' ')"
            $fail++
        }
    }
}
''
if ($fail) { "RESULT: $fail problem(s)" } else { 'RESULT: 全部模式（含波与方向）写入并读回一致' }
exit $(if ($fail) { 1 } else { 0 })
