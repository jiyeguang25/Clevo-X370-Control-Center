# fancurve.ps1 - ClevoHelper custom fan curve layer (MILESTONE 3)
#
# Curve model (verified against live telemetry on this machine):
#   each fan has 4 points  T1/D1 .. T4/D4
#     T = degrees C, D = duty in PERCENT
#   only T2/D2 and T3/D3 are writable; T1/D1 come from the firmware table and
#   T4/D4 are fixed at 100C / 100%.
#
# Two representations of the same curve:
#   DCHU block 13 (EEVT, firmware -> host)  : duty RAW 0-255
#   AppSettings page 4 and DCHU block 14     : duty PERCENT 0-100
#   slope R12 = round(((D2-D1)/(T2-T1)) * 2.55 * 16)   <- verified numerically
#
# Write path: SetDCHU_Data(14, frame256, 256) then fan mode 6 (Custom).
#   frame[0x02..0x0D] = T2,D2,T3,D3 for CPU / GPU1 / GPU2   (percent)
#   frame[0x0E..0x1F] = R12,R23,R34 per fan, HIGH byte then LOW byte
#
# SAFETY: dry-run default. Clamps: monotonic temps and duties, duty floor,
# a forced 100%/100C top point, and a watchdog that returns the fans to Auto.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

$script:FanNames = @('CPU', 'GPU1', 'GPU2')
$script:MinDutyPct = 20        # PERCENT. The EC's first point is fixed at 28% (71 raw).
$script:MaxTempForMinDuty = 45  # below this the EC is allowed to idle the fan
# UNITS: every duty in this file is PERCENT (0-100), matching the vendor's FanArgs.D2/D3.
# The block-14 frame wants RAW 0-255, and the vendor converts with round(pct/100*255) in
# FAN.Write_WMI14 - New-FanCurveFrame does the same. Keeping percent here also fixes the
# slope formula: the captured baseline slopes (25/27/139 for 28%/41%/59% at 40/61/88) only
# come out right when the 2.55 factor is applied to percent, not to raw values.
$script:MinDuty = 51           # raw equivalent of 20%, still used by fanctl.ps1 callers

function Get-FanCurve {
    <#
      .SYNOPSIS Decode the live curve: raw table from block 13, percent table from page 4.
    #>
    [CmdletBinding()]
    param()
    $b13 = (Get-WmiPackage 13).Bytes
    $p4 = (Get-AppSettingPage 4).Bytes

    $fans = @()
    for ($f = 0; $f -lt 3; $f++) {
        # WARNING - the page-4 offsets below are an ASSUMPTION that has not been verified
        # byte-exactly (duties at +0..+2, temps at +6..+8 per bank of 0x12). Measured
        # evidence says the temps may sit one byte earlier: after a page-4 write the EC
        # reloaded its runtime table as T2 = T1+1, T3 = T2 (`40,41,61` for a requested
        # `40,61,88`), which is exactly what a one-byte-shifted read produces.
        # Nothing writes page 4 any more for that reason; treat this as display-only, and
        # trust block 13 (Get-FanRuntimeCurve, verified exact) as the source of truth.
        $o = 0x10 + $f * 0x12
        $fans += [pscustomobject]@{
            Fan  = $script:FanNames[$f]
            T1   = [int]$p4[$o + 6]
            T2   = [int]$p4[$o + 7]
            T3   = [int]$p4[$o + 8]
            T4   = 100
            D1   = [int]$p4[$o + 0]
            D2   = [int]$p4[$o + 1]
            D3   = [int]$p4[$o + 2]
            D4   = 100
            T2d  = [int]$p4[$o + 10]
            T3d  = [int]$p4[$o + 11]
            R12  = [int]$p4[$o + 12] -bor ([int]$p4[$o + 13] -shl 8)
            R23  = [int]$p4[$o + 14] -bor ([int]$p4[$o + 15] -shl 8)
            R34  = [int]$p4[$o + 16] -bor ([int]$p4[$o + 17] -shl 8)
            RawD2 = [int]$b13[16 + $f * 8 + 1]
            RawD3 = [int]$b13[16 + $f * 8 + 3]
        }
    }
    [pscustomobject]@{
        FanCount    = [int]$b13[12]
        InitFanMode = [int]$b13[14]
        ActiveMode  = [int]$p4[5]
        Fans        = $fans
    }
}

