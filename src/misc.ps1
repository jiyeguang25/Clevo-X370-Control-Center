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
