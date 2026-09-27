# dchu.ps1 - ClevoHelper DCHU bridge  (MILESTONE 1: READ ONLY)
#
# Factory channel:  InsydeDCHU.dll -> AcpiBridge.sys (ACPI\CLV0001, iface {86994c74-ad43-4812-b7e7-0c420b5c5fd7})
# Same path the factory Control Center uses. No extra driver, no EC poking.
#
# THREE verified access paths (reverse-engineered from FanSpeedSetting.exe IL):
#   1. AppSetting ids (0x405 FanMode ...)  are PAGE:OFFSET encoded  ->  ReadAppSettings(page, offset, len, buf)
#        0x405 -> page 4, offset 5        0x101 -> page 1, offset 1        0x200 -> page 2, offset 0
#      ALWAYS pass a 256-byte buffer. A short buffer faults the process (AccessViolation).
#   2. GetDCHU_Data_Integer(cmd, out int)   - small cmd space (~7..122), feature/support bits
#   3. GetDCHU_Data_Buffer(cmd, buf[256])   - block telemetry
#        12 = fan/thermal telemetry   13 = fan capability   17 = customer id
#
# Usage:  . .\dchu.ps1 ;  Get-AppSetting FanMode ; Get-WmiPackage 12 ; Get-DchuSummary

$ErrorActionPreference = 'Stop'

# DLL search order. The FIRST entry is our own copy: the panel ships with a local
# InsydeDCHU.dll so that deleting/uninstalling the factory Control Center folder cannot
# break it. Only the AcpiBridge *driver* (installed into System32\drivers by the INF) is
# still required - a user-mode DLL cannot be bundled for that.
$script:DchuCandidates = @(
    (Join-Path $PSScriptRoot 'lib\InsydeDCHU.dll'),
    'C:\Program Files (x86)\ControlCenter\DCHU\InsydeDCHU.dll',
    'C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll',
    'C:\WINDOWS\System32\DriverStore\FileRepository\acpibridge1.inf_amd64_cedafa39846f03cf\InsydeDCHU.dll'
)
# The copies differ in their export set. Only some build of the DLL exports
# SetDCHU_DataEx, and the fan-curve path (block 14) NEEDS it - SetDCHU_Data is
# rejected by the firmware for that block (returns 0x14 instead of the command
# echo). Pick a copy that actually has it.
function Test-DchuHasDataEx([string]$Path) {
    try {
        $s = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
        return $s.Contains('SetDCHU_DataEx')
    }
    catch { return $false }
}
$script:DchuDll = $script:DchuCandidates | Where-Object { (Test-Path -LiteralPath $_) -and (Test-DchuHasDataEx $_) } | Select-Object -First 1
if (-not $script:DchuDll) {
    $script:DchuDll = $script:DchuCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $script:DchuDll) { throw 'InsydeDCHU.dll not found - is Control Center installed?' }
$script:DchuHasDataEx = Test-DchuHasDataEx $script:DchuDll

$script:AppSetting = [ordered]@{
    PowerMode               = 0x101
    CameraStatus            = 0x106
    Flexikey_KB             = 0x108
    Flexikey_Mouse          = 0x109
    TouchPadStatus          = 0x10A
    ACPowerMode             = 0x110
    DTTStatus               = 0x120
    FlexiCharger            = 0x12E
    Major                   = 0x200
    Minor                   = 0x201
    Rev                     = 0x202
    KBType                  = 0x204
    KBLanguage              = 0x205
    Effect                  = 0x220
    StaticStatus            = 0x221
    KBSleep                 = 0x222
    KBBrightness            = 0x223
    FanMode                 = 0x405
    FanOffset               = 0x407
    TurboFan_Status         = 0x408
    NoiselessFan_status     = 0x409
    FanMode_Quiet           = 0x446
    FanMode_PowerSaving     = 0x447
    FanMode_Performance     = 0x448
    FanMode_Entertainment   = 0x449
    FanOffset_Quiet         = 0x44A
    FanOffset_PowerSaving   = 0x44B
    FanOffset_Performance   = 0x44C
    FanOffset_Entertainment = 0x44D
    CpuOC_IsSaved           = 0x620
    Xtu_Busy                = 0x6FB
    CpuOC_Init              = 0x6FF
}
$script:AppSettingIdToName = @{}
foreach ($kv in $script:AppSetting.GetEnumerator()) { $script:AppSettingIdToName[[int]$kv.Value] = $kv.Key }

