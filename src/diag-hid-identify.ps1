# diag-hid-identify.ps1 - name the vendor HID collections so we can find the RGB controller.
# READ ONLY: opens handles and reads descriptors/strings. Writes nothing.
$ErrorActionPreference = 'Continue'

Add-Type -Namespace HidId -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr templ);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr h);
[DllImport("hid.dll")]
public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
[DllImport("hid.dll", CharSet=CharSet.Unicode)]
public static extern bool HidD_GetProductString(IntPtr h, byte[] buf, int len);
[DllImport("hid.dll", CharSet=CharSet.Unicode)]
public static extern bool HidD_GetManufacturerString(IntPtr h, byte[] buf, int len);
[DllImport("hid.dll")]
public static extern bool HidD_GetFeature(IntPtr h, byte[] report, int len);
[DllImport("hid.dll")]
public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
[DllImport("hid.dll")]
public static extern bool HidD_FreePreparsedData(IntPtr pp);
[DllImport("hid.dll")]
public static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
'@ -PassThru | Out-Null

$HID_GUID = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$GENERIC_READ = [uint32]2147483648
$GENERIC_WRITE = [uint32]1073741824
$INVALID = [IntPtr]::new(-1)

function Get-Str([byte[]]$b) {
    if ($null -eq $b) { return '' }
    $s = [Text.Encoding]::Unicode.GetString($b)
    $z = $s.IndexOf([char]0)
    if ($z -ge 0) { $s = $s.Substring(0, $z) }
    return $s.Trim()
}

foreach ($d in (Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'HID\*' })) {
    $parts = $d.PNPDeviceID -split '\\'
    if ($parts.Count -lt 3) { continue }
    $hw = $parts[1].ToLower(); $inst = $parts[2].ToLower()
    $path = '\\?\hid#' + $hw + '#' + $inst + '#' + $HID_GUID
    $h = [HidId.Native]::CreateFileW($path, $GENERIC_READ, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -eq $INVALID) { continue }

    $attr = New-Object HidId.Native+HIDD_ATTRIBUTES
    $attr.Size = [Runtime.InteropServices.Marshal]::SizeOf($attr)
    [void][HidId.Native]::HidD_GetAttributes($h, [ref]$attr)

    $pb = New-Object byte[] 256; $mb = New-Object byte[] 256
    [void][HidId.Native]::HidD_GetProductString($h, $pb, 256)
    [void][HidId.Native]::HidD_GetManufacturerString($h, $mb, 256)

    $caps = New-Object byte[] 64
    $pp = [IntPtr]::Zero
    $capsTxt = ''
    if ([HidId.Native]::HidD_GetPreparsedData($h, [ref]$pp)) {
        if ([HidId.Native]::HidP_GetCaps($pp, $caps) -ge 0) {
            # HIDP_CAPS: Usage@0, UsagePage@2, InputReportByteLength@4,
            #            OutputReportByteLength@6, FeatureReportByteLength@8
            $usagePage = [BitConverter]::ToUInt16($caps, 2)
            $usage = [BitConverter]::ToUInt16($caps, 0)
            $inLen = [BitConverter]::ToUInt16($caps, 4)
            $outLen = [BitConverter]::ToUInt16($caps, 6)
            $featLen = [BitConverter]::ToUInt16($caps, 8)
            $capsTxt = 'UP=0x{0:X4} U=0x{1:X4}  in={2} out={3} feat={4}' -f $usagePage, $usage, $inLen, $outLen, $featLen
        }
        [void][HidId.Native]::HidD_FreePreparsedData($pp)
    }

    '{0,-34} VID={1:X4} PID={2:X4}  {3}' -f $hw, $attr.VendorID, $attr.ProductID, $capsTxt
    '{0,-34}   mfg="{1}"  product="{2}"' -f '', (Get-Str $mb), (Get-Str $pb)
    [void][HidId.Native]::CloseHandle($h)
}
