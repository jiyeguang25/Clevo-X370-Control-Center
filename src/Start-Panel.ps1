# Start-Panel.ps1 - launch ClevoHelper detached so it survives the launcher exiting.
#
# Why not Start-Process: when the launcher runs inside a job object (build agents,
# automation shells, some terminals) the panel is a child of that job and gets killed
# when the job closes. Win32_Process.Create goes through the WMI service, so the panel
# ends up parented to WmiPrvSE.exe and is completely independent.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File Start-Panel.ps1
[CmdletBinding()]
param([string]$Script)

if (-not $Script) { $Script = Join-Path $PSScriptRoot 'ClevoHelper.ps1' }
if (-not (Test-Path -LiteralPath $Script)) { throw "panel script not found: $Script" }

$existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -like ('*-File "' + $Script + '"*')   # exact script path, and never ourselves
    }
if ($existing) {
    Write-Host "already running (pid $($existing.ProcessId -join ', '))"
    return
}

$cmd = 'powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Script + '"'
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed, ReturnValue=$($r.ReturnValue)" }
Write-Host "started detached, pid $($r.ProcessId)"