if (-not ('ClevoHelper.DchuApi' -as [type])) {
    $esc = $script:DchuDll.Replace('\', '\\')
    Add-Type -Namespace ClevoHelper -Name DchuApi -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int GetDCHU_Data_Integer(int command, out int data);
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int GetDCHU_Data_Buffer(int command, byte[] buffer);
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int ReadAppSettings(int page, int offset, int length, byte[] buffer);
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int WriteAppSettings(int page, int offset, int length, byte[] buffer);
// WRITE path - only ever called through fanctl.ps1 / fancurve.ps1, gated behind -Apply
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int SetDCHU_Data(int command, byte[] buffer, int length);
// Needed for block 14 (custom fan curve) and for the graphics-mode switch.
// The 4th parameter is an OUTPUT BUFFER, not a single byte. Declaring it as "out byte"
// and passing [ref] to a 1-byte variable lets the native write past it - a latent
// memory-corruption bug. It must be a byte[] so the marshaller hands over the whole array.
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int SetDCHU_DataEx(int command, byte[] buffer, int length, byte[] output);
"@
}

# --- reads -----------------------------------------------------------------

function Get-AppSetting {
    <#
      .SYNOPSIS Read an AppSetting (READ ONLY). Id is name or 0xNNNN (page:offset encoded).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [int]$Length = 4
    )
    $code = -1
    if ($script:AppSetting.Contains($Id)) { $code = [int]$script:AppSetting[$Id] }
    elseif ($Id -match '^\s*(0x[0-9a-fA-F]+|\d+)\s*$') { $code = [Convert]::ToInt32($Id, $(if ($Id -match '0x') { 16 } else { 10 })) }
    else { throw "unknown AppSetting: $Id" }

    $page = $code -shr 8
    $off = $code -band 0xFF
    # 256-byte buffer ALWAYS - the native side touches more than 'length' bytes
    $buf = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::ReadAppSettings($page, $off, $Length, $buf)
    $name = if ($script:AppSettingIdToName.ContainsKey($code)) { $script:AppSettingIdToName[$code] } else { '' }
    [pscustomobject]@{
        Name   = $name
        Id     = ('0x{0:X}' -f $code)
        Page   = $page
        Offset = $off
        Rc     = ('0x{0:X8}' -f $rc)
        Int    = [BitConverter]::ToInt32($buf, 0)
        Bytes  = $buf
    }
}

function Get-AppSettingList {
    [CmdletBinding()]
    param([switch]$ShowBytes)
    foreach ($kv in $script:AppSetting.GetEnumerator()) {
        $r = Get-AppSetting $kv.Value
        if ($ShowBytes) {
            '{0,-24} {1,-8} p{2}/o{3,-4} rc={4} int={5}' -f $r.Name, $r.Id, $r.Page, $r.Offset, $r.Rc, $r.Int
        }
        else {
            '{0,-24} {1,-8} p{2}/o{3,-4} rc={4} int={5}' -f $r.Name, $r.Id, $r.Page, $r.Offset, $r.Rc, $r.Int
        }
    }
}

function Get-DchuInt {
    <#
      .SYNOPSIS GetDCHU_Data_Integer - small command space, feature/support bits.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][int]$Command)
    $v = 0
    $rc = [ClevoHelper.DchuApi]::GetDCHU_Data_Integer($Command, [ref]$v)
    [pscustomobject]@{ Id = ('0x{0:X}' -f $Command); Dec = $Command; Rc = ('0x{0:X8}' -f $rc); Int = $v }
}

function Get-WmiPackage {
    <#
      .SYNOPSIS GetDCHU_Data_Buffer - 256-byte block.  12 = fan/thermal telemetry, 13 = fan caps, 17 = customer id
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][int]$Command)
    $buf = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::GetDCHU_Data_Buffer($Command, $buf)
    [pscustomobject]@{ Command = $Command; Rc = ('0x{0:X8}' -f $rc); Bytes = $buf }
}

function Format-HexDump {
    param([byte[]]$Bytes, [int]$Length = 64)
    for ($i = 0; $i -lt [Math]::Min($Length, $Bytes.Length); $i += 16) {
        $chunk = $Bytes[$i..([Math]::Min($i + 15, $Bytes.Length - 1))]
        '{0:X4}  {1,-47}  {2}' -f $i, (($chunk | ForEach-Object { $_.ToString('X2') }) -join ' '),
            (($chunk | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } }) -join '')
    }
}

