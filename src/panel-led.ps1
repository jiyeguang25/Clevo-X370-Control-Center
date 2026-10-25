# panel-led.ps1 —— 键盘灯：RGB 模式/颜色/亮度/方向，色盘取色
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

# What the keyboard tab is currently set to. The LED hardware reports nothing back, so this
# session-side state is what the UI shows; the AppSettings mirror is the verification.
# default colour indices are looked up by label: inserting 彩虹 at the front shifted every
# index, and a hardcoded number would silently point at a different colour
function Get-RgbIndex([string]$label) {
    for ($i = 0; $i -lt $script:RgbPills.Count; $i++) { if ($script:RgbPills[$i].Label -eq $label) { return $i } }
    return 0
}

# ---- 键盘灯：存下来 + 开机注入回去 -------------------------------------------
# 用户报："键盘灯每次都会重置"。原因是**灯控芯片断电就忘**：EC 的 AppSettings 镜像还在
# （page 2 那套 Status/Effect 字节，重启后读得到），但面板以前只是把镜像读出来**显示**，
# 从来没有把它发回键盘 —— 所以每次开机键盘都是灭的，UI 却显示"静态/白"。
# 现在：你每次改灯（Request-Led）就存进 settings.json；启动时按下面的顺序**注入一次**：
#   ① settings.json 里的 Led（你在面板里最后调的那套）
#   ② 没有就用 EC 镜像里那套（原厂/以前设过的，重启后仍然在）
#   ③ 都没有，或者那个模式不是面板提供的五个 → 什么都不发（不猜、不动键盘）
function Save-LedConfig {
    $s = $script:LedSel
    $script:Settings.Led = @{
        Mode = [string]$s.Mode; Color = [int]$s.Color; Rainbow = [bool]$s.Rainbow
        UseCustom = [bool]$s.UseCustom
        R = [int]$s.Custom.R; G = [int]$s.Custom.G; B = [int]$s.Custom.B
        Bright = [int]$s.Bright; Speed = [int]$s.Speed
    }
    Save-Settings
    $script:LedConfigSource = 'settings'
}

function Set-LedSelFromConfig($cfg) {
    # 把一份配置（settings 里的 Led 对象，或 EC 镜像解出来的东西）填进 LedSel
    for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
        if ($script:LedModePills[$i].Key -eq [string]$cfg.Mode) { $script:LedSel.ModeIdx = $i; $script:LedSel.Mode = [string]$cfg.Mode; break }
    }
    $script:LedSel.Rainbow = [bool]$cfg.Rainbow
    if ($null -ne $cfg.R -and $cfg.UseCustom) {
        $script:LedSel.UseCustom = $true
        $script:LedSel.Custom = @{ R = [int]$cfg.R; G = [int]$cfg.G; B = [int]$cfg.B }
    }
    elseif ($null -ne $cfg.Color) {
        $script:LedSel.UseCustom = $false
        $script:LedSel.Color = [int]$cfg.Color
    }
    if ($null -ne $cfg.Bright -and [int]$cfg.Bright -ge 0 -and [int]$cfg.Bright -lt $script:RgbBrightness.Count) { $script:LedSel.Bright = [int]$cfg.Bright }
    if ($null -ne $cfg.Speed -and [int]$cfg.Speed -ge 0 -and [int]$cfg.Speed -lt $script:LedSpeedPills.Count) { $script:LedSel.Speed = [int]$cfg.Speed }
}

function New-ColorWheelBitmap([int]$size) {
    $bmp = New-Object System.Windows.Media.Imaging.WriteableBitmap($size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Bgra32), $null)
    $px = [ClevoHelper.ColorWheel]::Pixels($size)
    $bmp.WritePixels((New-Object System.Windows.Int32Rect(0, 0, $size, $size)), $px, ($size * 4), 0)
    $bmp.Freeze()
    return $bmp
}

