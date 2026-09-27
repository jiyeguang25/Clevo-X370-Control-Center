# Remove-FactoryLeftovers.ps1 - 把原厂 Control Center 留下的东西清干净（用户要求）。
#
# 清什么：
#   1. 原厂 FnKey/OSD 应用（CLEVOCO.FnhotkeysandOSD）+ 它的 provisioned 副本
#   2. C:\Program Files (x86)\ControlCenter 残留（卸载后剩 1.7 MB 尾料）
#   3. 三条指向空目录的 "ControlCenter 3.0 Package" 卸载项
#   4. 设备上"关联到原厂应用"的注册残留（AddSoftware 那套留下的），防止重装驱动时又把它拉回来
#
# **绝不动**（我们自己的面板要靠它们）：
#   ACPI\CLV0001 AcpiBridge 驱动、ACPI\CLV0002 AcpiBridge1 驱动、CCDCHUService 服务
#   以及 DriverStore 里的 acpibridge* 包。
#
# Usage:
#   powershell -File Remove-FactoryLeftovers.ps1            # 只报告（dry-run）
#   powershell -File Remove-FactoryLeftovers.ps1 -Apply     # 真删（需要管理员）
[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Continue'
$isAdmin = try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $false }

Write-Host ('模式：{0}   （管理员：{1}）' -f $(if ($Apply) { 'APPLY' } else { 'dry-run' }), $isAdmin)
Write-Host ''

# 先记录必须保住的东西，最后复查
function Get-Keepers {
    $drv = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'AcpiBridge' } | Select-Object Name, State
    $svc = Get-Service -Name CCDCHUService -ErrorAction SilentlyContinue
    [pscustomobject]@{ Drivers = $drv; Service = $(if ($svc) { "$($svc.Status)/$($svc.StartType)" } else { '(缺失)' }) }
}
$keepBefore = Get-Keepers
Write-Host '=== 必须保住的东西（本次不会碰） ==='
$keepBefore.Drivers | ForEach-Object { Write-Host ('    {0,-14} {1}' -f $_.Name, $_.State) }
Write-Host ('    {0,-14} {1}' -f 'CCDCHUService', $keepBefore.Service)
Write-Host ''

# ---------------------------------------------------------------- 1. appx ----
Write-Host '=== 1. 原厂应用 ==='
$pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^CLEVOCO\.' })
if (-not $pkgs.Count) { Write-Host '    （没有装着的 CLEVOCO 应用）' }
foreach ($p in $pkgs) {
    Write-Host ('    {0}  {1}' -f $p.Name, $p.Version)
    if ($Apply) {
        # 先停掉进程，否则包被占用删不掉
        Get-Process -Name 'FnKey' -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host ('      stopping pid {0}' -f $_.Id)
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 800
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; Write-Host '      已卸载' }
        catch { Write-Host ('      卸载失败：{0}' -f $_.Exception.Message) }
    }
}
$prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'CLEVOCO' })
if ($prov.Count) {
    foreach ($p in $prov) {
        Write-Host ('    [provisioned] {0}' -f $p.DisplayName)
        if ($Apply) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; Write-Host '      已移除预置副本' }
            catch { Write-Host ('      移除失败：{0}' -f $_.Exception.Message) }
        }
    }
}
else { Write-Host '    （没有预置副本）' }

# ------------------------------------------------------------- 2. 残留目录 ----
# 先删目录：三条卸载项的 InstallLocation 都指向它，目录一没了它们才算"死"，
# 下面的第 3 步才有依据只删该删的（顺序反了会两条都留着）。
Write-Host ''
Write-Host '=== 2. 残留目录 ==='
foreach ($d in 'C:\Program Files (x86)\ControlCenter', 'C:\Program Files\ControlCenter', 'C:\ProgramData\ControlCenter') {
    if (-not (Test-Path -LiteralPath $d)) { Write-Host ('    {0}  （不存在）' -f $d); continue }
    $sz = (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host ('    {0}  {1:N1} MB' -f $d, ($sz / 1MB))
    if ($Apply) {
        try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; Write-Host '      已删除' }
        catch { Write-Host ('      删除失败：{0}' -f $_.Exception.Message) }
    }
}

# ------------------------------------------------------- 3. 空卸载项 ----
Write-Host ''
Write-Host '=== 3. 指向已删目录的卸载项 ==='
$hives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($h in $hives) {
    Get-ChildItem $h -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName -match 'Control ?Center' -and $p.DisplayName -notmatch 'Killer|Thunderbolt') {
            $loc = [string]$p.InstallLocation
            $dead = (-not $loc) -or (-not (Test-Path -LiteralPath $loc))
            Write-Host ('    {0}  v{1}  InstallLocation="{2}"  可删={3}' -f $p.DisplayName, $p.DisplayVersion, $loc, $dead)
            if ($Apply -and $dead) {
                try { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop; Write-Host '      已删除' }
                catch { Write-Host ('      删除失败：{0}' -f $_.Exception.Message) }
            }
        }
    }
}

# --------------------------------------------- 4. 设备上的应用关联残留 ----
Write-Host ''
Write-Host '=== 4. 设备上"关联到原厂应用"的残留 ==='
foreach ($dev in 'ACPI\CLV0002\1', 'ACPI\CLV0001\1') {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$dev\Device Parameters"
    if (-not (Test-Path $k)) { continue }
    Get-ChildItem $k -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $txt = ($props.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match 'CLEVOCO|ClevoCtrlPnl|FnKey' })
        if ($txt) {
            Write-Host ('    {0}' -f $_.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', ''))
            $txt | ForEach-Object { Write-Host ('      {0} = {1}' -f $_.Name, $_.Value) }
            if ($Apply) {
                try { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop; Write-Host '      已删除' }
                catch { Write-Host ('      删除失败：{0}' -f $_.Exception.Message) }
            }
        }
    }
}
Write-Host '    （驱动 INF 里的 AddSoftware 已经在我们自己的包里删掉了，这是双保险）'

# ---------------------------------------------------------------- 复查 ----
Write-Host ''
$keepAfter = Get-Keepers
Write-Host '=== 复查：必须保住的东西还在吗 ==='
$keepAfter.Drivers | ForEach-Object { Write-Host ('    {0,-14} {1}' -f $_.Name, $_.State) }
Write-Host ('    {0,-14} {1}' -f 'CCDCHUService', $keepAfter.Service)
$ok = ($keepAfter.Drivers | Where-Object { $_.State -ne 'Running' }).Count -eq 0 -and $keepAfter.Service -match 'Running'
Write-Host ''
Write-Host $(if ($ok) { 'DCHU 驱动与服务完好 —— 面板功能不受影响。' } else { '⚠ 驱动/服务状态和之前不一样了，请把上面的输出发给我。' })
if (-not $Apply) { Write-Host '（dry-run：加 -Apply 才会真删。需要管理员。）' }