# --- decoded telemetry (validated against the factory app's own IL) ---------

function Get-AppSettingPage {
    <#
      .SYNOPSIS Read a whole 256-byte AppSetting page (this is what the vendor app does).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][int]$Page)
    $buf = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::ReadAppSettings($Page, 0, 256, $buf)
    [pscustomobject]@{ Page = $Page; Rc = ('0x{0:X8}' -f $rc); Bytes = $buf }
}

function Convert-ClevoFanRaw {
    # Exact expression taken from FanSpeedSetting.Page_system_monitor.UpdateUI_CPUFan:
    #   Math.Round(60 / (raw * 5.565217391304348E-05) * 2)
    param([int]$Raw)
    if ($Raw -le 0) { return 0 }
    [int][Math]::Round(60.0 / ($Raw * 5.565217391304348E-05) * 2.0)
}

$script:FanModeName = @{
    0 = 'Auto'; 1 = 'Max'; 2 = 'Silent'; 3 = 'Mode3'; 4 = 'Mode4'
    5 = 'MaxQ'; 6 = 'Custom'; 7 = 'AntiDust'; 8 = 'Noiseless'; 9 = 'IFSC'
}
$script:PowerModeName = @{ 0 = 'Quiet'; 1 = 'PowerSaving'; 2 = 'Performance'; 3 = 'Entertainment' }

function Get-ClevoTelemetry {
    <#
      .SYNOPSIS One decoded snapshot of the machine. READ ONLY.
      .DESCRIPTION
        block 12 layout (verified by IL + differential sampling):
          [2..3] cpu rpm raw   [4..5] gpu1 raw   [6..7] gpu2 raw   [36..37] sys raw
          [16] cpu duty (0-255)  [19] gpu1 duty  [22] gpu2 duty
          [18] cpu temp          [21] gpu1 temp  [24] gpu2 temp  [40] sys temp
        AppSetting page 4: [5]=FanMode  [7]=FanOffset  [8]=TurboFan
        AppSetting page 1: [1]=PowerMode  [16]=ACPowerMode
    #>
    [CmdletBinding()]
    param([switch]$NoSettings)

    $b = (Get-WmiPackage 12).Bytes
    # NOTE: PowerShell's -shl on a [byte] overflows *within the byte* (2 -shl 8 == 0).
    # Always widen to [int] first - this exact bug produced a bogus 31250 RPM during bring-up.
    $cpuRaw = ([int]$b[2] * 256) + $b[3]
    $gpuRaw = ([int]$b[4] * 256) + $b[5]
    $gpu2Raw = ([int]$b[6] * 256) + $b[7]
    $sysRaw = ([int]$b[36] * 256) + $b[37]

    $t = [ordered]@{
        CpuTemp    = [int]$b[18]
        GpuTemp    = [int]$b[21]
        Gpu2Temp   = [int]$b[24]
        SysTemp    = [int]$b[40]
        CpuFanRpm  = Convert-ClevoFanRaw $cpuRaw
        GpuFanRpm  = Convert-ClevoFanRaw $gpuRaw
        Gpu2FanRpm = Convert-ClevoFanRaw $gpu2Raw
        SysFanRpm  = Convert-ClevoFanRaw $sysRaw
        CpuFanDuty = [int][Math]::Round($b[16] * 100 / 255)
        GpuFanDuty = [int][Math]::Round($b[19] * 100 / 255)
        Gpu2FanDuty = [int][Math]::Round($b[22] * 100 / 255)
        CpuRaw     = $cpuRaw
        GpuRaw     = $gpuRaw
    }
    if (-not $NoSettings) {
        $p4 = (Get-AppSettingPage 4).Bytes
        $p1 = (Get-AppSettingPage 1).Bytes
        $fm = [int]$p4[5]
        $pm = [int]$p1[1]
        $t.FanMode = $fm
        $t.FanModeName = if ($script:FanModeName.ContainsKey($fm)) { $script:FanModeName[$fm] } else { "Mode $fm" }
        $t.FanOffset = [int]$p4[7]
        $t.TurboFan = [int]$p4[8]
        $t.PowerMode = $pm
        $t.PowerModeName = if ($script:PowerModeName.ContainsKey($pm)) { $script:PowerModeName[$pm] } else { "Mode $pm" }
        $t.AcPowerMode = [int]$p1[16]
    }
    [pscustomobject]$t
}