function Get-FanSlope {
    <#
      .SYNOPSIS R = round(((Dhi - Dlo) / (Thi - Tlo)) * 2.55 * 16), the factory formula.
    #>
    param([Parameter(Mandatory)]$Fan, [int]$Lo = 1, [int]$Hi = 2)
    $tLo = $Fan."T$Lo"; $tHi = $Fan."T$Hi"
    if ($tHi -le $tLo) { return 0 }
    [int][Math]::Round((($Fan."D$Hi" - $Fan."D$Lo") / [double]($tHi - $tLo)) * 2.55 * 16)
}

function Test-FanCurve {
    <#
      .SYNOPSIS Clamp and sanity-check a proposed curve. Returns the clamped fan set.
      .NOTES    Duties are PERCENT here (the frame builder converts). Rules:
                20 <= T1 < T2 < T3 < T4=100 ; duties monotonic ; D4 = 100 ;
                every duty >= $script:MinDutyPct.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fans, [int]$MinDuty = $script:MinDutyPct)
    $out = @()
    foreach ($f in $Fans) {
        # unused fan slot (this machine reports 2): keep it all-zero, never clamp it up
        if ([int]$f.T1 -eq 0 -and [int]$f.T2 -eq 0 -and [int]$f.T3 -eq 0 -and
            [int]$f.D1 -eq 0 -and [int]$f.D2 -le 1 -and [int]$f.D3 -le 2) {
            $out += [pscustomobject]@{ Fan = $f.Fan; T1 = 0; T2 = 0; T3 = 0; T4 = 0; D1 = 0; D2 = 0; D3 = 0; D4 = 0 }
            continue
        }
        $t1 = [Math]::Max(0, [Math]::Min(60, [int]$f.T1))
        $t2 = [Math]::Max($t1 + 1, [int]$f.T2)
        $t3 = [Math]::Max($t2 + 1, [int]$f.T3)
        if ($t3 -gt 99) { $t3 = 99; $t2 = [Math]::Min($t2, 98) }
        $d1 = [Math]::Max($MinDuty, [Math]::Min(100, [int]$f.D1))
        $d2 = [Math]::Max($d1, [Math]::Min(100, [int]$f.D2))
        $d3 = [Math]::Max($d2, [Math]::Min(100, [int]$f.D3))
        $out += [pscustomobject]@{
            Fan = $f.Fan; T1 = $t1; T2 = $t2; T3 = $t3; T4 = 100
            D1 = $d1; D2 = $d2; D3 = $d3; D4 = 100
        }
    }
    $out
}

function New-FanCurveFrame {
    <#
      .SYNOPSIS Build the 256-byte block-14 (FEVT) frame. Duties are PERCENT.
      .NOTES    Layout and the percent->raw conversion are byte-identical to the vendor's
                own FAN.Write_WMI14: buf[2]=T2, buf[3]=round(D2/100*255), buf[4]=T3,
                buf[5]=round(D3/100*255), same again at 6..9 for GPU1 and 10..13 for GPU2,
                then the slopes. T1/D1 and T4/D4 are NOT in the frame - the EC keeps its own
                (40C/28% and 100C/100%), which is why this table has 4 nodes of which only
                the middle two are adjustable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fans)
    $buf = New-Object byte[] 256
    for ($f = 0; $f -lt 3; $f++) {
        $o = 0x02 + $f * 4
        $buf[$o + 0] = [byte]$Fans[$f].T2
        $buf[$o + 1] = [byte][Math]::Round($Fans[$f].D2 * 255 / 100)
        $buf[$o + 2] = [byte]$Fans[$f].T3
        $buf[$o + 3] = [byte][Math]::Round($Fans[$f].D3 * 255 / 100)
    }
    for ($f = 0; $f -lt 3; $f++) {
        $o = 0x0E + $f * 6
        $r12 = Get-FanSlope $Fans[$f] 1 2
        $r23 = Get-FanSlope $Fans[$f] 2 3
        $r34 = Get-FanSlope $Fans[$f] 3 4
        # NOTE: this path stores the HIGH byte first (the AppSettings path stores low first).
        $buf[$o + 0] = [byte](($r12 -shr 8) -band 0xFF); $buf[$o + 1] = [byte]($r12 -band 0xFF)
        $buf[$o + 2] = [byte](($r23 -shr 8) -band 0xFF); $buf[$o + 3] = [byte]($r23 -band 0xFF)
        $buf[$o + 4] = [byte](($r34 -shr 8) -band 0xFF); $buf[$o + 5] = [byte]($r34 -band 0xFF)
    }
    $buf
}

