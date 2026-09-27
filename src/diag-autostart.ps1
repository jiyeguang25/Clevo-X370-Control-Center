# 自启机制的独立测试（现在是"Startup 快捷方式"）：
#   1) Enable-Autostart 会装一份 exe 到 %LOCALAPPDATA%\ClevoHelper，并在 Startup 写 .lnk；
#   2) 读回验证：目标存在、参数是 --tray、旧 .vbs 被清掉；
#   3) 真跑：停掉面板 → 跑那个快捷方式（和登录时一样）→ 面板应该起来，而且**没有弹窗**；
#   4) 目标故意指错时：Windows 会静默跳过（不会再出现 Windows Script Host 那个框）。
#
# 用法：diag-autostart.ps1 [-SkipRun]
param([switch]$SkipRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'autostart.ps1')

'==== 1) 生成（Enable-Autostart）===='
$script:HostExe = 'C:\Users\yeguang\DSH\ClevoHelper\dist\ClevoHelper.exe'
$r = Enable-Autostart
'  自启文件: ' + $r.Link
'  目标    : ' + $r.Target
'  参数    : ' + $r.Arguments
'  目标存在: ' + $r.TargetExists
'  迁移掉旧 .vbs: ' + $r.MigratedFromVbs
'  安装副本: ' + $r.Installed
'  旧 .vbs 还在吗: ' + (Test-Path -LiteralPath $script:LegacyAutostartVbs)

'==== 2) Startup 目录现状 ===='
Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')) -Force |
    Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String -Width 120

if ($SkipRun) { '（-SkipRun：不真跑）'; return }

'==== 3) 真跑一次（模拟登录）===='
# 只挑真正的面板进程：脚本自己的命令行里也有 "ClevoHelper"（路径），不加这几个条件
# 会把**自己**当面板杀掉（第一版就是这么自尽的）。
$me = $PID
$panels = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object {
        $_.ProcessId -ne $me -and
        $_.CommandLine -notmatch '-Command' -and
        $_.CommandLine -notmatch 'diag-' -and
        $_.CommandLine -match 'ClevoHelper\.ps1'
    })
foreach ($x in $panels) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3
'  跑之前面板进程数: ' + @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -notmatch '-Command' -and $_.CommandLine -notmatch 'diag-' -and $_.CommandLine -match 'ClevoHelper\.ps1' }).Count
$t0 = Get-Date
Start-Process -FilePath $r.Link          # 相当于双击 Startup 里那个快捷方式
'  启动返回用时 {0:N1}s（弹框会挂住不返回）' -f ((Get-Date) - $t0).TotalSeconds
Start-Sleep -Seconds 20
$now = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -notmatch '-Command' -and $_.CommandLine -notmatch 'diag-' -and $_.CommandLine -match 'ClevoHelper\.ps1' })
'  跑之后面板进程数: ' + $now.Count
$now | ForEach-Object { '    pid {0}  {1}' -f $_.ProcessId, (($_.CommandLine -replace '\s+', ' ')) }

'==== 4) 目标指错时（模拟 exe 被删）===='
$ws = New-Object -ComObject WScript.Shell
$bad = Join-Path $env:TEMP 'clevo-broken-autostart.lnk'
$l = $ws.CreateShortcut($bad)
$l.TargetPath = 'C:\__does_not_exist__\ClevoHelper.exe'
$l.Arguments = '--tray'
$l.Save()
$err = $null
try { Start-Process -FilePath $bad -ErrorAction Stop; '  Start-Process 没有报错' }
catch { '  Start-Process 报错（这没关系，登录时是资源管理器在跑，它直接跳过）：' + $_.Exception.Message }
Start-Sleep -Seconds 1
'  有没有卡住的脚本宿主进程: ' + @(Get-Process wscript, cscript -ErrorAction SilentlyContinue).Count
Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue
