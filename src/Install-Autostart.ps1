# Install-Autostart.ps1 —— 命令行版的"开机自启"开关（面板里那个开关用的是同一套逻辑）。
#
# 现在自启是 **Startup 目录里的一个快捷方式**，指向 %LOCALAPPDATA%\ClevoHelper\ClevoHelper.exe，
# 参数 `--tray`。逻辑全在 autostart.ps1 里，这个脚本只是薄薄一层壳。
#
# 为什么不再是 .vbs（这条路走过，两个坑都踩了）：
#   1) 目标写死桌面那个 exe：用户把桌面 exe 删掉后，每次登录弹
#      「Windows Script Host —— 系统找不到指定的文件 (0x80070002)」，面板还起不来；
#   2) 改成按候选路径试的 .vbs 之后，**Windows Defender 直接把 Startup 里的 .vbs 当木马隔离**：
#        Trojan:Script/ObfusScript.A!ml (threatid 2147842389) —— 自启静默失效。
#   快捷方式没有脚本可咬，而且目标不存在时 Windows 直接跳过它，不弹框。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-Autostart.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File Install-Autostart.ps1 -Uninstall
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$HostExe
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'autostart.ps1')
if ($HostExe) { $script:HostExe = $HostExe }

if ($Uninstall) {
    $ok = Disable-Autostart
    Write-Host ('uninstalled: 自启已' + $(if ($ok) { '关闭' } else { '**没关掉**（文件还在？）' }))
    Write-Host ('  Startup 目录: {0}' -f [Environment]::GetFolderPath('Startup'))
    return
}

$r = Enable-Autostart
Write-Host ('installed: {0}' -f $r.Link)
Write-Host ('  target : {0}  exists={1}' -f $r.Target, $r.TargetExists)
Write-Host ('  args   : {0}' -f $r.Arguments)
Write-Host ('  copy   : {0}' -f $r.Installed)
if ($r.MigratedFromVbs) { Write-Host '  （顺手删掉了旧机制留下的 ClevoHelper.vbs —— Defender 会把它当木马隔离）' }
Write-Host 'next logon: 从那份副本静默进托盘；关掉用 -Uninstall，或面板杂项页的「开机自启 → 关」'
