# Install-Watchdog.ps1 - keep ClevoHelper alive with a periodic scheduled task.
#
# WHY: the panel now recovers its own sampler runspace if that thread dies, but if the
# whole process goes away (crash, task manager, an aggressive "cleanup" tool) nothing
# brings it back. This task runs every 5 minutes and calls Start-Panel.ps1, which is
# idempotent: it exits immediately when the panel is already running.
#
# No administrator rights needed - a per-user task in the user's own context, which is
# also what we want, because the panel is a GUI in the interactive session.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-Watchdog.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-Watchdog.ps1 -Uninstall
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [int]$EveryMinutes = 5
)

$taskName = 'ClevoHelper Watchdog'
$starter = Join-Path $PSScriptRoot 'Start-Panel.ps1'

if ($Uninstall) {
    $r = schtasks /delete /tn $taskName /f 2>&1
    Write-Host $r
    return
}

if (-not (Test-Path -LiteralPath $starter)) { throw "Start-Panel.ps1 not found: $starter" }
if ($EveryMinutes -lt 1) { throw 'EveryMinutes must be >= 1' }

# /tr takes one string; quote the inner path and let schtasks store it verbatim.
$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $starter + '"'
$r = schtasks /create /tn $taskName /tr $tr /sc minute /mo $EveryMinutes /f 2>&1
Write-Host $r

$q = schtasks /query /tn $taskName /fo LIST 2>&1
Write-Host '--- task as registered ---'
$q | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host "Installed. It runs every $EveryMinutes minute(s) and starts the panel only if it is not already up."
Write-Host "Remove it with: -Uninstall"
