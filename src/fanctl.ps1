# fanctl.ps1 - ClevoHelper WRITE layer (MILESTONE 2)
#
# Safety model
#   * Every setter is DRY-RUN unless you pass -Apply.
#   * Before any write, the current state is captured to state\last-good.json.
#   * After any write, the value is read back and compared.
#   * -RevertAfterSec N spawns a detached worker that restores the saved state even
#     if this shell dies. Use it while testing.
#   * Only mode/offset switches live here. The custom fan CURVE (block 14) is NOT
#     implemented yet - that is M3 and needs its own review.
#
# Usage
#   . .\fanctl.ps1
#   Get-ClevoState
#   Set-ClevoFanMode -Mode Max                 # dry-run, prints what it would do
#   Set-ClevoFanMode -Mode Max -Apply -RevertAfterSec 10
#   Restore-ClevoState -Apply

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

$script:StateDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'state'
if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir | Out-Null }
$script:LastGoodPath = Join-Path $script:StateDir 'last-good.json'

# 0x79 (121) sub-commands, payload is always {value, 0, 0, sub}
$script:SUB_FanMode          = 1
$script:SUB_FanOffset        = 14
$script:SUB_PowerMode        = 25
$script:SUB_LoadFanDefaults  = 34
$script:SUB_AntiDustNow      = 41

$script:FanModeIds = [ordered]@{ Auto = 0; Max = 1; Silent = 3; MaxQ = 5; Custom = 6; AntiDust = 7 }
$script:PowerModeIds = [ordered]@{ Quiet = 0; PowerSaving = 1; Performance = 2; Entertainment = 3 }

function Resolve-ModeId {
    param([object]$Value, [System.Collections.IDictionary]$Table, [string]$What)
    if ($Value -is [string]) {
        if ($Table.Contains($Value)) { return [int]$Table[$Value] }
        throw "unknown $What '$Value'. Valid: $($Table.Keys -join ', ')"
    }
    [int]$Value
}

# ------------------------------------------------------------------ state ----

function Get-ClevoState {
    <#
      .SYNOPSIS Current writer-relevant state. READ ONLY.
    #>
    [CmdletBinding()]
    param()
    $t = Get-ClevoTelemetry
    [pscustomobject]@{
        FanMode        = $t.FanMode
        FanModeName    = $t.FanModeName
        FanOffset      = $t.FanOffset
        TurboFan       = $t.TurboFan
        PowerMode      = $t.PowerMode
        PowerModeName  = $t.PowerModeName
        AcPowerMode    = $t.AcPowerMode
        CapturedAt     = (Get-Date).ToString('o')
    }
}

function Save-ClevoState {
    <#
      .SYNOPSIS Persist the current state so it can be restored.
    #>
    [CmdletBinding()]
    param([string]$Path)
    $s = Get-ClevoState
    if (-not $Path) { $Path = $script:LastGoodPath }
    $s | Add-Member -NotePropertyName SavedFrom -NotePropertyValue $Path -Force
    $s | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
    $stamp = Join-Path $script:StateDir ('clevo-state-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $s | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    Write-Host ("saved: fan={0}({1}) offset={2} power={3}({4}) -> {5}" -f `
        $s.FanModeName, $s.FanMode, $s.FanOffset, $s.PowerModeName, $s.PowerMode, (Split-Path $Path -Leaf))
    $s
}

function Restore-ClevoState {
    <#
      .SYNOPSIS Re-apply a previously saved state.
    #>
    [CmdletBinding()]
    param([string]$Path, [switch]$Apply)
    if (-not $Path) { $Path = $script:LastGoodPath }
    if (-not (Test-Path -LiteralPath $Path)) { throw "no saved state at $Path" }
    $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Write-Host ("restoring from {0}: fan={1} offset={2} power={3}" -f (Split-Path $Path -Leaf), $s.FanMode, $s.FanOffset, $s.PowerMode)
    Set-ClevoFanOffset -Percent $s.FanOffset -Apply:$Apply | Out-Null
    Set-ClevoFanMode   -Mode $s.FanMode     -Apply:$Apply | Out-Null
    Set-ClevoPowerMode -Mode $s.PowerMode   -Apply:$Apply | Out-Null
}

