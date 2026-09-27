# diag-flexicharger.ps1 - READ ONLY probe of the FlexiCharger (battery charge limit) channel.
#
# The vendor's own module sends, on a checkbox/combobox change:
#     buf[0] = 0x1F ; buf[1] = enable ; buf[2] = start% ; buf[3] = stop%
#     DCHU.SetWMIPackageEx(4, buf, out)          <- ControlCenter30.Window1.SetFlexiCharger()
# and it READS with 0x1E, logging `buf[0]` as "FlexiCharger status" and `buf[2]` as
# "stopCharge" (CLEVOCO.FnhotkeysandOSD binary). 0x1E is therefore the read-back for 0x1F.
#
# This script only sends the READ. Nothing is written.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

"=== DCHU cmd 4 sub 0x1E (read FlexiCharger) ==="
$buf = New-Object byte[] 256
$buf[0] = 0x1E
$out = New-Object byte[] 256
$rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $buf, 256, $out)
"  rc = 0x{0:X8}" -f $rc
"  out[0..15] = {0}" -f (($out[0..15] | ForEach-Object { $_.ToString('X2') }) -join ' ')
"  -> status(out[0])={0}  start(out[1])={1}  stop(out[2])={2}  out[3]={3}" -f `
    [int]$out[0], [int]$out[1], [int]$out[2], [int]$out[3]
# Load_Preference() clears both combos and repopulates them from THIS response:
#   out[16..31] -> ComboBox_ChargerStart items   (zero = no item)
#   out[32..47] -> ComboBox_ChargerStop  items
# so the allowed thresholds come from the EC, not from a guess about the vendor's UI.
"  allowed start out[16..31] : {0}" -f (($out[16..31] | Where-Object { $_ -ne 0 }) -join ', ')
"  allowed stop  out[32..47] : {0}" -f (($out[32..47] | Where-Object { $_ -ne 0 }) -join ', ')
"  raw out[16..47] = {0}" -f (($out[16..47] | ForEach-Object { $_.ToString('X2') }) -join ' ')

''
'=== AppSettings ==='
foreach ($id in @(0x12E, 0x132)) {
    $page = $id -shr 8
    $off = $id -band 0xFF
    $b = (Get-AppSettingPage $page).Bytes
    "  0x{0:X3} (page {1} off 0x{2:X2}) = {3}" -f $id, $page, $off, [int]$b[$off]
}

''
'=== battery (WMI) ==='
Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | ForEach-Object {
    "  {0}  charge={1}%  BatteryStatus={2} (2=AC, 1=discharging)" -f $_.Name, $_.EstimatedChargeRemaining, $_.BatteryStatus
}