function Get-ClevoFanCurve {
    <#
      .SYNOPSIS Default fan curve from block 13 (duty scaled 0-255 -> %).
      .NOTES Verified monotonic: CPU 40C->28% 61C->41% 88C->59% 100C->100%
    #>
    [CmdletBinding()]
    param()
    $b = (Get-WmiPackage 13).Bytes
    $names = @('CPU', 'GPU1', 'GPU2')
    $out = @()
    for ($f = 0; $f -lt 3; $f++) {
        $o = 16 + $f * 8
        $out += [pscustomobject]@{
            Fan = $names[$f]
            T1 = [int]$b[$o];     D1 = [int][Math]::Round($b[$o + 1] * 100 / 255)
            T2 = [int]$b[$o + 2]; D2 = [int][Math]::Round($b[$o + 3] * 100 / 255)
            T3 = [int]$b[$o + 4]; D3 = [int][Math]::Round($b[$o + 5] * 100 / 255)
            T4 = [int]$b[$o + 6]; D4 = [int][Math]::Round($b[$o + 7] * 100 / 255)
        }
    }
    [pscustomobject]@{
        FanCount     = [int]$b[12]
        InitFanMode  = [int]$b[14]
        Curves       = $out
    }
}

# --------------------------------------------------------------- duties ------
function Convert-DutyPctToRaw([int]$Pct) {
    <#
      .SYNOPSIS Percent -> the EC's raw 0-255 duty, using the vendor's own conversion.
      .NOTES    Exactly what FAN.Write_WMI14 does: Math.Round(D / 100 * 255, 0).
                Lives here (not in fancurve.ps1) because BOTH threads need it: the sampler
                builds frames with it and the UI thread compares block-13 raw values against
                the percent presets. A UI-only call to a sampler-only function silently
                kills the whole paint pass.
    #>
    [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $Pct)) * 255 / 100)
}

# --------------------------------------------------------------- GPU mode ----# Reverse-engineered from ControlCenter30.exe (the shipped CC 3.0 UWP app), i.e. from the
# code behind the very UI the vendor tells users to click:
#
#   Window1.Load_Preference():
#       req[0] = 0x15;  DCHU.SetWMIPackageEx(4, req, out res);
#       res[0] = ACTIVE mode      res[1] = SUPPORTED-mode bitmask
#                                 (bit0 iGPU / bit1 dGPU / bit2 MSHybrid / bit3 Dynamic)
#   Window1.GPUSwitch_new(byte mode):
#       req[0] = 0x16;  req[1] = mode;  DCHU.SetWMIPackageEx(4, req, out res);
#       then the vendor IMMEDIATELY runs `shutdown.exe -f -r -t 0`.
#
# and SetWMIPackageEx(command, buffer, out) is exactly
#       SetDCHU_DataEx(command, buffer, 256, ref out[0])
#
# Two corrections over what this file used to say:
#   1. the frame length is 256, not 24. The EC returns the same rc for both, so the old
#      length was not detectable from the return value.
#   2. there is NO online read-back of a staged change. Measured on this machine: after
#      writing mode 4, then 3, then 9 (invalid), then 0, BOTH res[0] and the AppSetting
#      PreGPU_Mode (page 0 offset 247) kept reading 2, and rc was 0x4 for every value -
#      rc is just the command echo and carries no accept/reject information. The value is
#      consumed by the BIOS at POST, which is why the vendor's flow is "select -> reboot".
#      The earlier "GPU switching is a no-op on this machine" conclusion in README was
#      drawn from diffing AppSettings - i.e. from a channel that never carries this value.
#
# So: the read path is verified, the write frame is byte-identical to the vendor's, and
# the EFFECT of a write can only be observed after a reboot. Nothing here claims more.
$script:GpuModeName = @{
    1 = 'iGPU 核显'
    2 = 'dGPU 独显'
    3 = 'MSHybrid 混合'
    4 = 'Dynamic 动态'
}
# the labels ControlCenter30 puts in its combo box, kept verbatim for cross-checking
$script:GpuModeUiName = @{
    1 = 'Integrated GPU only'
    2 = 'Discrete GPU only'
    3 = 'MSHybrid'
    4 = 'Dynamic'
}