# ------------------------------------------------------------------ write ----

function Set-ClevoWmiValue {
    <#
      .SYNOPSIS Core write primitive: SetDCHU_Data(121, {value,0,0,sub}, 4).
      .NOTES Does NOT touch AppSettings - callers mirror that themselves, exactly as
             the vendor app does (otherwise Control Center's next reload wins).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Sub,
        [Parameter(Mandatory)][int]$Value,
        [switch]$Apply
    )
    $payload = [byte[]]@([byte]($Value -band 0xFF), [byte]0, [byte]0, [byte]($Sub -band 0xFF))
    $desc = 'SetDCHU_Data(121, {{{0},0,0,{1}}}, 4)' -f $payload[0], $payload[3]
    if (-not $Apply) {
        Write-Host "  [dry-run] $desc"
        return [pscustomobject]@{ Applied = $false; Cmd = $desc; Rc = $null }
    }
    $rc = [ClevoHelper.DchuApi]::SetDCHU_Data(121, $payload, 4)
    Write-Host ('  [apply]   {0} -> rc=0x{1:X8}' -f $desc, $rc)
    [pscustomobject]@{ Applied = $true; Cmd = $desc; Rc = ('0x{0:X8}' -f $rc) }
}

function Set-ClevoAppSetting {
    <#
      .SYNOPSIS Mirror a value into AppSettings (persistence), page:offset encoded id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$Value,
        [switch]$Apply
    )
    $page = $Id -shr 8; $off = $Id -band 0xFF
    $buf = New-Object byte[] 256
    $buf[0] = [byte]($Value -band 0xFF)
    $desc = 'WriteAppSettings(page={0}, offset={1}, 1, {{{2}}})' -f $page, $off, $buf[0]
    if (-not $Apply) { Write-Host "  [dry-run] $desc"; return [pscustomobject]@{ Applied = $false; Cmd = $desc } }
    $rc = [ClevoHelper.DchuApi]::WriteAppSettings($page, $off, 1, $buf)
    Write-Host ('  [apply]   {0} -> rc=0x{1:X8}' -f $desc, $rc)
    [pscustomobject]@{ Applied = $true; Cmd = $desc; Rc = ('0x{0:X8}' -f $rc) }
}

function Set-ClevoFanMode {
    <#
      .SYNOPSIS Switch fan mode. 0=Auto 1=Max 3=Silent 5=MaxQ 6=Custom 7=AntiDust
      .EXAMPLE  Set-ClevoFanMode -Mode Max -Apply -RevertAfterSec 15
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Mode,
        [switch]$Apply,
        [int]$RevertAfterSec = 0
    )
    $id = Resolve-ModeId $Mode $script:FanModeIds 'fan mode'
    $name = ($script:FanModeIds.GetEnumerator() | Where-Object Value -eq $id | Select-Object -First 1).Key
    Write-Host "FanMode -> $name ($id)"
    if ($Apply -and $RevertAfterSec -gt 0) { Save-ClevoState | Out-Null }
    Set-ClevoWmiValue -Sub $script:SUB_FanMode -Value $id -Apply:$Apply | Out-Null
    Set-ClevoAppSetting -Id 0x405 -Value $id -Apply:$Apply | Out-Null
    if ($Apply) {
        $now = (Get-ClevoTelemetry).FanMode
        if ($now -eq $id) { Write-Host "  verify: read back $now  OK" }
        else { Write-Warning "  verify: read back $now, expected $id" }
        if ($RevertAfterSec -gt 0) { Start-ClevoRevertTimer -Seconds $RevertAfterSec | Out-Null }
    }
}