function Request-Rgb {
    param([int]$R, [int]$G, [int]$B, [int]$Brightness = -1)
    $script:Sync.Pending = [pscustomobject]@{ Kind = 'rgb'; R = $R; G = $G; B = $B; Brightness = $Brightness; At = (Get-Date) }
    $n.StatusText.Text = '正在设置键盘灯…（整键盘重绘约 0.3 秒）'
}

# ---- 键盘灯：模式驱动 ------------------------------------------------------
# One "current selection" drives everything: picking a colour or a speed re-sends the whole
# selection, so the effect changes colour live instead of needing a "apply" button.
function Request-Led {
    param([switch]$Startup)
    $sel = $script:LedSel
    # The wheel's colour wins only while the user is in "custom" mode: clicking a preset
    # swatch clears UseCustom, so the two ways of choosing a colour never fight.
    if ($sel.UseCustom) {
        $c = [pscustomobject]@{ R = [int]$sel.Custom.R; G = [int]$sel.Custom.G; B = [int]$sel.Custom.B }
    }
    else {
        $c = $script:RgbPills[[int]$sel.Color]
    }
    $c2 = $script:RgbPills[[int]$sel.Color2]
    $script:Sync.Pending = [pscustomobject]@{
        Kind = 'led'
        Startup = [bool]$Startup
        Mode = [string]$sel.Mode
        ModeLabel = [string]$script:LedModePills[[int]$sel.ModeIdx].Label
        # No mode offered here is directional or two-coloured any more, so these stay at their
        # defaults and are never edited from the UI - they are still sent because the sampler's
        # frame builder takes them (kbled.ps1 keeps the full vendor protocol).
        Dir = [int]$sel.Dir
        R = [int]$c.R; G = [int]$c.G; B = [int]$c.B
        R2 = [int]$c2.R; G2 = [int]$c2.G; B2 = [int]$c2.B
        Rainbow = [bool]$sel.Rainbow
        Bright = [int]$script:RgbBrightness[[int]$sel.Bright].Level
        Speed = [int]$script:LedSpeedPills[[int]$sel.Speed].Level
        At = (Get-Date)
    }
    $n.StatusText.Text = ('正在应用键盘灯：{0} …' -f $script:LedModePills[[int]$sel.ModeIdx].Label)
    # 你按下去的这一套就是"我的键盘灯"：存进 settings.json，下次开机注入回键盘
    # （灯控芯片断电就忘，这是唯一能让它自己回来的办法 —— 见 Save-LedConfig 上面的说明）
    Save-LedConfig
}

# 选了颜色以后该做什么：当前模式用颜色就立刻写，不用（关闭/循环）就只记住并说清楚。
# 以前无论如何都发一次写入，模式是「关闭」时那就是"点了没反应" —— 现在两种情况都说得明白。
function Update-LedColorSelection {
    $mi = [int]$script:LedSel.ModeIdx
    $mp = $(if ($mi -ge 0 -and $mi -lt $script:LedModePills.Count) { $script:LedModePills[$mi] } else { $script:LedModePills[0] })
    if ([int]$mp.Colors -ge 1) { Request-Led }
    else {
        $n.StatusText.Text = ('已记住颜色；「{0}」不用颜色，切到 静态/波/呼吸 立刻生效' -f $mp.Label)
        $n.StatusText.Foreground = Get-Brush '#FF8A93A6'
    }
}

function Set-LedFromWheel([double]$x, [double]$y) {
    $size = [int]$script:WheelSize
    $p = [ClevoHelper.ColorWheel]::Pick($x, $y, $size)
    if ($null -eq $p) { return }         # outside the circle: nothing to pick
    $script:LedSel.Custom = @{ R = [int]$p[0]; G = [int]$p[1]; B = [int]$p[2] }
    $script:LedSel.UseCustom = $true
    $script:LedSel.Rainbow = $false      # picking a colour means "not multi-colour"
    $script:WheelHue = [int]$p[3]; $script:WheelSat = [int]$p[4]
    Update-LedColorSelection
}

