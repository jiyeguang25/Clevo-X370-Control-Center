# kbled.ps1 - ClevoHelper keyboard LED layer (MILESTONE 4)
#
# Transport: internal keyboard lighting is an ITE 829x exposed as HID vendor
# collections (UsagePage 0xFF89, VID_048D PID_8910). The command channel is the
# FEATURE-report collection with usage 0x00CC, length 7 bytes. No driver, no admin.
#
# Protocol triple-confirmed:
#   1. reverse-engineered from the factory app's IL (CC.PerkeyKB / perkey_api)
#   2. measured on this machine (feature report read/write, no-op write-back OK)
#   3. OpenRGB driver + device wiki for this exact VID/PID:
#      https://gitlab.com/OpenRGBDevelopers/OpenRGB-Wiki/-/blob/stable/Device-Documentation/Clevo-Per-Key-Keyboard.md
#      https://gitlab.com/EzyUser/OpenRGB/-/blob/Clevo8910-Keyboard/Controllers/Clevo8910Controller/
#
# Frame layout (always 7 bytes):
#     [0]=0xCC report id   [1]=command   [2..5]=data   [6]=0
#
#     set one key   { CC 01 <keyId> <R> <G> <B> 00 }
#     brightness    { CC 09 <bright 0-10> <speed 0-2> 00 00 00 }
#     turn off      { CC 00 0C 00 00 00 00 }
#     persist       { CC 20 <1=save 0=forget> 00 00 00 00 }
#     effect+colour { CC <effect> <key> <R> <G> <B> 00 }
#     effect random { CC <effect> FF <key> 00 00 00 }
#
# SAFETY: reads free, writes need -Apply.

$ErrorActionPreference = 'Stop'

$script:HidGuid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$script:LedUsagePage = 0xFF89
$script:ClassByte = 0xCC
$script:ReportSize = 7

$script:CmdDirect = 0x01      # set one key colour
$script:CmdAnim   = 0x00      # animation select (d0 = mode id)
$script:CmdBrightSpeed = 0x09
$script:CmdClear  = 0x0C      # d0 for CmdAnim = ClearColor (REQUIRED before per-key writes)
$script:CmdWaveColor  = 0x15
$script:CmdSnakeColor = 0x16
$script:CmdScanColor  = 0x17
$script:CmdRandomColor = 0x18
$script:CmdBios   = 0x20      # persist to EC/BIOS
$script:ColorCustom = 0xAA    # "use the RGB in this frame" slot

# Animation modes: cmd 0x00, d0 = id
$script:LedAnimation = [ordered]@{
    SpectrumCycle = 0x02
    Stop          = 0x03
    RainbowWave   = 0x04
    Random        = 0x09
    Scan          = 0x0A
    Snake         = 0x0B
    Clear         = 0x0C
}

# Colour effects: cmd = id, d0 = 0x00 for random or 0xAA for custom RGB
$script:LedEffect = [ordered]@{
    Direct   = 0x01
    Ripple   = 0x07
    Fade     = 0x08
    Breathe  = 0x0A
    Flashing = 0x0B
}

