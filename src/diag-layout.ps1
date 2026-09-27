# diag-layout.ps1 - audit the panel's real pixel layout without opening a window.
#
# Renders nothing: it builds the same off-screen window as diag-render-ui.ps1 and then reads
# each named element's position inside the window with TransformToAncestor. Eyeballing a
# screenshot cannot tell whether a control group starts 3px early; this can.
#
# Usage: powershell -STA -NoProfile -ExecutionPolicy Bypass -File diag-layout.ps1 [-Tab perf|kb|state|misc]
[CmdletBinding()]
param([ValidateSet('state', 'perf', 'kb', 'misc', 'about')][string]$Tab = 'perf')
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'ClevoHelper.ps1'
$txt = Get-Content -Raw -LiteralPath $src
$tail = '[void]$script:Win.ShowDialog()'

$audit = @'
$script:LedSel.Tab = '__TAB__'
$script:Win.WindowStartupLocation = 'Manual'
$script:Win.ShowActivated = $false
$script:Win.Left = -20000
$script:Win.Top = -20000
$script:Win.Show()
$frame = New-Object System.Windows.Threading.DispatcherFrame
$t = New-Object System.Windows.Threading.DispatcherTimer
$t.Interval = [TimeSpan]::FromSeconds(6)
$t.Add_Tick({ $t.Stop(); $frame.Continue = $false })
$t.Start()
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
$script:Win.UpdateLayout()

# rows to audit: label element, then the first element of each control group in that row
# (keyboard rows: only the modes/pills the panel still offers - 方向/副色/渐变 rows were
# removed when the mode list was cut to four)
$rows = @(
    @{ Name = '电源'; Items = @('Pwr0', 'Pwr3') },
    @{ Name = '显卡'; Items = @('Gpu0', 'Gpu2') },
    @{ Name = '风扇'; Items = @('Fan0', 'Fan2') },
    @{ Name = '节点2'; Items = @('Ct2TMinus', 'Ct2TVal', 'Ct2TPlus', 'Ct2DMinus', 'Ct2DVal', 'Ct2DPlus') },
    @{ Name = '节点3'; Items = @('Ct3TMinus', 'Ct3TVal', 'Ct3TPlus', 'Ct3DMinus', 'Ct3DVal', 'Ct3DPlus') },
    @{ Name = '键盘模式'; Items = @('Led0', 'Led3') },
    @{ Name = '键盘主色'; Items = @('Rgb0', 'Rgb8') },
    @{ Name = '键盘亮度'; Items = @('RgbB0', 'RgbB2') },
    @{ Name = '键盘速度'; Items = @('Spd0', 'Spd2') },
    @{ Name = '电池充电'; Items = @('Chg0', 'Chg2') },
    @{ Name = '充电开始'; Items = @('ChgS0', 'ChgS5') },
    @{ Name = '充电停止'; Items = @('ChgE0', 'ChgE4') },
    @{ Name = '开关行'; Items = @('Tp0', 'Wk0', 'Fl0', 'Ws0', 'Nl0') },
    @{ Name = '自启行'; Items = @('Auto0', 'Auto1') }
)

function Get-X($el) {
    if ($null -eq $el) { return $null }
    try {
        $p = $el.TransformToAncestor($script:Win).Transform((New-Object System.Windows.Point(0, 0)))
        return [pscustomobject]@{ X = [Math]::Round($p.X, 1); Y = [Math]::Round($p.Y, 1); W = [Math]::Round($el.ActualWidth, 1) }
    }
    catch { return $null }
}

$root = $script:Win.Content
Write-Output ("window {0}x{1}" -f [int]$root.ActualWidth, [int]$root.ActualHeight)
foreach ($r in $rows) {
    $parts = @()
    foreach ($n in $r.Items) {
        $el = $script:Win.FindName($n)
        $g = Get-X $el
        if ($g) { $parts += ('{0} x={1} w={2}' -f $n, $g.X, $g.W) }
        else { $parts += ('{0} (缺失)' -f $n) }
    }
    Write-Output ('  {0,-10} {1}' -f $r.Name, ($parts -join '   '))
}

# every label TextBlock in the left column should share one X
Write-Output ''
Write-Output 'left column labels (should all share one X):'
$labels = @()
foreach ($el in $script:Win.Content.FindVisualChildren) { }
$script:Sync.Stop = $true
'@

$run = Join-Path $PSScriptRoot '_layout-run.ps1'
try {
    Set-Content -LiteralPath $run -Value $txt.Replace($tail, $audit.Replace('__TAB__', $Tab)) -Encoding UTF8
    & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $run
}
finally { Remove-Item -LiteralPath $run -Force -ErrorAction SilentlyContinue }
