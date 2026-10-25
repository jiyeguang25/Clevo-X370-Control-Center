# model-guard.ps1 - 机型守卫的**唯一判定点**。
#
# 背景：本工具的全部 EC 命令字与字节布局都是在**蓝天 Clevo X370SN** 上一项项实测出来的
# （本机 = 蓝天 X370 准系统，经七彩虹微调后贴牌为「将星 X17 Pro Max 23 款」）。
# 换一台机器照发同样的帧，轻则读到的数字全是错的，重则写坏 EC。
# README 里承诺的是"别的机型不保证能用"；这个文件把"不保证"升级成"不许写" ——
# **只读监控照旧可用**，写入一律拦下并说清原因。
#
# 为什么认序列号、不认型号：本机 Win32_ComputerSystem.Model 是「X17 Pro Max」，
# **不含 X370**；机型指纹只出现在 Win32_ComputerSystemProduct.IdentifyingNumber
# （本机 = NKX370SNVG0000003C00530）。认 Model 会把本机自己拦在门外。
#
# 放行条件（任一满足即放行）：
#   1) 指纹里出现 X370SN                —— 本机命中
#   2) WMI 整个查不到（异常/非 Windows）—— 不因为"查不到"就把用户挡在门外，但记下原因
#   3) 用户显式强制                      —— 逃生门，风险自负，留痕
#
# 逃生门（风险自负）：ClevoHelper.exe --force-write
#                    或先设环境变量 CLEVOHELPER_FORCE_WRITE=1
#
# 用法（可重复 dot-source，只真正判定一次）：
#   . model-guard.ps1
#   $script:ModelIsX370SN      # $true / $false
#   $script:ModelGuardWhy      # 判定依据，写日志 / 显示在界面上
#   $script:ModelGuardForced   # 是不是走了逃生门
#
# 注意：本文件**不设** $ErrorActionPreference —— 调用方（dchu.ps1 / kbled.ps1）各有自己的
# 设置，改了会影响它们。

if (-not $script:ModelGuardDone) {
    $script:ModelGuardDone = $true

    $forced = ($env:CLEVOHELPER_FORCE_WRITE -eq '1')
    $ok = $false
    $why = ''

    try {
        $csx = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $why = '序列号={0} 型号={1} DMI型号={2} 厂商={3}' -f `
            $csx.IdentifyingNumber, $csx.Name, $cs.Model, $cs.Manufacturer
        $ok = ($why -match 'X370SN')
    }
    catch {
        $ok = $true
        $why = 'WMI 查询失败，跳过机型守卫：' + $_.Exception.Message
    }

    if ($forced) {
        $ok = $true
        $why = '用户强制放行（--force-write / CLEVOHELPER_FORCE_WRITE=1）'
    }

    $script:ModelIsX370SN = $ok
    $script:ModelGuardWhy = $why
    $script:ModelGuardForced = $forced
}