# ---------------------------------------------------------------- modes -----
# The vendor's per-key mode list, taken from its own module rather than invented:
#   LedKeyboardSetting.exe  ->  CC.PerkeyKB.Set{Breath,Blink,Ripple,Wave,Random,Scan,Snake}*Mode
#   LedKeyboardSetting.exe  ->  CC.Page_LED_Device  RB_PerKey_Effect_* handlers
# Every one of those methods ends in SetLEDStatus(cmd, param, R, G, B), which in our
# transport is the 7-byte frame { CC cmd param R G B 00 } - the same shape New-LedFrame
# builds. Measured examples straight out of the IL:
#   breath colour : SetLEDStatus(10, 170, R,G,B)   -> cmd 0x0A d0 0xAA
#   blink  colour : SetLEDStatus(11, 170, R,G,B)   -> cmd 0x0B d0 0xAA
#   wave   colour : SetLEDStatus(21, 161+dir,...)  -> cmd 0x15 d0 0xA1+dir
#   snake  colour : SetLEDStatus(22, 161+dir,...)  -> cmd 0x16 d0 0xA1+dir
#   scan   2 cols : SetLEDStatus(23, 161,...) then (23,162,...) -> cmd 0x17 d0 0xA1/0xA2
#   random colour : SetLEDStatus(24, 161, R,G,B)   -> cmd 0x18 d0 0xA1
#   ripple        : SetLEDStatus(7, 0, 0,0,0)      -> cmd 0x07 (colour lives in AppSettings)
#   clear         : SetLEDStatus(12, ...)          -> cmd 0x00 d0 0x0C
#
# StatusOff / ColorOff are AppSetting offsets on PAGE 2, straight from
# CC.other_Class.InsydeAcpiProt.WriteAcpi* (WriteAcpiBreathStatus writes 52,
# WriteAcpiBreathColor writes 53..55, ...). They are the vendor's own persisted copy and
# the ONLY software read-back that exists for a mode, so we mirror them and read them back.
# NOTE: offset 0x20 (WriteAcpiMode) is the "Effect" byte. It is what actually STARTS an
# animation: with it left at 0 the keyboard sat on a plain static colour for every mode, and
# writing each mode's own value (static 0, breath 1, blink 2, cycle 3, ripple 5, wave 7,
# scan 8, random 9, snake 10) is what made the animations run. It is written together with
# the rest of the page and read back like every other byte.
$script:LedModes = [ordered]@{
    'off'    = @{ Label = '关闭'; Cmd = 0x00; Param = 0x0C; EffectOff = 0x20; EffectVal = 0 }
    'static' = @{ Label = '静态'; PerKey = $true;                     StatusOff = 0x21; EffectOff = 0x20; EffectVal = 0 }
    'wave'   = @{ Label = '波浪'; Cmd = 0x15; Param = 0xA1; RandomParam = 0x71; Dirs = 8; StatusOff = 0x40; FreezeOff = 0x41; ColorOff = 0x42; EffectOff = 0x20; EffectVal = 7 }
    'breath' = @{ Label = '呼吸'; Cmd = 0x0A; Param = 0xAA; RandomParam = 0x00; StatusOff = 0x34; ColorOff = 0x35; EffectOff = 0x20; EffectVal = 1 }
    'blink'  = @{ Label = '闪烁'; Cmd = 0x0B; Param = 0xAA; RandomParam = 0x00; StatusOff = 0x38; ColorOff = 0x39; EffectOff = 0x20; EffectVal = 2 }
    'ripple' = @{ Label = '涟漪'; Cmd = 0x07; Param = 0x00;           StatusOff = 0x30; ColorOff = 0x31; EffectOff = 0x20; EffectVal = 5 }
    'random' = @{ Label = '随机'; Cmd = 0x18; Param = 0xA1;           StatusOff = 0x4C; ColorOff = 0x4D; EffectOff = 0x20; EffectVal = 9 }
    'scan'   = @{ Label = '扫描'; Cmd = 0x17; Param = 0xA1; Param2 = 0xA2; StatusOff = 0x45; ColorOff = 0x46; Color2Off = 0x49; EffectOff = 0x20; EffectVal = 8 }
    'snake'  = @{ Label = '蛇形'; Cmd = 0x16; Param = 0xA1; RandomParam = 0x71; Dirs = 4; StatusOff = 0x3C; ColorOff = 0x3D; EffectOff = 0x20; EffectVal = 10 }
    # 循环 / 彩虹循环. The per-key module's own SetMode() dispatcher has NO cycle case
    # (its 12 cases are wave/breath/blink/random/scan/ripple/FIAO/snake/Fn), so this is the
    # one entry NOT taken from that module: the frame is the animation-table selector
    # (CmdAnim + 0x02 = SpectrumCycle). It is one of the four modes the panel offers, so it
    # is exercised by the live four-mode test, not just by the IL dump.
    # Per-key has no CycleStatus either, so its only marker is the Effect byte.
    'cycle'  = @{ Label = '循环'; Anim = 0x02; EffectOff = 0x20; EffectVal = 3 }
}
$script:LedPage = 2          # all of the above live on AppSetting page 2
$script:LedSpeedOff = 0x22   # WriteAcpiSpeed
$script:LedBrightOff = 0x23  # WriteAcpiBrightness

