# Try-LedEncodings.ps1 - try each candidate keyboard-LED encoding in turn.
#
# WHY: the ITE 829x protocol is documented by four open-source projects and the vendor's
# own IL agrees, but LED COLOUR has NO software read-back on this machine - I scanned all
# 256 report IDs on all four HID collections, and no AppSetting reflects the colours.
# So the only way to confirm the encoding is to look at the keyboard.
#
# This walks the candidates, printing what it just sent, with a pause between each.
# Tell me which one actually lit the keyboard.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Try-LedEncodings.ps1
#
# Every attempt uses a distinct colour so they are easy to tell apart, and the script
# restores a plain blue at the end regardless.
[CmdletBinding()]
param([int]$PauseSeconds = 6)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kbled.ps1')

function Say($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Hex($b) { ($b | ForEach-Object { $_.ToString('X2') }) -join ' ' }

$cols = Get-LedCollection
$cmd = $cols | Where-Object Role -eq 'cmd'
$mtx = $cols | Where-Object Role -eq 'matrix'

function SendRaw($col, [byte[]]$bytes) {
    $h = Open-LedDevice $col -Write
    if ($h -eq [IntPtr]::new(-1)) { throw "cannot open $($col.HwId) for write" }
    try {
        $send = New-Object byte[] $col.FeatLen
        [Array]::Copy($bytes, $send, [Math]::Min($bytes.Length, $col.FeatLen))
        $ok = [ClevoHelper.LedNative]::HidD_SetFeature($h, $send, $col.FeatLen)
        Write-Host ("   sent -> {0}   ({1})" -f (Hex $send), $(if ($ok) { 'accepted' } else { 'REJECTED' }))
        return $ok
    }
    finally { [void][ClevoHelper.LedNative]::CloseHandle($h) }
}

Write-Host 'WATCH THE KEYBOARD. Each step sends a different colour/encoding.' -ForegroundColor Yellow
Write-Host "Pausing $PauseSeconds s between steps. Ctrl+C to stop at any time."
Start-Sleep -Seconds 3

# --- A: the documented encoding - col02, 7 bytes, cmd 0x01, all keys red ------------
Say "A: col02 {CC 01 <key> FF 00 00 00} per key  -> expect ALL KEYS RED"
Set-LedBrightness -Level 10 -Speed 1 -Apply | Out-Null
Clear-Led -Apply | Out-Null
foreach ($k in $script:LedKeyIds) {
    SendRaw $cmd ([byte[]]@(0xCC, 0x01, [byte]$k, 0xFF, 0x00, 0x00, 0x00)) | Out-Null
}
Start-Sleep -Seconds $PauseSeconds

# --- B: 6-byte writes (what the Linux implementations send) -------------------------
Say "B: same but 6-byte writes (Linux style) -> expect ALL KEYS GREEN"
$h = Open-LedDevice $cmd -Write
if ($h -ne [IntPtr]::new(-1)) {
    try {
        [void][ClevoHelper.LedNative]::HidD_SetFeature($h, [byte[]]@(0xCC, 0x00, 0x0C, 0x00, 0x00, 0x00), 6)
        foreach ($k in $script:LedKeyIds) {
            [void][ClevoHelper.LedNative]::HidD_SetFeature($h, [byte[]]@(0xCC, 0x01, [byte]$k, 0x00, 0xFF, 0x00), 6)
        }
        Write-Host '   sent 6-byte variant for every key'
    }
    finally { [void][ClevoHelper.LedNative]::CloseHandle($h) }
}
Start-Sleep -Seconds $PauseSeconds

# --- C: 8291-style 65-byte row matrix on the 0xCF collection ------------------------
Say "C: col04 65-byte matrix (2 pad + 21 B + 21 G + 21 R per row) -> expect ALL KEYS BLUE"
if ($mtx) {
    for ($row = 0; $row -lt 6; $row++) {
        $buf = New-Object byte[] 65
        $buf[0] = 0xCF
        for ($c = 0; $c -lt 21; $c++) { $buf[2 + $c] = 0xFF }          # blue plane
        SendRaw $mtx $buf | Out-Null
    }
}
else { Write-Host '   no 0xCF collection' }
Start-Sleep -Seconds $PauseSeconds

# --- D: the vendor's ClearColor + one key, in case only the clear was missing -------
Say "D: ClearColor then a SINGLE key (Esc) magenta - easiest to spot"
Clear-Led -Apply | Out-Null
SendRaw $cmd ([byte[]]@(0xCC, 0x01, 0x00, 0xFF, 0x00, 0xFF, 0x00)) | Out-Null
Start-Sleep -Seconds $PauseSeconds

# --- restore -----------------------------------------------------------------------
Say 'restoring: all keys blue at full brightness'
Set-LedBrightness -Level 10 -Speed 1 -Apply | Out-Null
Set-LedAllColor -R 0 -G 0 -B 255 -Apply 6>$null | Out-Null

Write-Host ''
Write-Host 'Done. Tell me which step (A/B/C/D) changed the keyboard, or if none did.' -ForegroundColor Yellow
Write-Host 'Undo any time with:  . .\src\kbled.ps1 ; Clear-Led -Apply' -ForegroundColor DarkGray
