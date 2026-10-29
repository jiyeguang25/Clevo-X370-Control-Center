# misc.ps1 - the switches on the 杂项 tab that are NOT DCHU byte channels.
#
# Three of them, each with a real read-back:
#   屏幕亮度  WMI (WmiMonitorBrightnessMethods.WmiSetBrightness / WmiMonitorBrightness)
#   触控板    HKCU\...\PrecisionTouchPad\Status\Enabled + the vendor's own notification
#   数字键盘  the session's NumLock state ([Console]::NumberLock)
#
# ---------------- 触控板 ------------------------------------------------------
# Decoded from CLEVOCO.FnhotkeysandOSD (FnKey.Features):
#   GetI2C_TP()   = Registry.GetValue("HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\
#                   CurrentVersion\PrecisionTouchPad\Status", "Enabled", 0)
#   SetI2C_TP(v)  = write that value, then Send_Win_Ctrl_F24() to make the driver take it
#   Send_Win_Ctrl_F24() = keybd_event(17,VK_CONTROL down); keybd_event(91,VK_LWIN down);
#                         keybd_event(135,VK_F24 down); then the same three as key-up
#                         (VK 17/91/135 = Ctrl / Left Windows / F24)
# The key order is the vendor's, copied exactly - the notification is matched by the
# touchpad driver, so "equivalent" is not good enough here.
# The AppSetting TouchPadStatus (0x10A) is only the vendor's mirror of the same flag, so it
# is written too, but the registry value is what is read back as the verification.
$script:TouchPadStatusId = 0x10A      # page 1, offset 0x0A
$script:TouchPadRegPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PrecisionTouchPad\Status'

if (-not ('ClevoHelper.MiscNative' -as [type])) {
    Add-Type -Namespace ClevoHelper -Name MiscNative -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
[DllImport("user32.dll")]
public static extern short GetKeyState(int nVirtKey);
'@
}

function Send-WinCtrlF24 {
    <#
      .SYNOPSIS The touchpad-toggle notification, byte-for-byte from the vendor.
    #>
    [CmdletBinding()]
    param()
    $up = [uint32]2
    $z = [IntPtr]::Zero
    [ClevoHelper.MiscNative]::keybd_event(0x11, 0, 0, $z)     # Ctrl down
    [ClevoHelper.MiscNative]::keybd_event(0x5B, 0, 0, $z)     # Win  down
    [ClevoHelper.MiscNative]::keybd_event(0x87, 0, 0, $z)     # F24  down
    [ClevoHelper.MiscNative]::keybd_event(0x11, 0, $up, $z)   # Ctrl up
    [ClevoHelper.MiscNative]::keybd_event(0x5B, 0, $up, $z)   # Win  up
    [ClevoHelper.MiscNative]::keybd_event(0x87, 0, $up, $z)   # F24  up
}

function Get-TouchPadState {
    <#
      .SYNOPSIS Is the Precision touchpad enabled? READ ONLY (the vendor's own source).
    #>
    [CmdletBinding()]
    param()
    try {
        $v = (Get-ItemProperty -LiteralPath $script:TouchPadRegPath -Name 'Enabled' -ErrorAction Stop).Enabled
        [pscustomobject]@{ Supported = $true; Enabled = ([int]$v -ne 0); Raw = [int]$v }
    }
    catch {
        [pscustomobject]@{ Supported = $false; Enabled = $null; Raw = $null; Error = $_.Exception.Message }
    }
}

function Set-TouchPadState {
    <#
      .SYNOPSIS Enable/disable the touchpad: registry value + the driver notification.
      .NOTES    Reads the registry back afterwards. That proves the flag was stored; whether
                the pad itself responded can only be felt, so the caller must not claim more.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled, [switch]$Apply)
    $before = Get-TouchPadState
    if (-not $before.Supported) { throw ('本机没有 PrecisionTouchPad 状态键：{0}' -f $before.Error) }
    if (-not $Apply) {
        Write-Host ('  [dry-run] PrecisionTouchPad\Status\Enabled = {0} + Ctrl+Win+F24' -f [int]$Enabled)
        return [pscustomobject]@{ Applied = $false; Before = $before }
    }
    Set-ItemProperty -LiteralPath $script:TouchPadRegPath -Name 'Enabled' -Value ([int]$Enabled) -Type DWord
    Send-WinCtrlF24
    Start-Sleep -Milliseconds 250
    $after = Get-TouchPadState
    if (Get-Command Set-AppSettingByte -ErrorAction SilentlyContinue) {
        $page = $script:TouchPadStatusId -shr 8
        $off = $script:TouchPadStatusId -band 0xFF
        Set-AppSettingByte -Page $page -Patch @{ $off = [int]$Enabled } -Apply | Out-Null
    }
    [pscustomobject]@{
        Applied = $true
        Ok      = ($after.Enabled -eq $Enabled)
        Before  = $before.Enabled
        After   = $after.Enabled
        Note    = '注册表读回一致；触控板是否真的响应只有手指能确认'
    }
}