# SAFETY: the protocol accepts brightness 0x00-0x0A ONLY. A reverse-engineering
# write-up reports sending 0x32 (=50, the ITE 8291 maximum) left the keyboard
# completely dark until reset. Never raise this ceiling.
$script:MaxBrightness = 0x0A
$script:MaxSpeed = 0x0A
$script:ReportDelayMs = 1     # 1 ms pacing between reports, as keyRGB defaults

# 6 rows x 20 columns, key id = row * 0x20 + column (see Clevo8910Keys.h)
$script:LedKeyIds = @(
    # row 0 (0x00)
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13
    # row 1 (0x20)
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33
    # row 2 (0x40)
    0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x50, 0x51, 0x52, 0x53
    # row 3 (0x60)
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73
    # row 4 (0x80)
    0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91, 0x92, 0x93
    # row 5 (0xA0)
    0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3
)

if (-not ('ClevoHelper.LedNative' -as [type])) {
    Add-Type -Namespace ClevoHelper -Name LedNative -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr templ);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr h);
[DllImport("hid.dll")]
public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
[DllImport("hid.dll")]
public static extern bool HidD_FreePreparsedData(IntPtr pp);
[DllImport("hid.dll")]
public static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
[DllImport("hid.dll")]
public static extern bool HidD_GetFeature(IntPtr h, byte[] report, int len);
[DllImport("hid.dll")]
public static extern bool HidD_SetFeature(IntPtr h, byte[] report, int len);
[DllImport("hid.dll")]
public static extern bool HidD_GetProductString(IntPtr h, byte[] buf, int len);
'@
}

function Get-LedCollection {
    <#
      .SYNOPSIS Enumerate the ITE keyboard lighting HID collections. READ ONLY.
    #>
    [CmdletBinding()]
    param()
    $out = @()
    foreach ($d in (Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'HID\*' })) {
        $parts = $d.PNPDeviceID -split '\\'
        if ($parts.Count -lt 3) { continue }
        $hw = $parts[1].ToLower(); $inst = $parts[2].ToLower()
        $path = '\\?\hid#' + $hw + '#' + $inst + '#' + $script:HidGuid
        $h = [ClevoHelper.LedNative]::CreateFileW($path, [uint32]2147483648, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($h -eq [IntPtr]::new(-1)) { continue }

        $caps = New-Object byte[] 64
        $pp = [IntPtr]::Zero
        $usage = 0; $usagePage = 0; $feat = 0
        if ([ClevoHelper.LedNative]::HidD_GetPreparsedData($h, [ref]$pp)) {
            if ([ClevoHelper.LedNative]::HidP_GetCaps($pp, $caps) -ge 0) {
                $usage = [BitConverter]::ToUInt16($caps, 0)
                $usagePage = [BitConverter]::ToUInt16($caps, 2)
                $feat = [BitConverter]::ToUInt16($caps, 8)
            }
            [void][ClevoHelper.LedNative]::HidD_FreePreparsedData($pp)
        }
        $pb = New-Object byte[] 256
        [void][ClevoHelper.LedNative]::HidD_GetProductString($h, $pb, 256)
        $prod = [Text.Encoding]::Unicode.GetString($pb); $z = $prod.IndexOf([char]0); if ($z -ge 0) { $prod = $prod.Substring(0, $z) }
        [void][ClevoHelper.LedNative]::CloseHandle($h)

        if ($usagePage -eq $script:LedUsagePage -and $prod -like '*ITE*') {
            $out += [pscustomobject]@{
                HwId = $hw; Path = $path; Usage = $usage; UsagePage = $usagePage
                FeatLen = $feat; Product = $prod
                Role = switch ($usage) { 0x00CC { 'cmd' } 0x00CE { 'status' } 0x00CF { 'matrix' } default { 'other' } }
            }
        }
    }
    $out
}

# Cached: enumerating HID collections costs a WMI query plus ~27 device opens.
# Calling it once per LED frame made a full 115-key repaint take minutes.
$script:CmdCollection = $null
function Get-LedCmdCollection {
    if ($null -eq $script:CmdCollection) {
        $script:CmdCollection = Get-LedCollection | Where-Object Role -eq 'cmd' | Select-Object -First 1
        if (-not $script:CmdCollection) { throw 'ITE LED command collection (usage 0xCC) not found' }
    }
    $script:CmdCollection
}

