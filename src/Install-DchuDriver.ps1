# Install-DchuDriver.ps1 - install (or repair) the ACPI bridge driver + DCHU service from
# the copies bundled inside this application.
#
# WHY: everything the panel does with fans / power modes / graphics mode goes through
#   InsydeDCHU.dll -> ACPI\CLV0001 (AcpiBridge)      <- kernel driver
#                  -> ACPI\CLV0002 (AcpiBridge1/DCHUService)
# The DLL travels inside this app, but the two devices are kernel-mode and can only be
# installed by the OS. Normally the factory Control Center installer put them there; this
# script lets the app do it alone, so a fresh Windows needs nothing else installed first.
#
# Usage (needs administrator - pnputil refuses otherwise):
#   powershell -File Install-DchuDriver.ps1 -Status     # read-only report
#   powershell -File Install-DchuDriver.ps1             # dry run
#   powershell -File Install-DchuDriver.ps1 -Apply      # install/repair
#   ClevoHelper.exe --install-driver                    # same, with a UAC prompt
[CmdletBinding()]
param([switch]$Apply, [switch]$Status)

$ErrorActionPreference = 'Stop'
$driverDir = Join-Path $PSScriptRoot 'driver'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DchuState {
    $ids = @('ACPI\CLV0001\1', 'ACPI\CLV0002\1')
    $dev = foreach ($i in $ids) {
        $d = Get-PnpDevice -InstanceId $i -ErrorAction SilentlyContinue
        [pscustomobject]@{
            InstanceId = $i
            Present    = [bool]$d
            Status     = $(if ($d) { $d.Status } else { '(设备不存在)' })
        }
    }
    $svc = Get-Service -Name CCDCHUService -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Devices = $dev
        Service = [pscustomobject]@{
            Present = [bool]$svc
            Status  = $(if ($svc) { "$($svc.Status)/$($svc.StartType)" } else { '(服务不存在)' })
            Path    = $(if ($svc) { (Get-CimInstance Win32_Service -Filter "Name='CCDCHUService'").PathName } else { '' })
        }
    }
}

function Show-State([string]$tag) {
    $s = Get-DchuState
    Write-Host "--- $tag"
    foreach ($d in $s.Devices) { Write-Host ("    {0,-20} {1}" -f $d.InstanceId, $d.Status) }
    Write-Host ("    {0,-20} {1}" -f 'CCDCHUService', $s.Service.Status)
    if ($s.Service.Path) { Write-Host ("    {0,-20} {1}" -f '', $s.Service.Path) }
    $s
}

$bundled = Get-ChildItem -LiteralPath $driverDir -File -ErrorAction SilentlyContinue
if (-not $bundled) { throw "bundled driver files not found in $driverDir" }
$inf1 = Join-Path $driverDir 'acpibridge.inf'
$inf2 = Join-Path $driverDir 'acpibridge1.inf'
foreach ($f in @($inf1, $inf2)) { if (-not (Test-Path -LiteralPath $f)) { throw "missing $f" } }

# 完整性检查：这个包里少一个文件，装上去的服务就会"运行着但什么都不返回"。
# 这坑真踩过 —— 早期内嵌的驱动包只有 9 个文件，缺 GetProductdll.dll / Device.dll / Platform.dll，
# 正是 DCHUService.exe 干活要用的那几个，"安装成功"之后所有 DCHU 读数全是 0。
# 所以这里宁可拒绝安装，也不装一个残包。
$required = @('DCHUService.exe', 'GetProductdll.dll', 'Device.dll', 'Platform.dll', 'InsydeDCHU.dll',
              'AcpiBridge.sys', 'AcpiBridge1.sys')
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $driverDir $_)) })
# 另一条硬性要求：INF 不得把驱动关联到原厂应用（AddSoftware / SoftwareID）。
# 原厂 INF 里有 `AddSoftware = ClevoCtrlPnl` 加上一行 SoftwareID 指向 pfn://CLEVOCO.FnhotkeysandOSD，
# 它会让 Windows 在装完驱动之后去安装/拉起原厂 FnKey 应用 —— 用户明确不要这个（真踩过）。
# 注意判据要**跳过 INF 注释行**（以 ; 开头），否则我自己写在那里的说明注释会被当指令。
$bloat = @()
foreach ($inf in Get-ChildItem $driverDir -Filter '*.inf' -File) {
    $code = Get-Content -LiteralPath $inf.FullName |
        Where-Object { $_ -notmatch '^\s*;' }
    $bad = $code | Select-String -Pattern '^\s*AddSoftware\s*=|^\s*SoftwareID\s*=\s*pfn:' -ErrorAction SilentlyContinue
    if ($bad) { $bloat += ('{0}: {1}' -f $inf.Name, ($bad | Select-Object -First 1).Line.Trim()) }
}
if ($bloat.Count) {
    throw ('驱动 INF 里还有关联原厂应用的指令，拒绝安装：{0}' -f ($bloat -join '; '))
}
if ($missing.Count) {
    throw ('自带的驱动包不完整，缺少：{0}（缺文件的包装上去会让 DCHU 服务运行但不响应，因此拒绝安装）' -f ($missing -join ', '))
}