# ---------------- 数字键盘 (NumLock) -----------------------------------------
# There is NO DCHU/EC setting for NumLock on this machine: the factory Control Center only
# publishes a "NumLk" tray message (CCToHKTray), and 0x109 is that message id, not an
# AppSetting - writing it as one would be a guess. What every OS-level tool does instead is
# toggle the session's NumLock key, which is exactly what the user sees as the NumLock lamp,
# and [Console]::NumberLock reads the same state back.
$script:VkNumLock = 0x90

function Get-NumLockState {
    <#
      .SYNOPSIS The session's NumLock state. READ ONLY.
      .NOTES    [Console]::NumberLock is the documented read, but it THROWS when the process
                has no console at all - which is exactly the packaged panel (the launcher is
                compiled /target:winexe). GetKeyState(VK_NUMLOCK) reads the same toggle bit
                through user32 and works there, so it is the fallback. The console API stays
                first because it is the one that is correct on a console host.
    #>
    [CmdletBinding()]
    param()
    $on = $null
    try { $on = [bool][Console]::NumberLock } catch { }
    if ($null -eq $on) {
        try { $on = [bool](([ClevoHelper.MiscNative]::GetKeyState($script:VkNumLock) -band 1) -ne 0) }
        catch { }
    }
    [pscustomobject]@{ On = $on; Source = $(if ($null -eq $on) { 'unavailable' } else { 'ok' }) }
}

function Set-NumLockState {
    <#
      .SYNOPSIS Toggle NumLock (OS level) and read the state back.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$On, [switch]$Apply)
    $before = Get-NumLockState
    if (-not $Apply) {
        Write-Host ('  [dry-run] keybd_event(VK_NUMLOCK) -> {0}' -f $On)
        return [pscustomobject]@{ Applied = $false; Before = $before.On }
    }
    if ($before.On -ne $On) {
        $z = [IntPtr]::Zero
        [ClevoHelper.MiscNative]::keybd_event([byte]$script:VkNumLock, 0, 0, $z)
        [ClevoHelper.MiscNative]::keybd_event([byte]$script:VkNumLock, 0, [uint32]2, $z)
        Start-Sleep -Milliseconds 150
    }
    $after = Get-NumLockState
    [pscustomobject]@{ Applied = $true; Ok = ($after.On -eq $On); Before = $before.On; After = $after.On }
}

# ---------------- 电池状态 ---------------------------------------------------
# Shown at the top of the 杂项 tab so the charge limit's effect is visible right next to it.
# Win32_Battery: EstimatedChargeRemaining (%), BatteryStatus (1 = discharging, 2 = AC).
# Both are OS numbers, not EC ones - the EC side of the same story is the FlexiCharger read.
function Get-BatteryState {
    <#
      .SYNOPSIS Charge percent and AC/discharge state. READ ONLY.
    #>
    [CmdletBinding()]
    param()
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if (-not $b) { return [pscustomobject]@{ Supported = $false } }
        [pscustomobject]@{
            Supported = $true
            Percent   = [int]$b.EstimatedChargeRemaining
            Status    = [int]$b.BatteryStatus
            OnAc      = ([int]$b.BatteryStatus -eq 2)
            Name      = "$($b.Name)".Trim()
        }
    }
    catch { [pscustomobject]@{ Supported = $false; Error = $_.Exception.Message } }
}