function Get-GpuMode {
    <#
      .SYNOPSIS Read the active graphics mode and the modes the EC says it supports. READ ONLY.
      .NOTES    frame: SetDCHU_DataEx(4, { 0x15, 0 ... }, 256, out)
                out[0] = active mode, out[1] = supported bitmask
    #>
    [CmdletBinding()]
    param()
    $buf = New-Object byte[] 256
    $buf[0] = 0x15
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $buf, 256, $out)
    $m = [int]$out[0]
    $mask = [int]$out[1]
    $sup = @()
    foreach ($bit in 0..3) { if (($mask -shr $bit) -band 1) { $sup += ($bit + 1) } }
    [pscustomobject]@{
        Mode      = $m
        ModeName  = if ($script:GpuModeName.ContainsKey($m)) { $script:GpuModeName[$m] } else { "未知($m)" }
        Mask      = $mask
        Supported = $sup
        Persisted = [int](Get-AppSettingPage 0).Bytes[247]
        Rc        = ('0x{0:X8}' -f $rc)
        Raw       = @($out[0..7])
    }
}

function Set-GpuMode {
    <#
      .SYNOPSIS Stage a graphics-mode change. It takes effect at the NEXT BOOT.
      .NOTES    frame: SetDCHU_DataEx(4, { 0x16, mode, 0 ... }, 256, out) - byte-identical
                to ControlCenter30.Window1.GPUSwitch_new(byte).
                We deliberately do NOT reboot (the vendor does, force-reboot -t 0), so the
                choice can still be re-staged before the user restarts.
                Read back both channels, but do NOT present them as verification: they
                report the ACTIVE mode, which by design does not move until POST.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(1, 4)][int]$Mode,
        [switch]$Apply,
        [int[]]$Supported = @()
    )
    if ($Supported.Count -and ($Supported -notcontains $Mode)) {
        throw ('EC 报告不支持模式 {0}（支持：{1}）' -f $Mode, ($Supported -join ','))
    }
    $before = Get-GpuMode
    if (-not $Apply) {
        Write-Host ('  [dry-run] SetDCHU_DataEx(4, {{ 0x16, {0}, 0 ... }}, 256)   [{1}]' -f $Mode, $script:GpuModeName[$Mode])
        return [pscustomobject]@{ Applied = $false; Mode = $Mode; BeforeActive = $before.Mode }
    }

    $buf = New-Object byte[] 256
    $buf[0] = 0x16
    $buf[1] = [byte]$Mode
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $buf, 256, $out)

    Start-Sleep -Milliseconds 400
    $after = Get-GpuMode
    [pscustomobject]@{
        Applied      = $true
        Mode         = $Mode
        ModeName     = $script:GpuModeName[$Mode]
        Rc           = ('0x{0:X8}' -f $rc)
        BeforeActive = $before.Mode
        AfterActive  = $after.Mode
        StillActive  = ($after.Mode -eq $before.Mode)
        Note         = '重启后生效；在线读回只能看到“当前生效模式”，原厂 CC 同样不校验，写完直接强制重启'
    }
}

# ------------------------------------------------- FlexiCharger (电池充电) ---
# Vendor code: ControlCenter30.Window1.SetFlexiCharger() / Load_Preference()
#   write : SetWMIPackageEx(4, { 0x1F, enable, start%, stop% }, out)
#   read  : SetWMIPackageEx(4, { 0x1E, ... }, out)
#             out[0]      = enable (0 = the vendor's 最大电池电量, i.e. no charge limit)
#             out[1]      = current start%      out[2] = current stop%
#             out[16..31] = the start values the EC accepts (0 = end of list)
#             out[32..47] = the stop  values the EC accepts
#   Load_Preference() fills both combo boxes from those two ranges, so the legal choices come
#   from the firmware - this file never invents a threshold. Measured on this machine:
#   start {40,50,60,70,80,95}, stop {60,70,80,90,100}, current 1/70/80 (= the vendor's 推荐).
$script:FlexiChargerReadCmd = 0x1E
$script:FlexiChargerWriteCmd = 0x1F

