# gpu.ps1 - GPU telemetry for ClevoHelper.
#
# WHY THIS FILE EXISTS
# The panel used to shell out to nvidia-smi.exe every sample (4x/second). That makes an
# external executable a hard dependency: if it is not on PATH / not in System32 / not
# shipped by the installed driver version, all GPU numbers silently disappear.
#
# NVML (nvml.dll, shipped in System32 by every NVIDIA driver) gives the same numbers
# in-process, with no subprocess, no console window and no path assumptions. Verified on
# this machine - NVML and nvidia-smi agree exactly:
#     NVML        : RTX 4080 Laptop GPU | 46C | 2280 MHz | 42.282 W | 19%
#     nvidia-smi  : RTX 4080 Laptop GPU, 46, 2280 MHz, 42.28 W, 19 %
#
# nvidia-smi is kept only as a fallback, and its path is searched instead of hardcoded.
# GPU readings will always need the NVIDIA *driver* - that is not a dependency this project
# can bundle away - but nothing here needs any extra program to be installed.

Set-StrictMode -Off

$script:NvmlState = @{ Tried = $false; Ready = $false; Handle = [IntPtr]::Zero }

function Initialize-Nvml {
    <#
      .SYNOPSIS Load nvml.dll and grab device 0. Cached; safe to call repeatedly.
    #>
    [CmdletBinding()]
    param()
    if ($script:NvmlState.Tried) { return $script:NvmlState.Ready }
    $script:NvmlState.Tried = $true
    try {
        if (-not ('ClevoHelper.Nvml' -as [type])) {
            Add-Type -Namespace ClevoHelper -Name Nvml -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct NvmlUtilization { public uint Gpu; public uint Memory; }
[DllImport("nvml.dll", EntryPoint="nvmlInit_v2")] public static extern int Init();
[DllImport("nvml.dll", EntryPoint="nvmlShutdown")] public static extern int Shutdown();
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetCount_v2")] public static extern int GetCount(out uint n);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetHandleByIndex_v2")] public static extern int GetHandle(uint i, out IntPtr d);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetTemperature")] public static extern int GetTemp(IntPtr d, uint sensor, out uint v);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetPowerUsage")] public static extern int GetPower(IntPtr d, out uint mw);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetClockInfo")] public static extern int GetClock(IntPtr d, uint type, out uint mhz);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetUtilizationRates")] public static extern int GetUtil(IntPtr d, out NvmlUtilization u);
[DllImport("nvml.dll", EntryPoint="nvmlDeviceGetName")] public static extern int GetName(IntPtr d, byte[] buf, uint len);
'@
        }
        if ([ClevoHelper.Nvml]::Init() -ne 0) { return $false }
        $h = [IntPtr]::Zero
        if ([ClevoHelper.Nvml]::GetHandle(0, [ref]$h) -ne 0) { return $false }
        $script:NvmlState.Handle = $h
        $script:NvmlState.Ready = $true
    }
    catch { $script:NvmlState.Ready = $false }
    $script:NvmlState.Ready
}

function Get-NvidiaSmiPath {
    <#
      .SYNOPSIS Find nvidia-smi.exe without assuming one location.
    #>
    [CmdletBinding()]
    param()
    $cands = @(
        (Join-Path $env:WINDIR 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $g = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

function Get-GpuTelemetry {
    <#
      .SYNOPSIS GPU temperature / clock / power / utilisation.
      .OUTPUTS  Ok, Name, TempC, Mhz, Watts, Util, Sensor ('nvml' | 'smi')
      .NOTES    NVML first (in-process). nvidia-smi only as a fallback, and the caller is
                told which one answered so the UI can be honest about it.
    #>
    [CmdletBinding()]
    param()
    $r = [pscustomobject]@{ Ok = $false; Name = ''; TempC = $null; Mhz = $null; Watts = $null; Util = $null; Sensor = '' }

    if (Initialize-Nvml) {
        try {
            $h = $script:NvmlState.Handle
            $t = [uint32]0; $p = [uint32]0; $c = [uint32]0
            $u = New-Object ClevoHelper.Nvml+NvmlUtilization
            $okT = ([ClevoHelper.Nvml]::GetTemp($h, 0, [ref]$t) -eq 0)
            $okP = ([ClevoHelper.Nvml]::GetPower($h, [ref]$p) -eq 0)
            $okC = ([ClevoHelper.Nvml]::GetClock($h, 0, [ref]$c) -eq 0)
            $okU = ([ClevoHelper.Nvml]::GetUtil($h, [ref]$u) -eq 0)
            if ($okT -or $okP -or $okC) {
                $name = ''
                try {
                    $nb = New-Object byte[] 96
                    if ([ClevoHelper.Nvml]::GetName($h, $nb, 96) -eq 0) { $name = ([Text.Encoding]::ASCII.GetString($nb)).Trim([char]0) }
                }
                catch { }
                $r.Ok = $true; $r.Sensor = 'nvml'; $r.Name = $name
                if ($okT) { $r.TempC = [int]$t }
                if ($okC) { $r.Mhz = [int]$c }
                if ($okP) { $r.Watts = [Math]::Round($p / 1000.0, 1) }
                if ($okU) { $r.Util = [int]$u.Gpu }
                return $r
            }
        }
        catch { }
    }

    $smi = Get-NvidiaSmiPath
    if ($smi) {
        try {
            $csv = & $smi --query-gpu=name,temperature.gpu,power.draw,clocks.sm,utilization.gpu --format=csv,noheader,nounits 2>$null
            if ($csv) {
                $f = @(($csv -split ',') | ForEach-Object { $_.Trim() })
                $r.Ok = $true; $r.Sensor = 'smi'; $r.Name = $f[0]
                $r.TempC = [int]$f[1]; $r.Watts = [double]$f[2]; $r.Mhz = [int]$f[3]; $r.Util = [int]$f[4]
            }
        }
        catch { }
    }
    $r
}

function Test-GpuTelemetry {
    <#
      .SYNOPSIS Diagnostic: which source answers, and with what numbers.
    #>
    [CmdletBinding()]
    param()
    $nvmlOk = Initialize-Nvml
    $smi = Get-NvidiaSmiPath
    [pscustomobject]@{
        NvmlLoaded = $nvmlOk
        NvmlDll    = $(if (Test-Path (Join-Path $env:WINDIR 'System32\nvml.dll')) { Join-Path $env:WINDIR 'System32\nvml.dll' } else { '(未找到)' })
        SmiPath    = $(if ($smi) { $smi } else { '(未找到)' })
        Reading    = Get-GpuTelemetry
    }
}
