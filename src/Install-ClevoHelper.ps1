# 把构建好的 exe 部署到本机（全部是用户级操作，不需要管理员）：
#   1) 复制到 %LOCALAPPDATA%\ClevoHelper\ClevoHelper.exe —— **稳定位置**；
#   2) 开始菜单（+ 桌面，可用 -NoDesktop 关掉）快捷方式、AUMID 注册项都指向它；
#   3) 自启的 .vbs 用这份新副本重写（自启本来开着才写；-Autostart 强制打开）。
#
# 为什么要有"稳定位置"这件事：用户的桌面上原来放的是 exe 本体，他把桌面清掉以后，
# 开机自启里写死的那个桌面路径就失效了 —— 每次登录弹「系统找不到指定的文件 (0x80070002)」。
# 现在 exe 只有一份放在 %LOCALAPPDATA%，桌面/开始菜单/自启都指向它；删快捷方式不会让程序失效。
#
# 用法：Install-ClevoHelper.ps1 [-Source <刚构建的 exe>] [-NoDesktop] [-Autostart]
param(
    [string]$Source,
    [switch]$NoDesktop,
    [switch]$Autostart
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$root = Split-Path $src -Parent

if (-not $Source) { $Source = Join-Path $root 'dist\ClevoHelper.exe' }
if (-not (Test-Path -LiteralPath $Source)) { throw "source exe not found: $Source" }
$Source = (Get-Item -LiteralPath $Source).FullName

$installDir = Join-Path $env:LOCALAPPDATA 'ClevoHelper'
$installExe = Join-Path $installDir 'ClevoHelper.exe'
if (-not (Test-Path -LiteralPath $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

# 正在被面板占用时也要能覆盖：源和目标不同路径，Copy-Item 覆盖目标文件本身是允许的
Copy-Item -LiteralPath $Source -Destination $installExe -Force
Write-Host ('deployed: {0}' -f $installExe)
Write-Host ('  size  : {0:N0} KB' -f ((Get-Item -LiteralPath $installExe).Length / 1KB))
Write-Host ('  from  : {0}' -f $Source)

# 快捷方式 / AUMID 身份（Set-ShortcutIdentity 自己会读回验证）
$identArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $src 'Set-ShortcutIdentity.ps1'), '-Exe', $installExe)
if (-not $NoDesktop) { $identArgs += '-AlsoDesktop' }
& powershell.exe @identArgs
if ($LASTEXITCODE -ne 0) { Write-Host ('  identity exit {0}' -f $LASTEXITCODE) }

# 自启：本来开着就刷新，或者显式要求打开
. (Join-Path $src 'autostart.ps1')
$script:HostExe = $installExe
if ($Autostart -or (Get-AutostartState)) {
    $r = Enable-Autostart
    Write-Host ('autostart: {0}' -f $r.VbsPath)
    foreach ($c in $r.Candidates) { Write-Host ('  candidate: {0}  exists={1}' -f $c, (Test-Path -LiteralPath $c)) }
}
else { Write-Host 'autostart: 没开，跳过（用 -Autostart 可以打开）' }