function Invoke-DchuCmd4([byte]$Sub, [byte[]]$Params = @(), [int]$Len = 4) {
    <#
      .SYNOPSIS The vendor's SetWMIPackageEx(4, frame, out) in one place.
      .NOTES    frame[0] = sub-command, frame[1..] = parameters. Returns the raw response so
                callers can read a value back instead of trusting the return code.
    #>
    $buf = New-Object byte[] 256
    $buf[0] = $Sub
    for ($i = 0; $i -lt $Params.Count; $i++) { $buf[$i + 1] = [byte]$Params[$i] }
    $out = New-Object byte[] 256
    $rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $buf, 256, $out)
    [pscustomobject]@{ Rc = $rc; Out = $out; Frame = @($buf[0..($Len - 1)]) }
}

function Get-FlexiCharger {
    <#
      .SYNOPSIS Current charge-limit state + the thresholds the EC accepts. READ ONLY.
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-DchuCmd4 -Sub $script:FlexiChargerReadCmd
    $starts = @(); for ($i = 16; $i -le 31; $i++) { if ($r.Out[$i] -ne 0) { $starts += [int]$r.Out[$i] } }
    $stops = @(); for ($i = 32; $i -le 47; $i++) { if ($r.Out[$i] -ne 0) { $stops += [int]$r.Out[$i] } }
    [pscustomobject]@{
        Enabled      = ([int]$r.Out[0] -ne 0)
        Start        = [int]$r.Out[1]
        Stop         = [int]$r.Out[2]
        StartOptions = $starts
        StopOptions  = $stops
        Rc           = ('0x{0:X8}' -f $r.Rc)
        Raw          = @($r.Out[0..3])
    }
}

function Set-FlexiCharger {
    <#
      .SYNOPSIS Set the battery charge limit. Byte-identical to the vendor's frame.
      .NOTES    -Enabled:$false is the vendor's 最大电池电量 (charge to 100%, no limit).
                Thresholds are refused unless the EC itself offered them, and the state
                is read back through cmd 4 sub 0x1E afterwards - that read is the
                verification, not the return code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [int]$Start = 0,
        [int]$Stop = 0,
        [switch]$Apply
    )
    $before = Get-FlexiCharger
    if ($Enabled) {
        if ($Start -le 0 -or $Stop -le 0) { throw '启用充电限制时必须给出起止阈值' }
        if ($before.StartOptions.Count -and $before.StartOptions -notcontains $Start) {
            throw ('EC 不接受起始电量 {0}%（可选：{1}）' -f $Start, ($before.StartOptions -join ','))
        }
        if ($before.StopOptions.Count -and $before.StopOptions -notcontains $Stop) {
            throw ('EC 不接受停止电量 {0}%（可选：{1}）' -f $Stop, ($before.StopOptions -join ','))
        }
        if ($Start -ge $Stop) { throw ('起始电量必须小于停止电量（{0} >= {1}）' -f $Start, $Stop) }
    }
    else {
        # the vendor still sends the last thresholds; keep the EC's current ones so the
        # frame carries no invented number
        $Start = $before.Start
        $Stop = $before.Stop
    }
    if (-not $Apply) {
        Write-Host ('  [dry-run] SetDCHU_DataEx(4, {{ 0x1F, {0}, {1}, {2} }})' -f [int]$Enabled, $Start, $Stop)
        return [pscustomobject]@{ Applied = $false; Before = $before }
    }
    $r = Invoke-DchuCmd4 -Sub $script:FlexiChargerWriteCmd -Params @([byte][int]$Enabled, [byte]$Start, [byte]$Stop)
    Start-Sleep -Milliseconds 300
    $after = Get-FlexiCharger
    $ok = ($after.Enabled -eq $Enabled) -and
          (-not $Enabled -or ($after.Start -eq $Start -and $after.Stop -eq $Stop))
    [pscustomobject]@{
        Applied = $true
        Ok      = $ok
        Rc      = ('0x{0:X8}' -f $r.Rc)
        Before  = ('{0} {1}-{2}%' -f $(if ($before.Enabled) { '限制' } else { '不限制' }), $before.Start, $before.Stop)
        After   = ('{0} {1}-{2}%' -f $(if ($after.Enabled) { '限制' } else { '不限制' }), $after.Start, $after.Stop)
        Note    = 'AppSetting FlexiCharger(0x12E) 是原厂自己的副本，本次不写：读回走 EC 的 0x1E'
    }
}

