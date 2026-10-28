# panel-core.ps1 —— 基础工具：存取配置、写日志、请求槽、XAML 小控件构造器
#
# 由 ClevoHelper.ps1 用 dot-source 载入：所有 panel-*.ps1 共享**同一个脚本作用域**，
# 不是 PowerShell 模块（没有 Import-Module、没有独立作用域）。所以：
#   * 这里只放函数定义，不要写顶层可执行语句；
#   * $script: 开头的变量是全体共享的，改之前先想清楚谁会读到它；
#   * 界面控件都在主文件的 $n 里（$n.StatusText 这种），这里直接用即可。

function Save-Settings {
    try {
        # -Depth 8：FanCurve / Led / Saved 都是嵌套的哈希表，默认深度会把里面那层丢掉
        # （写出去只剩一个空对象）。Saved 里面还嵌着充电窗口，所以要更深。
        ($script:Settings | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { Write-Dbg ('settings save failed: ' + $_.Exception.Message) }
}

# "我的配置"里的一项改了 → 立刻存（用户要求：每次更改后保存，下次开机注入）
function Save-MyConfig([string]$Key, $Value) {
    if (-not $script:Settings.Saved) { $script:Settings.Saved = @{} }
    $script:Settings.Saved[$Key] = $Value
    Save-Settings
    Write-Dbg ('my config saved: {0} = {1}' -f $Key, $Value)
}

function Write-Dbg([string]$m) {
    try {
        # create the log directory on demand: when running from the packaged exe the whole
        # tree lives under %LOCALAPPDATA%\ClevoHelper and the artifacts folder does not
        # exist yet - Add-Content would throw and the panel would log NOTHING, silently.
        $dir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # keep the log bounded: a repeating error would otherwise grow it forever
        $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 1MB) {
            $keep = Get-Content -LiteralPath $script:LogPath -Tail 200 -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $script:LogPath -Value $keep -Encoding UTF8
            Add-Content -LiteralPath $script:LogPath -Value '(log truncated at 1 MB)' -Encoding UTF8
        }
        Add-Content -LiteralPath $script:LogPath -Value ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $m) -Encoding UTF8
    }
    catch { }
}