# ---------------- 电池健康 ---------------------------------------------------
function Get-BatteryHealth {
    <#
      .SYNOPSIS Design / full-charge capacity, cycle count, voltage. READ ONLY, slow (WMI+DCOM).
      .DESCRIPTION 只在启动时调用一次（电池页用它算损耗）。
      这里**必须**用 Get-WmiObject 而不是 Get-CimInstance：本机实测 root\wmi 的
      BatteryStaticData 走 CIM 会抛「更具体的错误代码不包含发生的常规错误」，走 DCOM 读得到
      （DesignedCapacity=103056 mWh）。同理 BatteryFullChargedCapacity=91352。
      CycleCount 这台机器恒为 0（不报），所以健康度只按「满充/设计」，循环次数显示「—」。
    #>
    [CmdletBinding()]
    param()
    $r = [ordered]@{ Supported = $false }
    try {
        $sd = Get-WmiObject -Namespace root\wmi -Class BatteryStaticData -ErrorAction Stop | Select-Object -First 1
        if ($sd -and [int]$sd.DesignedCapacity -gt 0) {
            $r.Supported = $true
            $r.Design = [int]$sd.DesignedCapacity
            # 本机 BatteryCycleCount 恒为 0（电池不实现该 SMART 字段），所以界面上这一格
            # 显示制造日期——它是真值，也能用来判断电池年龄。
            try { if ($sd.ManufactureDate) { $r.Made = [string]$sd.ManufactureDate } } catch { }
                    # 静态身份：运行期不变，电池页用来回答"这块电池是谁"。
                    try { if ($sd.ManufactureName) { $r.Mfr = [string]$sd.ManufactureName } } catch { }
                    try { if ($sd.DeviceName) { $r.Dev = [string]$sd.DeviceName } } catch { }
                    try {
                        # Chemistry 是 SmartBattery 规范：4 个 ASCII 字符按小端塞进一个 DWORD。
                        # 本机实测 0x4E4F494C → 字节 4C 49 4F 4E → "LION"（锂离子）。
                        # 以前直接 ToString() 把 1313818956 丢到界面上，用户看到的是个无意义大数。
                        if ($sd.Chemistry) {
                            $cb = [BitConverter]::GetBytes([uint32]$sd.Chemistry)
                            $cs = -join ($cb | ForEach-Object { [char]$_ })
                            if ($cs -eq 'LION') { $r.Chem = '锂离子 LION' }
                            elseif ($cs -eq 'LIP') { $r.Chem = '锂聚合物 LIP' }
                            elseif ($cs -match '^[\x20-\x7E]{4}$') { $r.Chem = $cs }
                        }
                    } catch { }
            try {
                $fc = Get-WmiObject -Namespace root\wmi -Class BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($fc -and [int]$fc.FullChargedCapacity -gt 0) {
                    $r.Full = [int]$fc.FullChargedCapacity
                    $r.Health = [Math]::Round((100.0 * $r.Full / $r.Design), 1)
                }
            } catch { }
            try {
                $cc = Get-WmiObject -Namespace root\wmi -Class BatteryCycleCount -ErrorAction Stop | Select-Object -First 1
                if ($cc -and [int]$cc.CycleCount -gt 0) { $r.Cycles = [int]$cc.CycleCount }
            } catch { }
            try {
                $st = Get-WmiObject -Namespace root\wmi -Class BatteryStatus -ErrorAction Stop | Select-Object -First 1
                if ($st) {
                    if ([int]$st.RemainingCapacity -gt 0) { $r.Now = [int]$st.RemainingCapacity }
                    if ([int]$st.Voltage -gt 0) { $r.VoltMv = [int]$st.Voltage }
                    # 充/放电功率（mW）与电池温度（十分之一开尔文）。两者都可能为 0/不报，
                    # 交给界面显示「—」，不在这里猜。
                    if ($null -ne $st.ChargeRate) { $r.ChargeMw = [int]$st.ChargeRate }
                    if ($null -ne $st.DischargeRate) { $r.DischargeMw = [int]$st.DischargeRate }
                    if ($null -ne $st.Temperature) { $r.TempK10 = [int]$st.Temperature }
                }
            } catch { }
        }
    }
    catch { $r.Error = $_.Exception.Message }
    [pscustomobject]$r
}