function Convert-DutyPctToRawLocal([int]$Pct) {
    # kept only for callers that dot-source fancurve.ps1 alone; the real one lives in
    # dchu.ps1 so the UI thread has it too
    Convert-DutyPctToRaw $Pct
}

function Write-FanCurve {
    <#
      .SYNOPSIS Send the curve via block 14, then switch the fan mode to Custom.
                DRY RUN unless -Apply.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Frame, [switch]$Apply, [switch]$SkipModeSwitch)
    if (-not $Apply) {
        Write-Host '  [dry-run] SetDCHU_DataEx(14, <256 B frame>, 256)'
        Write-Host ('    [02..0D] ' + (($Frame[0x02..0x0D] | ForEach-Object { $_.ToString('X2') }) -join ' '))
        Write-Host ('    [0E..1F] ' + (($Frame[0x0E..0x1F] | ForEach-Object { $_.ToString('X2') }) -join ' '))
        return
    }
    # MUST be SetDCHU_DataEx: plain SetDCHU_Data(14,...) is rejected with rc=0x14,
    # while DataEx returns 0x0E (command echo = success).
    # The 4th parameter is the native side's OUTPUT BUFFER (a byte*), so it has to be a
    # 256-byte array - passing `[ref]$someSingleByte` throws "Cannot convert PSReference[Byte]
    # to System.Byte[]" and silently killed EVERY curve write. See the same fix in
    # Write-FanFrame and in ClevoHelper.ps1's 'curve' handler.
    $outBuf = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(14, $Frame, 256, $outBuf)
    Write-Host ('  [apply] SetDCHU_DataEx(14, frame, 256) -> rc=0x{0:X8} (0x0E = ok)' -f $rc)
    if ($rc -ne 14) { throw ('block-14 write rejected, rc=0x{0:X}' -f $rc) }
    if (-not $SkipModeSwitch) {
        $b = New-Object byte[] 256; $b[0] = 6
        [void][ClevoHelper.DchuApi]::SetDCHU_Data(121, [byte[]]@(6, 0, 0, 1), 4)
        [void][ClevoHelper.DchuApi]::WriteAppSettings(4, 5, 1, $b)
        Write-Host '  [apply] fan mode -> Custom (6)'
    }
}

function Get-FanCurveFromStock {
    <#
      .SYNOPSIS The clamped copy of the curve currently active (safe no-op source).
    #>
    [CmdletBinding()]
    param()
    $c = Get-FanCurve
    Test-FanCurve -Fans $c.Fans -MinDuty 0
}

function Set-AppSettingByte {
    <#
      .SYNOPSIS Patch individual bytes of an AppSetting page with a READ-MODIFY-WRITE.
      .NOTES NEVER write a partially filled 256-byte page: WriteAppSettings replaces
             the whole page, so anything left at zero is destroyed. I wiped the fan
             table's slope fields and the GPU1/GPU2 entries exactly that way once and
             had to restore the page byte-for-byte from a captured dump.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Page,
        [Parameter(Mandatory)][hashtable]$Patch,   # offset -> value
        [switch]$Apply
    )
    $buf = (Get-AppSettingPage $Page).Bytes      # start from what is really there
    $desc = @()
    foreach ($k in ($Patch.Keys | Sort-Object)) {
        $off = [int]$k
        $buf[$off] = [byte]([int]$Patch[$k] -band 0xFF)
        $desc += ('[{0:X2}]={1:X2}' -f $off, $buf[$off])
    }
    if (-not $Apply) { Write-Host ('  [dry-run] WriteAppSettings(page={0}, 0, 256) patch {1}' -f $Page, ($desc -join ' ')); return }
    $rc = [ClevoHelper.DchuApi]::WriteAppSettings($Page, 0, 256, $buf)
    Write-Host ('  [apply] WriteAppSettings(page={0}, 0, 256) patch {1} -> rc=0x{2:X8}' -f $Page, ($desc -join ' '), $rc)
}