function Get-LedId {
    <#
      .SYNOPSIS LED id encoding, confirmed by OpenRGB: ((row & 7) << 5) | (col & 0x1F)
                rows 0..5 top-to-bottom (row 0 = F-key row), cols 0..19.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(0, 7)][int]$Row, [Parameter(Mandatory)][ValidateRange(0, 31)][int]$Col)
    [byte]((($Row -band 0x07) -shl 5) -bor ($Col -band 0x1F))
}

function Open-LedDevice {
    param([Parameter(Mandatory)]$Collection, [switch]$Write)
    $access = [uint32]2147483648
    if ($Write) { $access = [uint32]3221225472 }   # GENERIC_READ | GENERIC_WRITE
    [ClevoHelper.LedNative]::CreateFileW($Collection.Path, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
}

function Read-LedFeature {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Collection, [Parameter(Mandatory)][byte]$ReportId)
    $h = Open-LedDevice $Collection
    if ($h -eq [IntPtr]::new(-1)) { throw "open failed for $($Collection.HwId)" }
    try {
        $buf = New-Object byte[] $Collection.FeatLen
        $buf[0] = $ReportId
        if (-not [ClevoHelper.LedNative]::HidD_GetFeature($h, $buf, $Collection.FeatLen)) {
            $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ("GetFeature(0x{0:X2}) failed, win32 {1}" -f $ReportId, $e)
        }
        $buf
    }
    finally { [void][ClevoHelper.LedNative]::CloseHandle($h) }
}

function New-LedFrame {
    param([byte]$Cmd, [byte]$D0 = 0, [byte]$D1 = 0, [byte]$D2 = 0, [byte]$D3 = 0)
    [byte[]]@($script:ClassByte, $Cmd, $D0, $D1, $D2, $D3, 0)
}

function Write-LedReport {
    <#
      .SYNOPSIS Send one 7-byte LED frame on the command collection. -Apply to send.
      .NOTES 7 bytes, not the 6 the Linux implementations send: this unit declares
             a 7-byte feature report and our own round-trip test proved it works.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Frame, [switch]$Apply)
    $col = Get-LedCmdCollection

    $txt = ($Frame | ForEach-Object { $_.ToString('X2') }) -join ' '
    if (-not $Apply) { Write-Host "  [dry-run] $txt"; return $null }

    $h = Open-LedDevice $col -Write
    if ($h -eq [IntPtr]::new(-1)) { throw 'open for write failed' }
    try {
        $send = New-Object byte[] $script:ReportSize
        [Array]::Copy($Frame, $send, [Math]::Min($Frame.Length, $script:ReportSize))
        if (-not [ClevoHelper.LedNative]::HidD_SetFeature($h, $send, $script:ReportSize)) {
            $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ("SetFeature failed, win32 {0}  frame={1}" -f $e, $txt)
        }
        if ($script:ReportDelayMs -gt 0) { Start-Sleep -Milliseconds $script:ReportDelayMs }
        $back = New-Object byte[] $script:ReportSize
        $back[0] = $script:ClassByte
        [void][ClevoHelper.LedNative]::HidD_GetFeature($h, $back, $script:ReportSize)
        $back
    }
    finally { [void][ClevoHelper.LedNative]::CloseHandle($h) }
}

# ------------------------------------------------------------- public API ----

function Set-LedBrightness {
    <#
      .SYNOPSIS Brightness 0-10 (official UI steps 2,4,6,10), speed 0-10 (0 = slowest).
      .NOTES Hard-capped at 10. See $script:MaxBrightness - higher values have been
             reported to leave the keyboard dark.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(0, 10)][int]$Level,
        [ValidateRange(0, 10)][int]$Speed = 1,
        [switch]$Apply
    )
    Write-LedReport (New-LedFrame $script:CmdBrightSpeed $Level $Speed) -Apply:$Apply | Out-Null
}

function Set-LedKeyColor {
    <#
      .SYNOPSIS Set one key: { CC 01 keyId R G B 00 }   keyId = row*0x20 + col
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(0, 255)][int]$KeyId,
        [Parameter(Mandatory, Position = 1)][ValidateRange(0, 255)][int]$R,
        [Parameter(Mandatory, Position = 2)][ValidateRange(0, 255)][int]$G,
        [Parameter(Mandatory, Position = 3)][ValidateRange(0, 255)][int]$B,
        [switch]$Apply
    )
    Write-LedReport (New-LedFrame $script:CmdDirect $KeyId $R $G $B) -Apply:$Apply | Out-Null
}

