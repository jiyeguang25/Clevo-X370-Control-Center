# 代码层功能探针：只调用只读/纯函数（不写 EC、不启动窗口）。
# 必须在 src 目录下运行（模块用 $PSScriptRoot 找 dll/驱动/资源）。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
$ErrorActionPreference = 'Continue'
$src = $PSScriptRoot
$pass = 0; $fail = 0; $skip = 0
$log = Join-Path $env:TEMP 'clevo-func-probe.log'
$script:LogPath = $log
$script:Sync = [hashtable]::Synchronized(@{ Pending = $null; Status = '' })

function S([string]$name, [string]$why) {
    Write-Host ('SKIP  {0,-24} {1}' -f $name, $why)
    $script:skip++
}

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
T 'Get-WmiPackage.13' { $b = (Get-WmiPackage 13).Bytes; if ($b.Length -ne 256) { throw ('block13 长度 ' + $b.Length) }; 'bytes=256' }
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
T 'Read-LedFeature' {
  $cols = @(Get-LedCollection)
  if ($cols.Count -eq 0) { throw '没枚举到 HID 集合' }
  $c = $cols | Where-Object { $_.HwId -like '*col02*' } | Select-Object -First 1
  if (-not $c) { $c = $cols[0] }
  $r = Read-LedFeature -Collection $c -ReportId 0xCC
  'cols={0} len={1}' -f $cols.Count, $r.Length
}

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
T 'New-PillXaml' { $x = New-PillXaml 'ZZ1' @(@{ Label = '自动' }, @{ Label = '性能' }, @{ Label = '静音' }) 70; if ($x -notmatch 'x:Name="ZZ10"') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-AboutRowXaml' { $x = New-AboutRowXaml 'ZZ2' '标签'; if ($x -notmatch 'x:Name="ZZ2"') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-SwitchRowXaml' { $x = New-SwitchRowXaml 'ZZ3' '开关'; if ($x -notmatch 'ZZ3') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
T 'New-StepperXaml' { $x = New-StepperXaml 'ZZ4'; if ($x -notmatch 'ZZ4') { throw '没生成名字' } else { 'ok ' + $x.Length + ' 字符' } }
S 'New-ColorWheelBitmap' '类型由 ClevoHelper.ps1 启动时 Add-Type 注册；专项验证用 src\diag-colorwheel.ps1'
T 'Get-RgbIndex' { 'idx={0}' -f (Get-RgbIndex 'static') }
T 'New-FanCurveFrame' {
  # 注意：Get-FanRuntimeCurve 的 D1..D4 是原始 0-255，New-FanCurveFrame 要百分比（P1..P4）。
  $pct = Get-FanRuntimeCurve | ForEach-Object { [pscustomobject]@{ T1=$_.T1; T2=$_.T2; T3=$_.T3; T4=$_.T4; D1=$_.P1; D2=$_.P2; D3=$_.P3; D4=$_.P4 } }
  $f = New-FanCurveFrame -Fans $pct; 'frame={0} 字节' -f $f.Length
}
T 'New-FanCurveFrame 单位护栏' {
  try { New-FanCurveFrame -Fans @([pscustomobject]@{ T2=60; T3=80; D2=428; D3=400 }) | Out-Null; throw '护栏没生效（应当抛错）' }
  catch { if ($_ -like '*要百分比*') { '正确拒绝' } else { throw } }
}
T 'New-LedFrame' { $f = New-LedFrame -Mode 'static' -R 255 -G 70 -B 70 -Brightness 6 -Speed 5; 'cmd 0x{0:X2} len={1}' -f $f[0], $f.Length }
T 'Test-FanCurve' { $r = Test-FanCurve -Fans (Get-FanRuntimeCurve); 'fans={0}' -f @($r).Count }
T 'Test-ClosureScopeTrap' { $r = Test-ClosureScopeTrap; '坑={0}' -f $r.Count }

Write-Host ('-' * 70)
Write-Host ("结论：PASS={0}  FAIL={1}" -f $pass, $fail)
Write-Host 'FUNC-PROBE DONE'
