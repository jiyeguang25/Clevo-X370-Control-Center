# diag-hid.ps1 - can a normal user-mode process open the vendor HID collections?
# READ-ONLY diagnostic: opens handles, reads nothing, writes nothing.
$ErrorActionPreference = 'Continue'

Add-Type -Namespace HidDiag -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateFileW(string name, uint access, uint share,
    System.IntPtr sa, uint disp, uint flags, System.IntPtr templ);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(System.IntPtr h);
'@ -PassThru | Out-Null

$HID_GUID = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
# NOTE: PowerShell parses 0x80000000 as a negative Int32, so spell these out.
$GENERIC_READ = [uint32]2147483648
$GENERIC_WRITE = [uint32]1073741824
$OPEN_EXISTING = 3
$INVALID = [IntPtr]::new(-1)

function Try-Open([string]$path, [uint32]$access) {
    $h = [HidDiag.Native]::CreateFileW($path, $access, 3, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($h -eq $INVALID) {
        $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return [pscustomobject]@{ Ok = $false; Err = $e; Msg = ([ComponentModel.Win32Exception]$e).Message }
    }
    [void][HidDiag.Native]::CloseHandle($h)
    return [pscustomobject]@{ Ok = $true; Err = 0; Msg = 'ok' }
}

$devs = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'HID\*' }
foreach ($d in $devs) {
    $id = $d.PNPDeviceID                                    # HID\VID_048D&PID_8910&COL01\6&273F3263&0&0000
    $parts = $id -split '\\'
    if ($parts.Count -lt 3) { continue }
    $hw = $parts[1].ToLower()                               # vid_048d&pid_8910&col01
    $inst = $parts[2].ToLower()
    $path = '\\?\hid#' + $hw + '#' + $inst + '#' + $HID_GUID

    $r = Try-Open $path $GENERIC_READ
    $w = Try-Open $path ([uint32]($GENERIC_READ -bor $GENERIC_WRITE))
    $rTxt = if ($r.Ok) { 'read  OK' } else { "read  DENIED($($r.Err) $($r.Msg))" }
    $wTxt = if ($w.Ok) { 'write OK' } else { "write DENIED($($w.Err) $($w.Msg))" }
    '{0,-52} {1,-34} {2,-12} {3}' -f $d.Name, $hw, $rTxt, $wTxt
}

''
'=== elevated? ==='
'' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