# ---------------- 输入设备 ---------------------------------------------------
function Get-InputDevices {
    <#
      .SYNOPSIS 键盘灯走的是哪一路 HID、触控板挂在哪条总线上。READ ONLY, slow (PnP enumeration).
      .DESCRIPTION 启动时读一次。键盘灯判据与 kbled.ps1 完全相同（VID_048D&PID_8910 = ITE 829x），
      因为那一路上写命令的正是它；这里显示出来是为了"灯不亮时先看有没有认到设备"。
    #>
    [CmdletBinding()]
    param()
    $kb = '--'
    $tp = '--'
    try {
        $dev = Get-PnpDevice -Class HIDClass -ErrorAction Stop |
            Where-Object { $_.InstanceId -match 'VID_048D&PID_8910' } | Select-Object -First 1
        $kb = $(if ($dev) { 'VID_048D / PID_8910 · ITE 829x' } else { '未认到（键盘灯会失效）' })
    }
    catch { $kb = '查询失败' }
    try {
        $m = Get-PnpDevice -Class Mouse -ErrorAction Stop |
            Where-Object { $_.Status -eq 'OK' -and $_.InstanceId -match 'HID|I2C|PS2' } |
            Sort-Object -Property @{ Expression = { $(if ($_.InstanceId -match '^I2C') { 0 } elseif ($_.InstanceId -match '^PS2') { 1 } else { 2 }) } } |
            Select-Object -First 1
        if ($m) {
            $bus = $(if ($m.InstanceId -match '^I2C') { 'I2C HID' } elseif ($m.InstanceId -match '^PS2') { 'PS/2' } else { 'HID' })
            $tp = ('{0} · {1}' -f $m.FriendlyName, $bus)
        }
    }
    catch { $tp = '查询失败' }
    [pscustomobject]@{ Keyboard = $kb; Touchpad = $tp }
}

# ---------------- 屏幕亮度 ---------------------------------------------------
function Get-ScreenBrightness {
    <#
      .SYNOPSIS Current panel brightness in percent. READ ONLY.
    #>
    [CmdletBinding()]
    param()
    $m = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $m) { return [pscustomobject]@{ Supported = $false; Percent = $null } }
    [pscustomobject]@{ Supported = $true; Percent = [int]$m.CurrentBrightness }
}

function Set-ScreenBrightness {
    <#
      .SYNOPSIS Set panel brightness (percent) through WMI and read it back.
      .NOTES    -Quick writes and returns immediately without the settle sleep or the
                read-back. That is for the middle of a slider drag: the settle+verify pair
                costs ~0.4s, which is exactly what made dragging feel like it was stepping.
                The end of the drag always does a full, verified write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(0, 100)][int]$Percent, [switch]$Apply, [switch]$Quick)
    $before = Get-ScreenBrightness
    if (-not $before.Supported) { throw '本机 WMI 不提供亮度控制（外接屏/驱动不支持）' }
    if (-not $Apply) {
        Write-Host ('  [dry-run] WmiSetBrightness(0, {0})' -f $Percent)
        return [pscustomobject]@{ Applied = $false; Before = $before.Percent }
    }
    $meth = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop |
        Select-Object -First 1
    if (-not $meth) { throw 'WmiMonitorBrightnessMethods 不可用' }
    [void](Invoke-CimMethod -InputObject $meth -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$Percent })
    if ($Quick) {
        return [pscustomobject]@{ Applied = $true; Quick = $true; Ok = $null; Before = $before.Percent; After = $null }
    }
    Start-Sleep -Milliseconds 250
    $after = Get-ScreenBrightness
    [pscustomobject]@{ Applied = $true; Quick = $false; Ok = ([Math]::Abs($after.Percent - $Percent) -le 1); Before = $before.Percent; After = $after.Percent }
}

# ---------------- 电池报告 / 容量历史 -----------------------------------------
# Windows 自己每周记一次"满充容量"，这份数据只有 powercfg /batteryreport 的 HTML 里有。
# 循环次数这块电池不提供（报告里 CYCLE COUNT 是空的），但容量历史是实的，衰减看得见。
function Get-BatteryReportPath {
    <# 报告落在 artifacts 目录，和日志放一起。 #>
    [CmdletBinding()] param()
    $dir = Join-Path $env:LOCALAPPDATA 'ClevoHelper\artifacts'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir 'battery-report.html'
}

