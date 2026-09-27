# diag-render-ui.ps1 - render the panel to a PNG without opening a window.
#
# Why: the layout has to be reviewable when the desktop is busy (a full-screen game on
# top of everything), and an off-screen render is also the only way to get a stable,
# repeatable picture of the UI to compare after a change.
#
# How: take ClevoHelper.ps1, swap its final ShowDialog() call for "show off-screen ->
# pump the dispatcher for 7 s (so the sampling timer paints real numbers) -> render the
# root visual with RenderTargetBitmap -> save PNG", run that copy, then delete it.
#
# Usage: powershell -STA -NoProfile -ExecutionPolicy Bypass -File diag-render-ui.ps1 [-Tab perf|kb|misc]
# Output: ..\artifacts\panel-render.png
[CmdletBinding()]
param([ValidateSet('state', 'perf', 'kb', 'misc', 'about')][string]$Tab = 'state',
      [string]$LedMode = '',          # keyboard mode key to picture (e.g. scan / random)
      [string]$OutFile = '')          # defaults to artifacts\panel-render.png
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'ClevoHelper.ps1'
$txt = Get-Content -Raw -LiteralPath $src
$tail = '[void]$script:Win.ShowDialog()'
if (-not $txt.Contains($tail)) { throw 'ShowDialog tail not found - did the panel script change?' }

$render = @'
# ---- off-screen render (replaces ShowDialog) ----
$script:LedSel.Tab = '__TAB__'                # which control tab to picture
if ('__LEDMODE__') {
    $hit = $false
    for ($i = 0; $i -lt $script:LedModePills.Count; $i++) {
        if ($script:LedModePills[$i].Key -eq '__LEDMODE__') { $script:LedSel.ModeIdx = $i; $script:LedSel.Mode = '__LEDMODE__'; $hit = $true }
    }
    # a key the panel does not offer (e.g. wave, which the factory app can leave in the EC)
    # must render the "no pill lit" state - mirror the sync block so this is a real test
    if (-not $hit) { $script:LedSel.ModeIdx = -1; $script:LedSel.Mode = '__LEDMODE__' }
    # the paint pass syncs the pills from the EC's persisted mode on the first snapshot,
    # which would overwrite the mode we just forced - mark it as already synced
    $script:LedSynced = $true
}
$script:Win.WindowStartupLocation = 'Manual'
$script:Win.ShowActivated = $false            # never steal focus from whatever is running
$script:Win.Left = -20000
$script:Win.Top = -20000
$script:Win.Show()
$frame = New-Object System.Windows.Threading.DispatcherFrame
$t = New-Object System.Windows.Threading.DispatcherTimer
$t.Interval = [TimeSpan]::FromSeconds(7)
$t.Add_Tick({ $t.Stop(); $frame.Continue = $false })
$t.Start()
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
$script:Win.UpdateLayout()
$content = $script:Win.Content
$w = [int][Math]::Ceiling($content.ActualWidth)
$h = [int][Math]::Ceiling($content.ActualHeight)
$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($content)
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$out = if ('__OUT__') { '__OUT__' } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\panel-render.png' }
$fs = [System.IO.File]::Create($out)
$enc.Save($fs)
$fs.Close()
"RENDER {0}x{1} -> {2}" -f $w, $h, $out
$s = $script:Sync.Snapshot
if ($s) { "snapshot: cpu={0}C util={1}% freq={2}MHz {3}W | gpu={4}C util={5}%" -f $s.CpuTemp, $s.CpuUtil, $s.CpuMhz, $s.CpuWatts, $s.GpuTemp, $s.GpuUtil }
$script:Sync.Stop = $true
'@

$run = Join-Path $PSScriptRoot '_render-run.ps1'
try {
    # the copy must sit in src\ because that is where the panel resolves dchu.ps1 from
    Set-Content -LiteralPath $run -Value $txt.Replace($tail, $render.Replace('__TAB__', $Tab).Replace('__LEDMODE__', $LedMode).Replace('__OUT__', $OutFile)) -Encoding UTF8
    & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File $run
}
finally { Remove-Item -LiteralPath $run -Force -ErrorAction SilentlyContinue }
