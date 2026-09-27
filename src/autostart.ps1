# 开机自启（Startup 目录里的一个**快捷方式**）
#
# 这条路踩过两次坑，最后才定成"快捷方式"：
#
#   坑 1：目标写死成桌面那个 exe。用户把桌面 exe 删掉以后，每次登录弹
#         「Windows Script Host —— 系统找不到指定的文件 (0x80070002)」（0x80070002 = 文件找不到），
#         而且面板根本没起来。
#
#   坑 2：用 .vbs 来做（好按顺序试几个候选路径）。结果 **Windows Defender 把 Startup 里的 .vbs
#         当成木马直接隔离**：
#           11:16:32  Trojan:Script/ObfusScript.A!ml  (threatid 2147842389)
#                     file:_...\Startup\ClevoHelper.vbs ; startup:_...\Startup\ClevoHelper.vbs
#           11:16:46  已处置（文件被删）
#         于是自启静默失效，还平白多了一条"中过木马"的记录。
#
# 现在：Startup 里放一个 .lnk，指向一份**稳定位置的 exe**（%LOCALAPPDATA%\ClevoHelper\），
# 参数 `--tray`。好处：
#   · 没有任何脚本 ⇒ Defender 没有可咬的东西（快捷方式不是脚本）；
#   · 目标不存在时，Windows **直接跳过**这个快捷方式，**不弹任何框**；
#   · 面板启动时如果发现自启开着但目标没了，会自己把副本补回去（Repair-Autostart）。

$script:InstallDir = Join-Path $env:LOCALAPPDATA 'ClevoHelper'
$script:InstallExe = Join-Path $script:InstallDir 'ClevoHelper.exe'
$script:AutostartLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClevoHelper.lnk'
$script:LegacyAutostartVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClevoHelper.vbs'

function Get-AutostartPath { return $script:AutostartLnk }
function Get-AutostartLogPath { Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\autostart.log' }

function Get-AutostartState {
    # 旧的 .vbs 也算"开着"，这样从老版本升上来时能迁移掉（见 Enable-Autostart）
    return (Test-Path -LiteralPath $script:AutostartLnk) -or (Test-Path -LiteralPath $script:LegacyAutostartVbs)
}

function Get-AutostartExePath {
    # 当前在用的 exe：打包运行时由 -HostExe 传进来；开发模式（直接跑 .ps1）没有
    if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) { return $script:HostExe }
    return $null
}

function Get-AutostartCandidates {
    $list = @(
        $script:InstallExe,
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\ClevoHelper.exe'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ClevoHelper.exe'),
        (Get-AutostartExePath)
    )
    return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AutostartTarget {
    <#
      .SYNOPSIS 自启快捷方式现在指向哪个 exe（读 .lnk 的真值，不是我以为的值）。读不到返回 ''。
    #>
    if (-not (Test-Path -LiteralPath $script:AutostartLnk)) { return '' }
    try {
        $ws = New-Object -ComObject WScript.Shell
        return [string]($ws.CreateShortcut($script:AutostartLnk).TargetPath)
    }
    catch { return '' }
}

function Install-PanelExe {
    <#
      .SYNOPSIS 把面板 exe 复制到 %LOCALAPPDATA%\ClevoHelper，返回落地路径（失败返回 $null）。
      .NOTES    源按"最可能是用户正在用的那个"排序；正在运行的 exe 可以被复制（Windows 允许读）。
    #>
    $sources = @(
        (Get-AutostartExePath),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\ClevoHelper.exe'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ClevoHelper.exe')
    )
    foreach ($src in $sources) {
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $script:InstallDir)) {
                New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
            }
            $full = (Resolve-Path -LiteralPath $src).Path
            if ($full -ne $script:InstallExe) {
                Copy-Item -LiteralPath $full -Destination $script:InstallExe -Force
            }
            return $script:InstallExe
        }
        catch { Write-Dbg ('install copy failed from ' + $src + ': ' + $_.Exception.Message) }
    }
    return $null
}

function Enable-Autostart {
    <#
      .SYNOPSIS 装一份 exe 到稳定位置，写 Startup 快捷方式（目标=那份 exe，参数 --tray）。
      .NOTES    顺手删掉旧机制留下的 .vbs（Defender 会把它当木马隔离，留着没意义还吓人）。
                不碰界面 —— 面板的 Set-Autostart 负责显示。
    #>
    $installed = Install-PanelExe
    $target = $(if ($installed) { $installed } else { (Get-AutostartCandidates | Select-Object -First 1) })
    if (-not $target) { throw '找不到可以指向的 exe（dist / 桌面 / 安装副本都不在）' }

    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($script:AutostartLnk)
    $lnk.TargetPath = $target
    $lnk.Arguments = '--tray'                       # 登录时直接进托盘，不弹窗口
    $lnk.WorkingDirectory = (Split-Path $target -Parent)
    $lnk.IconLocation = $target + ',0'
    $lnk.Description = 'ClevoHelper 开机自启（登录后直接进托盘）'
    $lnk.WindowStyle = 7                            # 最小化启动，连任务栏都不闪
    $lnk.Save()

    $legacy = Test-Path -LiteralPath $script:LegacyAutostartVbs
    if ($legacy) { Remove-Item -LiteralPath $script:LegacyAutostartVbs -Force -ErrorAction SilentlyContinue }

    # 读回验证：快捷方式真的指向存在的那份 exe、参数真的是 --tray
    $back = $ws.CreateShortcut($script:AutostartLnk)
    return [pscustomobject]@{
        VbsPath = $script:AutostartLnk     # 名字保留，调用方只当"自启文件路径"用
        Link = $script:AutostartLnk
        Target = [string]$back.TargetPath
        Arguments = [string]$back.Arguments
        TargetExists = (Test-Path -LiteralPath ([string]$back.TargetPath))
        MigratedFromVbs = $legacy
        Installed = $installed
        Candidates = @(Get-AutostartCandidates)
    }
}

function Disable-Autostart {
    Remove-Item -LiteralPath $script:AutostartLnk -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:LegacyAutostartVbs -Force -ErrorAction SilentlyContinue
    return (-not (Get-AutostartState))
}

function Repair-Autostart {
    <#
      .SYNOPSIS 自启开着、但快捷方式丢了或指向的 exe 没了 —— 用当前这份 exe 重新装好。
      .NOTES    自启没开时什么都不做（不替用户打开一个他没要的东西）。面板启动时调一次。
    #>
    if (-not (Get-AutostartState)) { return $null }
    $cur = Get-AutostartTarget
    if ($cur -and (Test-Path -LiteralPath $cur) -and (Test-Path -LiteralPath $script:AutostartLnk)) { return $null }
    return (Enable-Autostart)
}