function Update-BatteryReport {
    <# 生成 Windows 电池报告。约 1 秒。返回 @{ Ok; Path; Error }。 #>
    [CmdletBinding()] param()
    $p = Get-BatteryReportPath
    try {
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        $exe = Join-Path $env:WINDIR 'System32\powercfg.exe'
        $out = & $exe /batteryreport /output $p 2>&1
        if (-not (Test-Path $p)) { return [pscustomobject]@{ Ok = $false; Path = $p; Error = ([string]$out) } }
        [pscustomobject]@{ Ok = $true; Path = $p; Error = '' }
    }
    catch { [pscustomobject]@{ Ok = $false; Path = $p; Error = $_.Exception.Message } }
}

function Get-BatteryHistory {
    <# 满充容量历史（7 天一段）。7 天内复用缓存，避免每次启动都跑 powercfg。 #>
    [CmdletBinding()]
    param([switch]$Refresh)
    $cache = Join-Path (Split-Path -Parent (Get-BatteryReportPath)) 'battery-history.json'
    if (-not $Refresh -and (Test-Path $cache)) {
        try {
            $c = Get-Content $cache -Raw -Encoding UTF8 | ConvertFrom-Json
            # At 必须是 ISO 字符串（见下面写回）；老缓存里可能是 ConvertTo-Json 把 DateTime
            # 展开成的 @{value=...; DateTime=...}，两种都认，认不出就当缓存过期重算。
            $at = $null
            try {
                if ($c.At -is [string]) { $at = [datetime]::Parse($c.At) }
                elseif ($c.At.value) { $at = [datetime]$c.At.value }
                elseif ($c.At) { $at = [datetime]$c.At }
            }
            catch { }
            if ($at -and ((Get-Date) - $at).TotalDays -lt 7 -and $c.Points) {
                return [pscustomobject]@{ Source = 'cache'; At = $at; Points = @($c.Points); Error = '' }
            }
        }
        catch { }
    }
    $r = Update-BatteryReport
    if (-not $r.Ok) { return [pscustomobject]@{ Source = 'none'; At = $null; Points = @(); Error = $r.Error } }
    $pts = @()
    try {
        $h = [System.IO.File]::ReadAllText($r.Path)
        $flat = ($h -replace '(?s)<style.*?</style>', '' -replace '(?s)<script.*?</script>', '' -replace '<[^>]+>', ' ' -replace '&nbsp;', '') -replace '\s+', ' '
        foreach ($m in [regex]::Matches($flat, '(\d{4}-\d{2}-\d{2})\s*-\s*(\d{4}-\d{2}-\d{2})\s*([\d,]+)\s*mWh\s*([\d,]+)\s*mWh')) {
            $full = [int]($m.Groups[3].Value -replace ',', '')
            $des = [int]($m.Groups[4].Value -replace ',', '')
            if ($des -gt 0 -and $full -gt 0) {
                $pts += [pscustomobject]@{
                    Start  = $m.Groups[1].Value
                    End    = $m.Groups[2].Value
                    Full   = $full
                    Design = $des
                    Health = [Math]::Round(100.0 * $full / $des, 1)
                }
            }
        }
    }
    catch { }
    # At 一定写成 ISO 字符串：ConvertTo-Json 在 5.1 里会把 DateTime 展开成 @{value;DisplayHint;DateTime}，
    # 下次 ConvertFrom-Json 回来就再也转不回 DateTime，缓存永远失效（踩过）。
    try { [pscustomobject]@{ At = (Get-Date).ToString('o'); Points = $pts } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cache -Encoding UTF8 } catch { }
    [pscustomobject]@{ Source = 'report'; At = (Get-Date); Points = $pts; Error = '' }
}

function Format-Sparkline {
    <# 把一串数值画成 ▁▂▃▄▅▆▇█ 的火花线。少于两点返回「—」。 #>
    [CmdletBinding()]
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -lt 2) { return '—' }
    $blocks = @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    if ($max -eq $min) { return (-join ($blocks[4] * $Values.Count)) }
    -join ($Values | ForEach-Object { $blocks[[int][Math]::Round(($_-$min)/($max-$min)*7)] })
}