function Clear-Led {
    <#
      .SYNOPSIS ClearColor: { CC 00 0C 00 00 00 00 }
      .NOTES REQUIRED before per-key writes - the firmware otherwise keeps old LED
             state and ignores new black (0,0,0) values.
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    Write-LedReport (New-LedFrame $script:CmdAnim $script:CmdClear) -Apply:$Apply | Out-Null
}

function Set-LedAllColor {
    <#
      .SYNOPSIS Full repaint: brightness, then ClearColor, then one report per key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(0, 255)][int]$R,
        [Parameter(Mandatory, Position = 1)][ValidateRange(0, 255)][int]$G,
        [Parameter(Mandatory, Position = 2)][ValidateRange(0, 255)][int]$B,
        [ValidateRange(0, 10)][int]$Brightness = 10,
        [ValidateRange(0, 10)][int]$Speed = 1,
        [switch]$NoClear,
        [switch]$Apply
    )
    Write-Host ("  all keys -> R{0} G{1} B{2}  bright {3}  ({4} keys)" -f $R, $G, $B, $Brightness, $script:LedKeyIds.Count)
    Set-LedBrightness -Level $Brightness -Speed $Speed -Apply:$Apply | Out-Null
    if (-not $NoClear) { Clear-Led -Apply:$Apply | Out-Null }
    foreach ($k in $script:LedKeyIds) {
        Write-LedReport (New-LedFrame $script:CmdDirect $k $R $G $B) -Apply:$Apply | Out-Null
    }
}

function Set-LedAnimation {
    <#
      .SYNOPSIS Animation select: { CC 00 <mode> 00 00 00 00 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Mode,
        [switch]$Apply
    )
    if (-not $script:LedAnimation.Contains($Mode)) { throw "unknown animation '$Mode'. Valid: $($script:LedAnimation.Keys -join ', ')" }
    Write-LedReport (New-LedFrame $script:CmdAnim ([byte]$script:LedAnimation[$Mode])) -Apply:$Apply | Out-Null
}

function Set-LedEffectColor {
    <#
      .SYNOPSIS Colour variant of an effect: { CC <effect> 0xAA R G B 00 }
      .NOTES   d0 MUST be 0xAA ("use the RGB in this frame"). This used to pass the $Key
               argument as d0, so the default (0) selected the RANDOM variant and the RGB
               landed in the wrong slots - the light never took the colour that was asked
               for. The vendor's IL is explicit: SetLEDStatus(10, 170, R,G,B) for breath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Effect,
        [Parameter(Mandatory, Position = 1)][ValidateRange(0, 255)][int]$R,
        [Parameter(Mandatory, Position = 2)][ValidateRange(0, 255)][int]$G,
        [Parameter(Mandatory, Position = 3)][ValidateRange(0, 255)][int]$B,
        [switch]$Apply
    )
    if (-not $script:LedEffect.Contains($Effect)) { throw "unknown effect '$Effect'. Valid: $($script:LedEffect.Keys -join ', ')" }
    Write-LedReport (New-LedFrame ([byte]$script:LedEffect[$Effect]) $script:ColorCustom $R $G $B) -Apply:$Apply | Out-Null
}

function Set-LedRandomEffect {
    <#
      .SYNOPSIS Random-colour variant: d0 = 0x00 ("pick your own colour").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Effect, [switch]$Apply)
    if (-not $script:LedEffect.Contains($Effect)) { throw "unknown effect '$Effect'" }
    Write-LedReport (New-LedFrame ([byte]$script:LedEffect[$Effect]) 0x00) -Apply:$Apply | Out-Null
}