# --------------------------------------------- 键盘设置 (Win 键 / FnLock) ---
# Vendor code: ControlCenter30.Window1.SetKeyboardSetting()
#   frame : SetWMIPackageEx(4, { 0x19, fnLock, winKey, winFnSwap }, out)
#   mirror: WriteAppSettings(1, 0x24, 3, { fnLock, winKey, winFnSwap })
# The AppSetting names come from the FnKey module's own enum:
#   FnLock = 0x124, WinKey_Enable = 0x125, WinFnkeySwitch = 0x126
# VALUES ARE 1/2, NOT 0/1: 1 = 开/启用, 2 = 关/禁用. (Measured now: 2/1/2 = FnLock 关,
# Win 键 启用, Win/Fn 未交换 - which is what the factory UI shows.)
$script:KbSetCmd = 0x19
$script:KbSetMirrorOff = 0x24      # page 1, 3 bytes: FnLock, WinKey_Enable, WinFnkeySwitch
$script:OnOffOn = 1                # 1 = on/enabled / not swapped
$script:OnOffOff = 2               # 2 = off/disabled / swapped

function Get-KeyboardSetting {
    <#
      .SYNOPSIS Read the three keyboard switches from their persisted mirror (READ ONLY).
      .NOTES    There is no read command for 0x19, so the vendor's own mirror is the only
                read-back - and it is the same byte the factory UI reads on startup.
    #>
    [CmdletBinding()]
    param()
    $b = (Get-AppSettingPage 1).Bytes
    [pscustomobject]@{
        FnLock     = ([int]$b[0x24] -eq $script:OnOffOn)   # F1..F12 act as F-keys without Fn
        WinKey     = ([int]$b[0x25] -eq $script:OnOffOn)   # Win key enabled
        WinFnSwap  = ([int]$b[0x26] -eq $script:OnOffOn)   # Win and Fn positions swapped
        Raw        = @([int]$b[0x24], [int]$b[0x25], [int]$b[0x26])
    }
}

function Set-KeyboardSetting {
    <#
      .SYNOPSIS Write the three keyboard switches in ONE frame, the way the vendor does.
      .NOTES    They share a single command, so this is a read-modify-write over the mirror:
                anything not passed in keeps its current value. Reads the mirror back
                afterwards as the verification.
    #>
    [CmdletBinding()]
    param(
        [Nullable[bool]]$FnLock,
        [Nullable[bool]]$WinKey,
        [Nullable[bool]]$WinFnSwap,
        [switch]$Apply
    )
    $before = Get-KeyboardSetting
    $fn = if ($null -ne $FnLock) { $FnLock } else { $before.FnLock }
    $wk = if ($null -ne $WinKey) { $WinKey } else { $before.WinKey }
    $ws = if ($null -ne $WinFnSwap) { $WinFnSwap } else { $before.WinFnSwap }
    $v = @(
        $(if ($fn) { $script:OnOffOn } else { $script:OnOffOff }),
        $(if ($wk) { $script:OnOffOn } else { $script:OnOffOff }),
        $(if ($ws) { $script:OnOffOn } else { $script:OnOffOff })
    )
    if (-not $Apply) {
        Write-Host ('  [dry-run] SetDCHU_DataEx(4, {{ 0x19, {0} }}) + WriteAppSettings(1, 0x24, 3, {0})' -f ($v -join ','))
        return [pscustomobject]@{ Applied = $false; Before = $before }
    }
    $r = Invoke-DchuCmd4 -Sub $script:KbSetCmd -Params @([byte]$v[0], [byte]$v[1], [byte]$v[2])
    # mirror exactly where the vendor puts it: page 1 offset 0x24, 3 bytes
    if (Get-Command Set-AppSettingByte -ErrorAction SilentlyContinue) {
        Set-AppSettingByte -Page 1 -Patch @{ 0x24 = $v[0]; 0x25 = $v[1]; 0x26 = $v[2] } -Apply | Out-Null
    }
    $after = Get-KeyboardSetting
    $ok = ($after.FnLock -eq $fn) -and ($after.WinKey -eq $wk) -and ($after.WinFnSwap -eq $ws)
    [pscustomobject]@{
        Applied = $true
        Ok      = $ok
        Rc      = ('0x{0:X8}' -f $r.Rc)
        Frame   = ($r.Frame | ForEach-Object { $_.ToString('X2') }) -join ' '
        After   = ('FnLock={0} Win键={1} Win/Fn交换={2}' -f $after.FnLock, $after.WinKey, $after.WinFnSwap)
    }
}