# 代码层功能探针：只调用只读/纯函数（不写 EC、不启动窗口）。
# 必须在 src 目录下运行（模块用 $PSScriptRoot 找 dll/驱动/资源）。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
$ErrorActionPreference = 'Continue'
$src = $PSScriptRoot
$pass = 0; $fail = 0; $skip = 0
$log = Join-Path $env:TEMP 'clevo-func-probe.log'
$script:LogPath = $log
$script:Sync = [hashtable]::Synchronized(@{ Pending = $null; Status = '' })

function T([string]$name, [scriptblock]$sb, [string]$expect) {
    try {
        $v = & $sb
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { throw '返回空' }
        $s = if ($v -is [string]) { $v } else { ($v | Out-String -Width 200).Trim() }
        $s = ($s -replace '\s+', ' ')
        if ($s.Length -gt 150) { $s = $s.Substring(0, 150) + '…' }
        Write-Host ('PASS  {0,-24} {1}' -f $name, $s)
        $script:pass++
    } catch {
        Write-Host ('FAIL  {0,-24} {1}' -f $name, $_.Exception.Message)
        $script:fail++
    }
}

# ---- 按依赖顺序加载模块（dot-source 才有正确的 $PSScriptRoot）----
foreach ($m in 'panel-core.ps1', 'model-guard.ps1', 'dchu.ps1', 'fanctl.ps1', 'fancurve.ps1', 'gpu.ps1',
    'kbled.ps1', 'misc.ps1', 'autostart.ps1', 'panel-scene.ps1', 'panel-about.ps1', 'panel-led.ps1', 'panel-selftest.ps1') {
    try { . (Join-Path $src $m); Write-Host ("loaded {0}" -f $m) }
    catch { Write-Host ("LOAD-FAIL {0}: {1}" -f $m, $_.Exception.Message); $script:fail++ }
}
Write-Host ('-' * 70)

# ---- 1. EC 通道 ----
T 'Test-DchuHasDataEx' { Test-DchuHasDataEx }
T 'Get-AppSetting.PowerMode' { (Get-AppSetting -Id 'PowerMode').Int }
T 'Get-AppSetting.FanMode' { (Get-AppSetting -Id 'FanMode').Int }
T 'Get-AppSetting.GpuMode' { ([regex]::Match((Get-DchuSummary | Out-String),'GpuMode\s*=\s*(\S+)').Groups[1].Value) }
T 'Get-ClevoTelemetry' {
    $t = Get-ClevoTelemetry
    'cpu={0}°C gpu={1}°C cpuRpm={2} gpuRpm={3}' -f $t.CpuTemp, $t.GpuTemp, $t.CpuFanRpm, $t.GpuFanRpm
}
T 'Get-ClevoState' { $s = Get-ClevoState; 'power={0} fan={1}' -f $s.PowerMode, $s.FanMode }
T 'Get-GpuMode' { $g = Get-GpuMode; 'active={0} supported={1}' -f $g.Active, $g.Supported }
T 'Get-FlexiCharger' { $c = Get-FlexiCharger; 'enabled={0} start={1} stop={2}' -f $c.Enabled, $c.Start, $c.Stop }
T 'Get-KeyboardSetting' { $k = Get-KeyboardSetting; 'fn={0} win={1} swap={2}' -f $k.FnLock, $k.WinKey, $k.Swap }
T 'Get-ClevoFanCurve' { $c = Get-ClevoFanCurve; 'nodes={0}' -f ($c.Nodes.Count) }
T 'Get-FanRuntimeCurve' { $c = Get-FanRuntimeCurve; 'nodes={0}' -f ($c.Count) }
T 'Get-LedModeFromAppSettings' { Get-LedModeFromAppSettings }
T 'Read-LedFeature' { $c = Get-LedCollection; if (-not $c) { throw '没枚举到 HID 集合' }; $r = Read-LedFeature -Collection $c -ReportId 0xCC; 'cols={0} rc={1}' -f $c.Count, $r.Rc }

# ---- 2. 系统只读 ----
T 'Get-BatteryState' { $b = Get-BatteryState; 'pct={0}% ac={1}' -f $b.Percent, $b.OnAc }
T 'Get-BatteryHealth' { $h = Get-BatteryHealth; 'health={0}% design={1} full={2}' -f $h.HealthPct, $h.Design, $h.Full }
T 'Get-ScreenBrightness' { 'bright={0}%' -f (Get-ScreenBrightness).Percent }
T 'Get-InputDevices' { $d = Get-InputDevices; 'kb={0} | tp={1}' -f $d.Keyboard, $d.Touchpad }
T 'Get-NumLockState' { 'numlock={0}' -f (Get-NumLockState) }
T 'Get-TouchPadState' { $t = Get-TouchPadState; 'enabled={0}' -f $t.Enabled }
T 'Get-AutostartState' { 'enabled={0} path={1}' -f (Get-AutostartState).Enabled, (Get-AutostartTarget) }

# ---- 3. 纯函数 ----
T 'Compare-AppVersion 1.10>1.9' { if ((Compare-AppVersion 'v1.10' 'v1.9') -le 0) { throw '比较错误' } else { 'v1.10 > v1.9 ✔' } }
T 'Compare-AppVersion 1.3==v1.3' { if ((Compare-AppVersion '1.3' 'v1.3') -ne 0) { throw '比较错误' } else { '相等 ✔' } }
T 'New-SceneRequest' { $r = New-SceneRequest -Index 1 -Auto $false; 'kind={0} label={1} power={2} fan={3}' -f $r.Kind, $r.Label, $r.Power, $r.Fan }
T 'Test-ReqSlotFree' { 'free={0}' -f (Test-ReqSlotFree) }
T 'New-PillXaml' { $x = New-PillXaml 'ZZ1' $script:PowerPills 70; if ($x -notmatch 'x:Name="ZZ10"') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-AboutRowXaml' { $x = New-AboutRowXaml 'ZZ2' '标签'; if ($x -notmatch 'x:Name="ZZ2"') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-SwitchRowXaml' { $x = New-SwitchRowXaml 'ZZ3' '开关'; if ($x -notmatch 'ZZ3') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-StepperXaml' { $x = New-StepperXaml 'ZZ4'; if ($x -notmatch 'ZZ4') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-ColorWheelBitmap' { $b = New-ColorWheelBitmap; 'wheel={0}x{1}' -f $b.PixelWidth, $b.PixelHeight }
T 'Get-RgbIndex' { 'idx={0}' -f (Get-RgbIndex 'static') }
T 'New-FanCurveFrame' { $f = New-FanCurveFrame -Fans (Get-FanRuntimeCurve); 'frame={0} 字节' -f $f.Length }
T 'New-LedFrame' { $f = New-LedFrame -Mode 'static' -R 255 -G 70 -B 70 -Brightness 6 -Speed 5; 'cmd 0x{0:X2} len={1}' -f $f[0], $f.Length }
T 'Test-FanCurve' { $r = Test-FanCurve -Fans (Get-FanRuntimeCurve); 'fans={0}' -f @($r).Count }
T 'Test-ClosureScopeTrap' { $r = Test-ClosureScopeTrap; '坑={0}' -f $r.Count }

Write-Host ('-' * 70)
Write-Host ("结论：PASS={0}  FAIL={1}" -f $pass, $fail)
Write-Host 'FUNC-PROBE DONE'