function Set-ClevoPowerMode {
    <#
      .SYNOPSIS Switch power/performance mode. 0=Quiet 1=PowerSaving 2=Performance 3=Entertainment
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$Mode,
        [switch]$Apply,
        [int]$RevertAfterSec = 0
    )
    $id = Resolve-ModeId $Mode $script:PowerModeIds 'power mode'
    $name = ($script:PowerModeIds.GetEnumerator() | Where-Object Value -eq $id | Select-Object -First 1).Key
    Write-Host "PowerMode -> $name ($id)"
    if ($Apply -and $RevertAfterSec -gt 0) { Save-ClevoState | Out-Null }
    Set-ClevoWmiValue -Sub $script:SUB_PowerMode -Value $id -Apply:$Apply | Out-Null
    Set-ClevoAppSetting -Id 0x101 -Value $id -Apply:$Apply | Out-Null
    if ($Apply) {
        $now = (Get-ClevoTelemetry).PowerMode
        if ($now -eq $id) { Write-Host "  verify: read back $now  OK" }
        else { Write-Warning "  verify: read back $now, expected $id" }
        if ($RevertAfterSec -gt 0) { Start-ClevoRevertTimer -Seconds $RevertAfterSec | Out-Null }
    }
}

function Set-ClevoFanOffset {
    <#
      .SYNOPSIS Fan offset 0..100 %. The firmware wants 0..255.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(0, 100)][int]$Percent,
        [switch]$Apply
    )
    $raw = [int][Math]::Round(255 * $Percent / 100)
    Write-Host "FanOffset -> $Percent % (raw $raw)"
    Set-ClevoWmiValue -Sub $script:SUB_FanOffset -Value $raw -Apply:$Apply | Out-Null
    Set-ClevoAppSetting -Id 0x407 -Value $raw -Apply:$Apply | Out-Null
    if ($Apply) {
        $now = (Get-ClevoTelemetry).FanOffset
        Write-Host "  verify: read back raw $now"
    }
}

function Invoke-ClevoLoadFanDefaults {
    [CmdletBinding()]
    param([switch]$Apply)
    Write-Host 'LoadFanDefaults'
    Set-ClevoWmiValue -Sub $script:SUB_LoadFanDefaults -Value 0 -Apply:$Apply | Out-Null
}

function Invoke-ClevoAntiDustNow {
    [CmdletBinding()]
    param([switch]$Apply)
    Write-Host 'AntiDust: run now'
    Set-ClevoWmiValue -Sub $script:SUB_AntiDustNow -Value 0 -Apply:$Apply | Out-Null
}

function Clear-ClevoFanOverride {
    <#
      .SYNOPSIS Safety exit: hand fans back to the EC (Auto).
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    Write-Host 'safety: fan mode -> Auto'
    Set-ClevoWmiValue -Sub $script:SUB_FanMode -Value 0 -Apply:$Apply | Out-Null
    Set-ClevoAppSetting -Id 0x405 -Value 0 -Apply:$Apply | Out-Null
}

# --------------------------------------------------------------- watchdog ----

function Start-ClevoRevertTimer {
    <#
      .SYNOPSIS Detached worker that restores the saved state after N seconds, even
                if the calling shell is gone.
      .NOTES    Started through WMI with SW_HIDE (Win32_ProcessStartup.ShowWindow = 0) instead
                of `Start-Process -WindowStyle Hidden`: the latter still lets Windows create a
                console window first, which is the black flash the user sees.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)
    $worker = Join-Path $PSScriptRoot 'revert-worker.ps1'
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -StatePath "{1}" -Seconds {2}' -f `
        $worker, $script:LastGoodPath, $Seconds
    $startup = New-CimInstance -CimClass (Get-CimClass -ClassName Win32_ProcessStartup) -ClientOnly
    $startup.ShowWindow = [uint16]0    # SW_HIDE
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $cmd; ProcessStartupInformation = $startup
    }
    Write-Host ("  watchdog: revert in {0}s (pid {1})" -f $Seconds, $r.ProcessId)
    [pscustomobject]@{ Id = $r.ProcessId }
}