function Write-FanCurveAndPersist {
    <#
      .SYNOPSIS Push a curve to the EC (block 14) and select Custom mode.
      .NOTES    It deliberately does NOT rewrite AppSettings page 4 any more.
                The vendor's own fan app (FanSpeedSetting.exe ->
                Interface_FanTable.WriteEC_Fan1_Fan2_table) saves a curve with a SINGLE call
                to the EC - SetWMIPackageEx(4, frame) with frame[0]=41 and 112-byte per-fan
                records at [16]/[128] - and never writes page 4. Our old full-page mirror
                did, and writing page 4 makes the EC reload its runtime table through a
                page-4 layout this project has never verified: measured outcome was
                T2 = T1+1 and T3 = T2 (read back `40,41,61` instead of `40,61,88`), i.e. the
                fans silently followed a curve nobody asked for.
                If the page-4 layout is ever pinned down byte-exactly, persistence can be
                added back here behind a switch - not before.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fans, [switch]$Apply)
    $frame = New-FanCurveFrame $Fans
    Write-FanCurve $frame -Apply:$Apply
}

function Get-FanCurveDutyAt {
    <#
      .SYNOPSIS Expected duty (%) for a fan at a given temperature, from a page-4 curve.
      .NOTES    Linear between points; T1/D1 below T1; clamp to D4 above T3.
                Used to sanity-check the EC against the persisted curve.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fan, [Parameter(Mandatory)][double]$Temp)
    $t1 = [double]$Fan.T1; $t2 = [double]$Fan.T2; $t3 = [double]$Fan.T3
    $d1 = [double]$Fan.D1; $d2 = [double]$Fan.D2; $d3 = [double]$Fan.D3; $d4 = [double]$Fan.D4
    if ($Temp -le $t1) { return $d1 }
    if ($Temp -le $t2) { if ($t2 -eq $t1) { return $d2 } return $d1 + ($Temp - $t1) * ($d2 - $d1) / ($t2 - $t1) }
    if ($Temp -le $t3) { if ($t3 -eq $t2) { return $d3 } return $d2 + ($Temp - $t2) * ($d3 - $d2) / ($t3 - $t2) }
    if ($t3 -ge 100) { return $d4 }
    $v = $d3 + ($Temp - $t3) * ($d4 - $d3) / (100 - $t3)
    if ($v -gt 100) { return 100 }
    return $v
}

function Get-FanRuntimeCurve {
    <#
      .SYNOPSIS Decode block 13 (EEVT) - the RUNTIME table the EC is actually executing.
      .NOTES    Raw 0-255 duties; this is the verification reference for a curve write.
    #>
    [CmdletBinding()]
    param()
    $b = (Get-WmiPackage 13).Bytes
    $out = @()
    foreach ($f in 0, 1, 2) {
        $o = 16 + $f * 8
        $out += [pscustomobject]@{
            Fan = $script:FanNames[$f]
            T1 = [int]$b[$o];     T2 = [int]$b[$o + 2]; T3 = [int]$b[$o + 4]; T4 = [int]$b[$o + 6]
            D1 = [int]$b[$o + 1]; D2 = [int]$b[$o + 3]; D3 = [int]$b[$o + 5]; D4 = [int]$b[$o + 7]
            P1 = [int][Math]::Round(100 * $b[$o + 1] / 255); P2 = [int][Math]::Round(100 * $b[$o + 3] / 255)
            P3 = [int][Math]::Round(100 * $b[$o + 5] / 255); P4 = [int][Math]::Round(100 * $b[$o + 7] / 255)
        }
    }
    $out
}