function New-PillXaml([string]$prefix, $pills, [int]$minW = 70) {
    # MinWidth + centred text instead of per-pill Padding: 自动 / 强冷 / 均衡 are
    # different lengths, and content-sized pills made every row look ragged. With a
    # fixed MinWidth all pills in a group are the same size and line up in columns.
    # The keyboard mode row passes a smaller width so its 9 modes still fit on one line.
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($p in $pills) {
        $tip = if ($p.ContainsKey('Tip')) { ' ToolTip="' + $p.Tip + '"' } else { '' }
        [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Background="#FF262A33" CornerRadius="13" MinWidth="{2}" Padding="0,5" Margin="0,0,7,0" Cursor="Hand"{3}>' -f $prefix, $i, $minW, $tip))
        [void]$sb.AppendLine(('  <TextBlock x:Name="{0}{1}T" Text="{2}" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>' -f $prefix, $i, $p.Label))
        [void]$sb.AppendLine('</Border>')
        $i++
    }
    $sb.ToString()
}

function New-SwatchXaml([string]$prefix, $pills) {
    # A swatch is either a solid colour or the 彩虹 entry ($RainbowSwatch), which gets a real
    # gradient brush so it reads as "multi-colour" rather than as one more colour.
    # 24px + a 5px gap: at the portrait width the content column is 326px wide and the panel
    # offers 10 swatches, so 26+7 (=330) did not fit and the last ones slid under the row's
    # hint text. Measured after the change: 10 x 29 = 290.
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($p in $pills) {
        if ($p.Swatch -eq $script:RainbowSwatch) {
            [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Width="24" Height="24" CornerRadius="12" Margin="0,0,5,0" Cursor="Hand" ToolTip="{2}">' -f $prefix, $i, $p.Label))
            [void]$sb.AppendLine('  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0">')
            [void]$sb.AppendLine('    <GradientStop Color="#FFFF3B30" Offset="0"/><GradientStop Color="#FFFFD60A" Offset="0.2"/>')
            [void]$sb.AppendLine('    <GradientStop Color="#FF32D74B" Offset="0.4"/><GradientStop Color="#FF64D2FF" Offset="0.6"/>')
            [void]$sb.AppendLine('    <GradientStop Color="#FF0A84FF" Offset="0.8"/><GradientStop Color="#FFBF5AF2" Offset="1"/>')
            [void]$sb.AppendLine('  </LinearGradientBrush></Border.Background>')
            [void]$sb.AppendLine('</Border>')
        }
        else {
            [void]$sb.AppendLine(('<Border x:Name="{0}{1}" Width="24" Height="24" CornerRadius="12" Background="{2}" Margin="0,0,5,0" Cursor="Hand" ToolTip="{3}"/>' -f $prefix, $i, $p.Swatch, $p.Label))
        }
        $i++
    }
    $sb.ToString()
}

function New-SwitchRowXaml([string]$prefix, [string]$label, $pills, [string]$hint, [int]$pillW = 46) {
    # label + pill pair + a SHORT note to the right of the buttons (user request).
    # It has been in both shapes now, and the rule that makes the right-hand column safe is
    # simply that the note stays short: the content column is 326px, two pills take 106px,
    # which leaves ~210px - about 17 Chinese characters at 11px. The earlier version of this
    # row used full sentences ('系统 NumLock（原厂无 EC 通道，走系统按键）', ~240px) and the
    # text landed on top of the 关 pill (measured: hint x=191, pills 105..204).
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('            <Grid Margin="0,0,0,9">')
    [void]$sb.AppendLine('              <Grid.ColumnDefinitions>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="66"/>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="*"/>')
    [void]$sb.AppendLine('                <ColumnDefinition Width="Auto"/>')
    [void]$sb.AppendLine('              </Grid.ColumnDefinitions>')
    [void]$sb.AppendLine(('              <TextBlock Grid.Column="0" Text="{0}" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>' -f $label))
    [void]$sb.AppendLine(('              <StackPanel Grid.Column="1" Orientation="Horizontal" x:Name="{0}Row">' -f $prefix))
    [void]$sb.Append((New-PillXaml $prefix $pills $pillW))
    [void]$sb.AppendLine('              </StackPanel>')
    [void]$sb.AppendLine(('              <TextBlock Grid.Column="2" Text="{0}" Foreground="#FF5A6273" FontSize="11" VerticalAlignment="Center" ToolTip="{1}"/>' -f $hint, $hint))
    [void]$sb.AppendLine('            </Grid>')
    $sb.ToString()
}

function New-StepperXaml([string]$prefix, [string]$caption, [string]$unit = '°C') {
    # − value unit + stepper.
    # The number sits right-aligned in a FIXED 34px box and the unit left-aligned in its own
    # 22px box (monospace). Centre-aligning "60 °C" / "100 °C" in one box made the digits and
    # the ± buttons slide sideways as the value changed - measured, not guessed.
    @"
              <StackPanel Orientation="Horizontal" Margin="0,0,20,0" VerticalAlignment="Center">
                <TextBlock Text="$caption" Foreground="#FF5A6273" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Border x:Name="${prefix}Minus" Background="#FF262A33" CornerRadius="11" MinWidth="26" Padding="0,3" Cursor="Hand">
                  <TextBlock Text="&#x2212;" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
                <TextBlock x:Name="${prefix}Val" Text="--" Foreground="#FFD7DCE6" FontFamily="Consolas" FontSize="13"
                           Width="34" TextAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="${prefix}Unit" Text="$unit" Foreground="#FF6B7385" FontFamily="Consolas" FontSize="11"
                           Width="22" TextAlignment="Left" VerticalAlignment="Center" Margin="3,0,3,0"/>
                <Border x:Name="${prefix}Plus" Background="#FF262A33" CornerRadius="11" MinWidth="26" Padding="0,3" Cursor="Hand">
                  <TextBlock Text="+" Foreground="#FF98A1B3" FontSize="12" TextAlignment="Center"/>
                </Border>
              </StackPanel>
"@
}

function New-AboutRowXaml([string]$name, [string]$label) {
    # 关于页的一行：左侧小标签 + 右侧等宽值（和其它页面同一套列宽，所以标签列也对齐）
    @"
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="$label" Foreground="#FF6B7385" FontSize="12" VerticalAlignment="Center"/>
              <!-- 值可能比列宽长（"Microsoft Windows 11 Home China 10.0.26300" 就是），
                   截断之后鼠标停一下能看全——用绑定跟自己的 Text 走，省得每个赋值处再管一次。 -->
              <TextBlock Grid.Column="1" x:Name="$name" Text="--" Foreground="#FFD7DCE6" FontSize="11.5" FontFamily="Consolas"
                         VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                         ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
            </Grid>
"@
}

function New-VolumeRowXaml([int]$n) {
    # row 0 starts visible (empty) so the auto-sized window does not jump 25px when the
    # first storage sample arrives; the paint tick collapses it if the host has no disks
    $vis = if ($n -eq 0) { 'Visible' } else { 'Collapsed' }
    @"
            <Grid x:Name="Vol${n}Row" Margin="0,7,0,0" Visibility="$vis">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="76"/>
                <ColumnDefinition Width="96"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="Vol${n}Name" Text="" Foreground="#FFD7DCE6" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <Border Grid.Column="1" Background="#FF262A33" CornerRadius="3" Height="7" VerticalAlignment="Center">
                <Border x:Name="Vol${n}Bar" Background="#FF57B0FF" CornerRadius="3" Height="7" Width="0" HorizontalAlignment="Left"/>
              </Border>
              <TextBlock Grid.Column="2" x:Name="Vol${n}Size" Text="" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" Margin="10,0,10,0" TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Column="3" x:Name="Vol${n}Type" Text="" Foreground="#FF8A93A6" FontSize="11" VerticalAlignment="Center" MinWidth="46" TextAlignment="Right"/>
            </Grid>
"@
}

# 标题栏拖动。**必须放过最小化/关闭按钮**：DragMove() 是一个模态的拖动循环，鼠标按下
# 之后消息都由它接管 —— 如果按在最小化按钮上还把事件转发给标题栏，随后的
# MouseLeftButtonUp 就到不了按钮（这正是"最小化点了没反应"的根因；× 是 Down 绑定，
# 它在冒泡到标题栏之前就已经生效了，所以一直是好的）。
# 判据用两条：真鼠标点在按钮上（IsMouseOver），以及事件源在按钮子树里（OriginalSource
# 往上走）—— 后者在自检造合成事件时也成立，不依赖真实光标位置。
function Test-InTitleButton($src) {
    if ($n.MinBtn.IsMouseOver -or $n.CloseBtn.IsMouseOver) { return $true }
    $cur = $src
    $guard = 0
    while ($cur -and $guard -lt 40) {
        $guard++
        if ($cur -eq $n.MinBtn -or $cur -eq $n.CloseBtn -or $cur -eq $n.TitleIcon) { return $true }
        try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { $cur = $null }
    }
    return $false
}

# ---- 请求槽只有一个：启动注入必须排队，不能"同一轮里连发两个" ------------------------
# $script:Sync.Pending 是**一个**槽，采样器 runspace 每轮循环只取走一个请求（采样器里
# `$req = $S.Pending; $S.Pending = $null`）。所以同一个 Update-Panel 轮次里连发两个请求，
# 第二个会把第一个**直接顶掉**，第一个永远不会执行；而启动注入全是"发过就不再发"的
# （$script:LedRestored / $script:FanAppliedOnStart / …），被顶掉就等于这件事从没发生过。
# 凡启动注入，发之前先问这一句：槽不空就什么都不做，等下一次重画（约 400ms 后）再发。
# 2026-10-06 用户报的"开机不注入键盘灯、要手动点一下关闭灯光"就是这个 bug：
#   15:38:07.645 LED restore（发 Request-Led）→ 23ms 后 15:38:07.668 风扇曲线写回（发
#   Request-FanCurve）→ LED 请求被覆盖，而 $script:LedRestored 早已置位 → 永不重发。
function Test-ReqSlotFree { return ($null -eq $script:Sync.Pending) }

function Request-Write {
    param([int]$Mode, [string]$Kind, [switch]$Startup)
    $script:Sync.Pending = [pscustomobject]@{ Mode = $Mode; Kind = $Kind; Startup = [bool]$Startup; At = (Get-Date) }
    if ($Kind -eq 'restore') { $n.StatusText.Text = '正在恢复初始设置…' } else { $n.StatusText.Text = '正在切换…' }
}