function Save-LedModeToAppSettings {
    <#
      .SYNOPSIS Mirror the chosen mode / colours / speed into AppSetting page 2.
      .NOTES    Same bytes the vendor's own UI reads back (CC.other_Class.InsydeAcpiProt
                .WriteAcpi*): exactly one *Status byte is 1, the others are cleared, and the
                colour block follows its status byte. This is what survives a reboot AND it
                is the only read-back that exists for a mode - the LED hardware itself
                reports nothing.
                Needs Set-AppSettingByte (fancurve.ps1); returns $false when unavailable so
                kbled.ps1 stays usable on its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Mode,
        [int]$R = 0, [int]$G = 0, [int]$B = 0,
        [int]$R2 = 0, [int]$G2 = 0, [int]$B2 = 0,
        [int]$Speed = 5,
        [switch]$Apply
    )
    if (-not (Get-Command Set-AppSettingByte -ErrorAction SilentlyContinue)) { return $false }
    if (-not $script:LedModes.Contains($Mode)) { throw "unknown LED mode '$Mode'" }
    $patch = @{}
    foreach ($k in $script:LedModes.Keys) {
        $so = $script:LedModes[$k].StatusOff
        if ($null -ne $so) { $patch[[int]$so] = 0 }
    }
    $m = $script:LedModes[$Mode]
    if ($null -ne $m.StatusOff) { $patch[[int]$m.StatusOff] = 1 }
    # The Effect byte is what actually makes the firmware RUN an animation. It is not a
    # cosmetic mirror: PerkeyKB.set_Mode(x) is literally `WriteAcpiMode(x)`, and each
    # vendor effect setter calls it with its own value (breath=1, blink=2, ripple=5,
    # wave=7, scan=8, random=9, snake=10, Fn=11). This project used to ZERO this byte for
    # every mode, which is why the keyboard only ever showed the flat per-key colour and
    # no animation ever started.
    if ($null -ne $m.EffectOff) { $patch[[int]$m.EffectOff] = [int]$m.EffectVal }
    $patch[$script:LedSpeedOff] = $Speed
    if ($null -ne $m.ColorOff) {
        $patch[[int]$m.ColorOff + 0] = $R; $patch[[int]$m.ColorOff + 1] = $G; $patch[[int]$m.ColorOff + 2] = $B
    }
    if ($null -ne $m.Color2Off) {
        $patch[[int]$m.Color2Off + 0] = $R2; $patch[[int]$m.Color2Off + 1] = $G2; $patch[[int]$m.Color2Off + 2] = $B2
    }
    # also clear the Effect byte when the new mode does not use it, so a leftover value
    # cannot make Get-LedModeFromAppSettings report the wrong mode
    if ($null -eq $m.EffectOff) { $patch[0x20] = 0 }
    Set-AppSettingByte -Page $script:LedPage -Patch $patch -Apply:$Apply
    return $true
}

function Get-LedModeFromAppSettings {
    <#
      .SYNOPSIS Read back the persisted mode / colours / speed from AppSetting page 2.
    #>
    [CmdletBinding()]
    param()
    $pg = (Get-AppSettingPage $script:LedPage).Bytes
    $active = ''
    foreach ($k in $script:LedModes.Keys) {
        $so = $script:LedModes[$k].StatusOff
        if ($null -ne $so -and [int]$pg[[int]$so] -eq 1) { $active = $k; break }
    }
    # no per-mode status flag lit => fall back to the Effect byte, but ONLY for modes that
    # have no status flag of their own (cycle). Every other mode would otherwise be
    # ambiguous, since they all write Effect now.
    if (-not $active) {
        foreach ($k in $script:LedModes.Keys) {
            $mm = $script:LedModes[$k]
            if ($null -ne $mm.EffectOff -and $null -eq $mm.StatusOff -and
                [int]$pg[[int]$mm.EffectOff] -eq [int]$mm.EffectVal) { $active = $k; break }
        }
    }
    $col = $null
    if ($active -and $null -ne $script:LedModes[$active].ColorOff) {
        $o = [int]$script:LedModes[$active].ColorOff
        $col = @([int]$pg[$o], [int]$pg[$o + 1], [int]$pg[$o + 2])
    }
    [pscustomobject]@{
        Mode  = $active
        Color = $col
        Speed = [int]$pg[$script:LedSpeedOff]
    }
}

