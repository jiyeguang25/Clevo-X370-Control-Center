# revert-worker.ps1 - detached watchdog: restore a saved ClevoHelper state after N seconds.
# Spawned by Start-ClevoRevertTimer. Survives the death of the calling shell.
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][int]$Seconds
)

$ErrorActionPreference = 'Continue'
$logDir = Split-Path $StatePath -Parent
$log = Join-Path $logDir 'revert.log'

function Log([string]$m) {
    Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $m) -ErrorAction SilentlyContinue
}

Log "watchdog armed: restore in $Seconds s from $(Split-Path $StatePath -Leaf)"
Start-Sleep -Seconds $Seconds

try {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\dchu.ps1')
    $s = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json

    # Straight to the primitives: this path must not depend on fanctl.ps1's helpers.
    $buf = New-Object byte[] 256
    $buf[0] = [byte]([int]$s.FanMode -band 0xFF)
    [void][ClevoHelper.DchuApi]::SetDCHU_Data(121, [byte[]]@($buf[0], 0, 0, 1), 4)
    [void][ClevoHelper.DchuApi]::WriteAppSettings(4, 5, 1, $buf)

    $buf2 = New-Object byte[] 256
    $buf2[0] = [byte]([int]$s.PowerMode -band 0xFF)
    [void][ClevoHelper.DchuApi]::SetDCHU_Data(121, [byte[]]@($buf2[0], 0, 0, 25), 4)
    [void][ClevoHelper.DchuApi]::WriteAppSettings(1, 1, 1, $buf2)

    Log "restored fan=$($s.FanMode) power=$($s.PowerMode)"
}
catch {
    Log ('RESTORE FAILED: ' + $_.Exception.Message)
    # last resort: hand the fans back to the EC
    try {
        [void][ClevoHelper.DchuApi]::SetDCHU_Data(121, [byte[]]@(0, 0, 0, 1), 4)
        Log 'fallback applied: fan mode Auto'
    }
    catch { Log 'fallback also failed' }
}
