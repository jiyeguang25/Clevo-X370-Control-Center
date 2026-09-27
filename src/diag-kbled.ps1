# diag-kbled.ps1 - READ ONLY probe of the ITE 829x keyboard LED HID collections.
# Opens feature reports only. Nothing is written.
$ErrorActionPreference = 'Continue'

Add-Type -Namespace LedProbe -Name Native -MemberDefinition @'
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
public static extern bool HidD_GetProductString(IntPtr h, byte[] buf, int len);
'@ -PassThru | Out-Null

$HID_GUID = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$GENERIC_READ = [uint32]2147483648
$INVALID = [IntPtr]::new(-1)
$ITE_VID = 0x048D

function Get-Collections {
    $out = @()
    foreach ($d in (Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'HID\*' })) {
        $parts = $d.PNPDeviceID -split '\\'
        if ($parts.Count -lt 3) { continue }
        $hw = $parts[1].ToLower(); $inst = $parts[2].ToLower()
        $path = '\\?\hid#' + $hw + '#' + $inst + '#' + $HID_GUID
        $h = [LedProbe.Native]::CreateFileW($path, $GENERIC_READ, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($h -eq $INVALID) { continue }
        $caps = New-Object byte[] 64
        $pp = [IntPtr]::Zero
        $usagePage = 0; $usage = 0; $feat = 0; $inLen = 0; $outLen = 0
        if ([LedProbe.Native]::HidD_GetPreparsedData($h, [ref]$pp)) {
            if ([LedProbe.Native]::HidP_GetCaps($pp, $caps) -ge 0) {
                $usage = [BitConverter]::ToUInt16($caps, 0)
                $usagePage = [BitConverter]::ToUInt16($caps, 2)
                $inLen = [BitConverter]::ToUInt16($caps, 4)
                $outLen = [BitConverter]::ToUInt16($caps, 6)
                $feat = [BitConverter]::ToUInt16($caps, 8)
            }
            [void][LedProbe.Native]::HidD_FreePreparsedData($pp)
        }
        $pb = New-Object byte[] 256
        [void][LedProbe.Native]::HidD_GetProductString($h, $pb, 256)
        $prod = [Text.Encoding]::Unicode.GetString($pb); $z = $prod.IndexOf([char]0); if ($z -ge 0) { $prod = $prod.Substring(0, $z) }
        [void][LedProbe.Native]::CloseHandle($h)
        $out += [pscustomobject]@{ Name = $d.Name; HwId = $hw; Path = $path; UsagePage = $usagePage; Usage = $usage; Feat = $feat; In = $inLen; Out = $outLen; Product = $prod }
    }
    $out
}

$cols = Get-Collections | Where-Object { $_.UsagePage -eq 0xFF89 -and $_.Product -like '*ITE*' }
"=== ITE collections ==="
$cols | ForEach-Object { '  {0,-22} usage=0x{1:X4} feat={2,3} in={3} out={4}' -f $_.HwId, $_.Usage, $_.Feat, $_.In, $_.Out }

foreach ($c in $cols) {
    ''
    "=== {0}  (usage 0x{1:X4}, feat {2}) ===" -f $c.HwId, $c.Usage, $c.Feat
    $h = [LedProbe.Native]::CreateFileW($c.Path, $GENERIC_READ, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -eq $INVALID) { '  open failed'; continue }
    $len = [int]$c.Feat
    foreach ($rid in @(0x00, $c.Usage, 0xCC, 0xCE, 0xCF, 0x10, 0x01)) {
        if ($rid -gt 0xFF) { continue }
        $buf = New-Object byte[] $len
        $buf[0] = [byte]$rid
        $ok = [LedProbe.Native]::HidD_GetFeature($h, $buf, $len)
        if ($ok) {
            '  reportID 0x{0:X2} -> OK  {1}' -f $rid, (($buf | ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
        else {
            $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            '  reportID 0x{0:X2} -> fail({1})' -f $rid, $e
        }
    }
    [void][LedProbe.Native]::CloseHandle($h)
}