function Write-FanFrame {
    <#
      .SYNOPSIS Write a raw block-14 frame and verify by reading block 13 back.
      .OUTPUTS $true when the firmware's runtime table matches what we sent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Frame, [int]$ExpectT2, [int]$ExpectD2, [int]$ExpectT3, [int]$ExpectD3, [switch]$Apply)
    if (-not $Apply) { Write-Host '  [dry-run] SetDCHU_DataEx(14, frame, 256)'; return $false }
    $outBuf = New-Object byte[] 256   # native OUTPUT BUFFER - must be an array, not [ref][byte]
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(14, $Frame, 256, $outBuf)
    if ($rc -ne 14) { throw ('block-14 write rejected, rc=0x{0:X}' -f $rc) }
    Start-Sleep -Milliseconds 400
    $rt = (Get-FanRuntimeCurve)[0]
    $ok = ($rt.T2 -eq $ExpectT2) -and ($rt.D2 -eq $ExpectD2) -and ($rt.T3 -eq $ExpectT3) -and ($rt.D3 -eq $ExpectD3)
    Write-Host ('  readback fan0: T={0},{1},{2},{3}  D={4},{5},{6},{7}  -> {8}' -f `
        $rt.T1, $rt.T2, $rt.T3, $rt.T4, $rt.D1, $rt.D2, $rt.D3, $rt.D4, $(if ($ok) { 'MATCH' } else { 'MISMATCH' }))
    $ok
}

function Restore-FanBaselineTable {
    <#
      .SYNOPSIS Put the captured baseline runtime fan table back.
      .NOTES    This is NOT a factory curve. It is the curve that was already in the EC when
                this project first read it - i.e. the one the user had dialled in with the
                factory Control Center (which is why T2=61 / T3=88 are not multiples of 5).
                T = 40/61/88/100 ; duties 28%/41%/59%/100% -> raw 71/105/150/255 ;
                slopes 25/27/139 (percent-based, matching the vendor's own formula).
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    $buf = New-Object byte[] 256
    foreach ($k in 0, 1) {
        $buf[0x02 + $k * 4] = [byte]61;  $buf[0x03 + $k * 4] = [byte](Convert-DutyPctToRaw 41)
        $buf[0x04 + $k * 4] = [byte]88;  $buf[0x05 + $k * 4] = [byte](Convert-DutyPctToRaw 59)
        $o = 0x0E + $k * 6
        $buf[$o + 0] = 0x00; $buf[$o + 1] = 25
        $buf[$o + 2] = 0x00; $buf[$o + 3] = 27
        $buf[$o + 4] = 0x00; $buf[$o + 5] = 139
    }
    Write-FanFrame -Frame $buf -ExpectT2 61 -ExpectD2 (Convert-DutyPctToRaw 41) `
        -ExpectT3 88 -ExpectD3 (Convert-DutyPctToRaw 59) -Apply:$Apply
}
# the old name claimed these were factory values - they never were
Set-Alias -Name Restore-FanFactoryTable -Value Restore-FanBaselineTable
# ---------------------------------------------------------------------------
# The TRUE original AppSettings page 4 as captured on this machine, byte for byte.
# Length matters: an earlier "restore" of mine used a truncated 64-byte string and
# then verified against that same truncated buffer, so it silently zeroed 0x44
# (GPU2's R34 slope) and reported success. Always compare against THIS.
# ---------------------------------------------------------------------------
$script:Page4Original = [byte[]](
    0x00,0x00,0x00,0x00,0x02,0x06,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x1C,0x29,0x3B,0x64,0x42,0x55,0x28,0x3D,0x58,0x64,0x3C,0x50,0x19,0x00,0x1B,0x00,
    0x8B,0x00,0x1C,0x29,0x3A,0x64,0x42,0x55,0x28,0x3D,0x58,0x64,0x3C,0x50,0x19,0x00,
    0x1A,0x00,0x8F,0x00,0x00,0x01,0x02,0x64,0x01,0x02,0x00,0x00,0x00,0x64,0x00,0x00,
    0x00,0x00,0x00,0x00,0x28,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
)

function Get-FanPage4Diff {
    <#
      .SYNOPSIS Every byte of page 4 that differs from the captured original.
                Treats 0x05 (fan mode) as intentional and reports it separately.
    #>
    [CmdletBinding()]
    param()
    $now = (Get-AppSettingPage 4).Bytes
    $out = @()
    for ($i = 0; $i -lt 256; $i++) {
        $exp = if ($i -lt $script:Page4Original.Length) { $script:Page4Original[$i] } else { 0 }
        if ($now[$i] -ne $exp) { $out += ('0x{0:X2}: original 0x{1:X2} -> now 0x{2:X2}' -f $i, $exp, $now[$i]) }
    }
    $out
}

function Restore-FanPage4 {
    <#
      .SYNOPSIS Write the captured original page 4 back (read-modify-write, full page).
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    $buf = (Get-AppSettingPage 4).Bytes
    [Array]::Copy($script:Page4Original, $buf, $script:Page4Original.Length)
    if (-not $Apply) { Write-Host '  [dry-run] WriteAppSettings(4, 0, 256, <original image>)'; return }
    $rc = [ClevoHelper.DchuApi]::WriteAppSettings(4, 0, 256, $buf)
    $d = Get-FanPage4Diff
    Write-Host ('  [apply] rc=0x{0:X8}; bytes differing from the original: {1}' -f $rc, $d.Count)
    if ($d.Count) { $d | ForEach-Object { Write-Host "    $_" } }
}