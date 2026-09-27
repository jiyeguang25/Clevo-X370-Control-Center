# 把 EC 里"已暂存"的显卡模式写回某个值 —— 自检把测试值留在里面时用它收尾。
# 注意：pre-boot 值**没有在线读回**，所以这里能给的证据只有"命令发出去了 + rc"，
# 最终效果只能重启后看。用法：Set-GpuStaged.ps1 -Mode 2
param([Parameter(Mandatory = $true)][ValidateRange(1, 4)][int]$Mode)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dchu.ps1')

$before = Get-GpuMode
"当前生效 : {0}（{1}）   支持掩码=0x{2:X}   AppSetting PreGPU_Mode={3}" -f `
    $before.Mode, $before.ModeName, $before.Mask, $before.Persisted

if ($before.Supported -and ($before.Supported -notcontains $Mode)) {
    throw ('EC 报告不支持模式 {0}（支持：{1}）' -f $Mode, ($before.Supported -join ','))
}

$buf = New-Object byte[] 256
$buf[0] = 0x16
$buf[1] = [byte]$Mode
$out = New-Object byte[] 256
$rc = [ClevoHelper.DchuApi]::SetDCHU_DataEx(4, $buf, 256, $out)
"已写入暂存: {0}（{1}）  rc=0x{2:X}  out[0..3]={3}" -f `
    $Mode, $script:GpuModeName[$Mode], $rc, (($out[0..3] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')

Start-Sleep -Milliseconds 500
$after = Get-GpuMode
"写后读回 : 生效={0}（{1}） PreGPU_Mode={2}   ← 预期不变（pre-boot 值在线读不到）" -f `
    $after.Mode, $after.ModeName, $after.Persisted
"结论：最后一次 0x16 写入 = {0}；重启后应生效为「{1}」" -f $Mode, $script:GpuModeName[$Mode]
