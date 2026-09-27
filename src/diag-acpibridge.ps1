# diag-acpibridge.ps1 - find out exactly why the factory DCHU channel rejects us
$ErrorActionPreference = 'Continue'

Add-Type -Namespace ChDiag -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateFileW(string name, uint access, uint share, System.IntPtr sa, uint disp, uint flags, System.IntPtr templ);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(System.IntPtr h);
'@ -PassThru | Out-Null

$GUID = '{86994c74-ad43-4812-b7e7-0c420b5c5fd7}'
$paths = @(
    "\\?\ACPI#CLV0001#1#$GUID",
    "\\?\ACPI#CLV0002#1#$GUID"
)
foreach ($p in $paths) {
    $h = [ChDiag.Native]::CreateFileW($p, 0xC0000000, 3, [IntPtr]::Zero, 3, 0x80, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::new(-1)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        "  {0}  -> CreateFile FAILED, win32 error {1} ({2})" -f $p, $err, ([ComponentModel.Win32Exception]$err).Message
    }
    else {
        "  {0}  -> OPEN OK handle=0x{1:X}" -f $p, $h.ToInt64()
        [void][ChDiag.Native]::CloseHandle($h)
    }
}

"=== elevated? ==="
"  " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

"=== DCHU call, each DLL variant ==="
$dlls = @(
    'C:\Program Files (x86)\ControlCenter\InsydeDCHU.dll',
    "$env:TEMP\ccx\FanSpeedSetting\u_WapProjFanSpeedSetting_6.91.0.0_x64\FanSpeedSetting\InsydeDCHU.dll",
    'C:\WINDOWS\System32\DriverStore\FileRepository\acpibridge1.inf_amd64_6172acb3e289f51f\InsydeDCHU.dll'
)
$i = 0
foreach ($d in $dlls) {
    $i++
    if (-not (Test-Path -LiteralPath $d)) { "  MISSING $d"; continue }
    $esc = $d.Replace('\', '\\')
    try {
        $t = Add-Type -Namespace "DchuProbe$i" -Name Api -PassThru -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int GetDCHU_Data_Integer(int command, out int data);
[System.Runtime.InteropServices.DllImport("$esc")]
public static extern int ReadAppSettings(int page, int offset, int length, byte[] buffer);
"@
        $v = 0
        $rc = $t::GetDCHU_Data_Integer([int]0x200, [ref]$v)
        $buf = New-Object byte[] 16
        $rc2 = $t::ReadAppSettings(0, 0, 16, $buf)
        $hex = ($buf | ForEach-Object { $_.ToString('X2') }) -join ''
        "  [{0}] {1}" -f (Split-Path (Split-Path $d -Parent) -Leaf), $d
        "      GetDCHU_Data_Integer(0x200) rc=0x{0:X8} data=0x{1:X8}" -f $rc, $v
        "      ReadAppSettings(0,0,16)      rc=0x{0:X8} buf={1}" -f $rc2, $hex
    }
    catch { "  FAIL $d : $($_.Exception.Message)" }
}