Write-Host ("bundled driver package: {0} files, {1:N1} MB  ({2})  [完整性检查通过]" -f `
    $bundled.Count, (($bundled | Measure-Object Length -Sum).Sum / 1MB), $driverDir)

# The panel's own read path is the real acceptance test: a driver can be "installed" and
# still not answer. That check runs through InsydeDCHU.dll exactly like the app does.
# 必须定义在第一次调用之前（PowerShell 是按执行顺序认识的）。
function Test-DchuChannel {
    try {
        $dll = @(
            (Join-Path $PSScriptRoot 'lib\InsydeDCHU.dll'),
            'C:\Program Files (x86)\ControlCenter\DCHU\InsydeDCHU.dll'
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $dll) { return $null }
        if (-not ('ClevoHelper.DchuProbe' -as [type])) {
            Add-Type -Namespace ClevoHelper -Name DchuProbe -MemberDefinition @"
[System.Runtime.InteropServices.DllImport(@"$dll")]
public static extern int GetDCHU_Data_Buffer(int command, byte[] buffer);
"@
        }
        $buf = New-Object byte[] 256
        $rc = [ClevoHelper.DchuProbe]::GetDCHU_Data_Buffer(12, $buf)
        return [pscustomobject]@{ Rc = $rc; CpuTemp = [int]$buf[18]; GpuTemp = [int]$buf[21] }
    }
    catch { return $null }
}

$before = Show-State '当前状态'
$probeBefore = Test-DchuChannel
if ($probeBefore) {
    Write-Host ("    通道实测        rc=0x{0:X}  CPU={1}C  GPU={2}C" -f $probeBefore.Rc, $probeBefore.CpuTemp, $probeBefore.GpuTemp)
} else {
    Write-Host  '    通道实测        读不到数据（设备状态可能是 OK —— 这正是"按钮全都不灵"的样子）'
}

if ($Status) {
    # 判据必须包含"通道到底通不通"：设备状态 OK 但通道是死的，是真出现过的状态
    # （原厂控制中心卸载之后），只看 PnP 状态会给出"链路正常"的错误结论。
    $devOk = ($before.Devices | Where-Object { -not $_.Present -or $_.Status -ne 'OK' }).Count -eq 0
    $chanOk = [bool]($probeBefore -and $probeBefore.CpuTemp -gt 0)
    Write-Host ''
    if ($devOk -and $chanOk) { Write-Host 'DCHU 链路正常（设备 + 实测读数都通过），无需安装。' }
    elseif ($devOk -and -not $chanOk) {
        Write-Host '设备状态正常，但 DCHU 读数全是 0 —— 链路其实没通。'
        Write-Host '  先试：重启一次（驱动包换过之后系统会要求重启）。'
        Write-Host '  还不行：用 -Apply 重装自带驱动（会重启 DCHU 服务）。'
    }
    else { Write-Host 'DCHU 链路不完整 —— 可用 -Apply 安装自带驱动。' }
    return
}

if (-not $Apply) {
    Write-Host ''
    Write-Host '（dry-run：加 -Apply 才会安装。需要管理员权限）'
    Write-Host ("  pnputil /add-driver `"{0}`" /install" -f $inf1)
    Write-Host ("  pnputil /add-driver `"{0}`" /install" -f $inf2)
    return
}

if (-not (Test-Admin)) {
    throw '需要管理员权限：请用管理员身份运行，或直接执行 ClevoHelper.exe --install-driver（会弹 UAC）'
}

foreach ($inf in @($inf1, $inf2)) {
    Write-Host ("--- pnputil /add-driver {0} /install" -f (Split-Path $inf -Leaf))
    $out = & pnputil.exe /add-driver $inf /install 2>&1
    $out | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { Write-Host ("    !!! pnputil 返回 {0}" -f $LASTEXITCODE) }
}

# rescan so a device that was sitting there without a driver gets bound right away
try { & pnputil.exe /scan-devices 2>&1 | ForEach-Object { Write-Host "    $_" } } catch { }

# 再重启一次 DCHU 服务：驱动包换过之后，服务可能还握着旧设备实例的句柄，
# 表现就是"服务在跑但读数全是 0"。这一步失败不算致命（可能只是权限），所以只提示。
try {
    Write-Host '--- Restart-Service CCDCHUService'
    Restart-Service -Name 'CCDCHUService' -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    Write-Host '    服务已重启'
}
catch { Write-Host ("    服务重启失败（不影响驱动安装）：{0}" -f $_.Exception.Message) }

$after = Show-State '安装后状态'
$probe = Test-DchuChannel
Write-Host ''
if ($probe) {
    Write-Host ("DCHU 通道实测：rc=0x{0:X}  CPU={1}C  GPU={2}C  -> 可用" -f $probe.Rc, $probe.CpuTemp, $probe.GpuTemp)
}
else {
    Write-Host 'DCHU 通道实测：读不到数据。若设备状态是 OK，重启一次再试。'
}