function Set-LedGradient {
    <#
      .SYNOPSIS Paint a per-key gradient across the keyboard (a real 渐变, not an effect).
      .NOTES    Uses only the per-key colour command (0x01) - the same verified path as a
                flat repaint - so a gradient cannot fail where a solid colour works.
                'two'   : interpolate 主色 -> 副色 across the columns (left to right)
                'rainbow': full hue sweep across the columns
                Column/row come from the key id itself: id = row*0x20 + col.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('two', 'rainbow')][string]$Kind,
        [ValidateRange(0, 255)][int]$R1 = 255, [ValidateRange(0, 255)][int]$G1 = 0, [ValidateRange(0, 255)][int]$B1 = 0,
        [ValidateRange(0, 255)][int]$R2 = 0, [ValidateRange(0, 255)][int]$G2 = 0, [ValidateRange(0, 255)][int]$B2 = 255,
        [ValidateRange(0, 10)][int]$Brightness = 6,
        [ValidateRange(0, 10)][int]$Speed = 5,
        [switch]$Apply
    )
    Set-LedBrightness -Level $Brightness -Speed $Speed -Apply:$Apply | Out-Null
    Clear-Led -Apply:$Apply | Out-Null
    foreach ($k in $script:LedKeyIds) {
        $col = $k -band 0x1F
        $f = [Math]::Min(1.0, $col / 19.0)
        if ($Kind -eq 'two') {
            $r = [int][Math]::Round($R1 + ($R2 - $R1) * $f)
            $g = [int][Math]::Round($G1 + ($G2 - $G1) * $f)
            $b = [int][Math]::Round($B1 + ($B2 - $B1) * $f)
        }
        else {
            # hue sweep 0..300 deg, full saturation/value
            $h = 300.0 * $f
            $c = 1.0; $x = 1.0 - [Math]::Abs((($h / 60.0) % 2) - 1)
            switch ([int][Math]::Floor($h / 60.0)) {
                0 { $r = 255; $g = [int](255 * $x); $b = 0 }
                1 { $r = [int](255 * $x); $g = 255; $b = 0 }
                2 { $r = 0; $g = 255; $b = [int](255 * $x) }
                3 { $r = 0; $g = [int](255 * $x); $b = 255 }
                4 { $r = [int](255 * $x); $g = 0; $b = 255 }
                default { $r = 255; $g = 0; $b = [int](255 * $x) }
            }
        }
        Write-LedReport (New-LedFrame $script:CmdDirect $k $r $g $b) -Apply:$Apply | Out-Null
    }
}

function Set-LedMode {
    <#
      .SYNOPSIS Switch the keyboard to one of the vendor's mode types.
      .NOTES    Frames are the vendor's byte-for-byte (see $script:LedModes). Ripple is the
                exception: its frame carries no colour at all (SetLEDStatus(7,0,0,0,0)) -
                the colour is read from the EC (ReadAcpiRippleColor), so it is mirrored into
                AppSettings only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Mode,
        [ValidateRange(0, 255)][int]$R = 255, [ValidateRange(0, 255)][int]$G = 0, [ValidateRange(0, 255)][int]$B = 0,
        [ValidateRange(0, 255)][int]$R2 = 0, [ValidateRange(0, 255)][int]$G2 = 0, [ValidateRange(0, 255)][int]$B2 = 255,
        [ValidateRange(0, 7)][int]$Direction = 0,
        [ValidateRange(0, 10)][int]$Brightness = 10,
        [ValidateRange(0, 10)][int]$Speed = 5,
        [ValidateSet('off', 'two', 'rainbow')][string]$Gradient = 'off',
        [switch]$Random,
        [switch]$NoPersist,
        [switch]$Apply
    )
    if (-not $script:LedModes.Contains($Mode)) { throw "unknown LED mode '$Mode'. Valid: $($script:LedModes.Keys -join ', ')" }
    $m = $script:LedModes[$Mode]

    # brightness + speed always go first - the vendor does the same and the firmware ignores
    # an effect that arrives before its brightness
    Set-LedBrightness -Level $Brightness -Speed $Speed -Apply:$Apply | Out-Null

    switch ($Mode) {
        'off' { Clear-Led -Apply:$Apply | Out-Null }
        'static' {
            if ($Gradient -ne 'off' -or $Random) {
                # a gradient IS a static pattern: per-key colours, no animation involved.
                # $Random is how the UI says "彩虹" for this mode.
                Set-LedGradient -Kind $(if ($Gradient -eq 'off') { 'rainbow' } else { $Gradient }) `
                    -R1 $R -G1 $G -B1 $B -R2 $R2 -G2 $G2 -B2 $B2 `
                    -Brightness $Brightness -Speed $Speed -Apply:$Apply
            }
            else {
                Set-LedAllColor -R $R -G $G -B $B -Brightness $Brightness -Speed $Speed -Apply:$Apply | Out-Null
            }
        }
        'cycle' {
            # animation-table selector, not a per-key module frame (see $script:LedModes)
            Write-LedReport (New-LedFrame $script:CmdAnim ([byte]$m.Anim)) -Apply:$Apply | Out-Null
        }
        'ripple' {
            # no colour in the frame; send the select and let the EC use its stored colour
            Write-LedReport (New-LedFrame $m.Cmd $m.Param) -Apply:$Apply | Out-Null
        }
        'scan' {
            if ($Random) {
                # same convention as the other modes: d0 = 0x00 means "pick your own colours"
                Write-LedReport (New-LedFrame $m.Cmd 0x00) -Apply:$Apply | Out-Null
            }
            else {
                Write-LedReport (New-LedFrame $m.Cmd $m.Param $R $G $B) -Apply:$Apply | Out-Null
                Write-LedReport (New-LedFrame $m.Cmd $m.Param2 $R2 $G2 $B2) -Apply:$Apply | Out-Null
            }
        }
        default {
            # Multi-colour ("彩虹") is NOT a colour value: the vendor has a separate variant
            # per mode. wave/snake switch the parameter base from 0xA1+dir (use my RGB) to
            # 0x71+dir (let the firmware colour it); breath/blink send d0 = 0x00.
            $param = [int]$m.Param
            if ($Random -and $m.ContainsKey('RandomParam')) { $param = [int]$m.RandomParam }
            if ($m.ContainsKey('Dirs')) { $param = $param + $Direction }
            Write-LedReport (New-LedFrame $m.Cmd $param $R $G $B) -Apply:$Apply | Out-Null
        }
    }

    if (-not $NoPersist) {
        # Persist through the AppSettings mirror only (the bytes the vendor's own UI keeps).
        # Save-LedToEc (the 0x20 HID frame) is deliberately NOT sent here: its provenance is
        # weaker than the WriteAcpi* map, and this project does not fire unproven writes at
        # the EC as a side effect of clicking a colour.
        [void](Save-LedModeToAppSettings -Mode $Mode -R $R -G $G -B $B -R2 $R2 -G2 $G2 -B2 $B2 -Speed $Speed -Apply:$Apply)
    }
}

