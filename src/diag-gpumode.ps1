# diag-gpumode.ps1 - probe of the DCHU graphics-mode channel.
#
# Default: READ ONLY. Compares the two frame lengths (24 = what this repo used to pass,
# 256 = what ControlCenter30.exe actually passes) and prints the response buffer, so
# res[0] (current mode) and res[1] (supported-mode bitmask) can be read directly.
#
# -WriteTest -Apply: reversible write check. Writes a *supported* mode, reads it back on
#   BOTH channels (live res[0] + AppSetting PreGPU_Mode), then always restores the mode
#   that was there at the start - in a finally block, so an error still restores it.
#   The vendor's app reboots straight after the write; we never do. The mode is a
#   pre-boot value (PreGPU_Mode), so restoring it leaves the machine exactly as it was.
[CmdletBinding()]
param([switch]$WriteTest, [switch]$Apply)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

function Read-Mode {
    $req = New-Object byte[] 256
    $req[0] = 0x15
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $req, 256, $out)
    [pscustomobject]@{
        Rc        = $rc
        Live      = [int]$out[0]
        Mask      = [int]$out[1]
        Persisted = [int](Get-AppSettingPage 0).Bytes[247]
        Raw       = (($out[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
    }
}
function Write-Mode([int]$mode) {
    $req = New-Object byte[] 256
    $req[0] = 0x16
    $req[1] = [byte]$mode
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $req, 256, $out)
    $rc
}

function Show([string]$tag, [byte[]]$b, [int]$n = 24) {
    $hex = (($b[0..($n - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
    "  {0,-10} {1}" -f $tag, $hex
}

"=== READ frame: SetDCHU_DataEx(4, req[0]=0x15, LEN, out) ==="
foreach ($len in @(24, 256)) {
    $req = New-Object byte[] 256
    $req[0] = 0x15
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $req, $len, $out)
    "len={0,-4} rc=0x{1:X8}   res[0]={2} res[1]=0x{3:X2}" -f $len, $rc, $out[0], $out[1]
    Show 'res[0..]' $out 24
}

"=== 支持位图解码（res[1]，ControlCenter30 的判定） ==="
$r0 = Read-Mode
$names = @{ 0 = 'Integrated GPU only (iGPU)'; 1 = 'Discrete GPU only (dGPU)'; 2 = 'MSHybrid'; 3 = 'Dynamic' }
foreach ($bit in 0..3) {
    "  bit{0} {1,-28} {2}" -f $bit, $names[$bit], $(if (($r0.Mask -shr $bit) -band 1) { '支持' } else { '不支持' })
}
"  当前模式 res[0] = $($r0.Live)  →  $(if ($script:GpuModeName.ContainsKey($r0.Live)) { $script:GpuModeName[$r0.Live] } else { '未知' })"
"  AppSetting PreGPU_Mode = $($r0.Persisted)"

if (-not $WriteTest) {
    ''
    '（只读模式结束。要验证写入路径请加 -WriteTest -Apply）'
    return
}
if (-not $Apply) {
    ''
    '（dry-run：加 -Apply 才会真的写。会写一个受支持的模式，读回，然后还原。）'
    return
}

# --- reversible write test ---------------------------------------------------
$orig = $r0.Live
# pick a supported mode that is NOT the current one, prefer Dynamic (bit3)
$target = if ((($r0.Mask -shr 3) -band 1) -eq 1 -and $orig -ne 4) { 4 }
          elseif ((($r0.Mask -shr 0) -band 1) -eq 1 -and $orig -ne 1) { 1 }
          else { $orig }
"=== 写测试：$orig → $target → $orig（不重启） ==="
"  起点: live=$($r0.Live) persisted=$($r0.Persisted)"
try {
    $rcw = Write-Mode $target
    "  写 $target : rc=0x{0:X8}" -f $rcw
    Start-Sleep -Milliseconds 600
    $r1 = Read-Mode
    "  写后: live=$($r1.Live) persisted=$($r1.Persisted)   raw=$($r1.Raw)"
    if ($r1.Live -eq $target -or $r1.Persisted -eq $target) { '  >>> 写入生效（有读回变化）' }
    else { '  >>> 写入未生效（两个通道都没变）' }
}
finally {
    $rcb = Write-Mode $orig
    Start-Sleep -Milliseconds 600
    $r2 = Read-Mode
    "  还原 $orig : rc=0x{0:X8}  live={1} persisted={2}" -f $rcb, $r2.Live, $r2.Persisted
    if ($r2.Live -eq $orig -and $r2.Persisted -eq $orig) { '  >>> 已还原到起始状态（未重启，机器行为不变）' }
    else { '  >>> !!! 还原后与起始状态不一致，请勿重启并告知我' }
}