function Disable-Led {
    <#
      .SYNOPSIS Alias for ClearColor (all LEDs off).
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    Clear-Led -Apply:$Apply | Out-Null
}

function Save-LedToEc {
    <#
      .SYNOPSIS Persist the current lighting into the EC so it survives a reboot.
    #>
    [CmdletBinding()]
    param([switch]$Forget, [switch]$Apply)
    $v = if ($Forget) { 0 } else { 1 }
    Write-LedReport (New-LedFrame $script:CmdBios $v) -Apply:$Apply | Out-Null
}

function Test-LedWritePath {
    <#
      .SYNOPSIS No-op write-back proof on every collection (no visual change).
    #>
    [CmdletBinding()]
    param([switch]$Apply)
    foreach ($c in (Get-LedCollection | Sort-Object Usage)) {
        $rid = [byte]($c.Usage -band 0xFF)
        try { $before = Read-LedFeature $c $rid } catch { Write-Host ("  {0,-22} read failed: {1}" -f $c.HwId, $_.Exception.Message); continue }
        $beforeTxt = ($before | ForEach-Object { $_.ToString('X2') }) -join ' '
        Write-Host ("  {0,-22} read [{1}] {2}" -f $c.HwId, $c.Role, $beforeTxt)
        if ($Apply) {
            try {
                $h = Open-LedDevice $c -Write
                if ($h -eq [IntPtr]::new(-1)) { throw 'open for write failed' }
                $send = New-Object byte[] $c.FeatLen
                [Array]::Copy($before, $send, $c.FeatLen)
                $send[0] = $rid
                $ok = [ClevoHelper.LedNative]::HidD_SetFeature($h, $send, $c.FeatLen)
                [void][ClevoHelper.LedNative]::CloseHandle($h)
                Write-Host ("  {0,-22} write back {1}" -f '', $(if ($ok) { 'OK' } else { 'FAILED' }))
            }
            catch { Write-Host ("  {0,-22} write failed: {1}" -f '', $_.Exception.Message) }
        }
    }
}
