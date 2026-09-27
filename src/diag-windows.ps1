# 现在桌面上有哪些可见窗口、归谁管 —— 用来排查"任务栏里那个奇怪的东西是谁"。
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -Namespace W -Name Api -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassNameW(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@

$rows = New-Object System.Collections.ArrayList
$cb = [W.Api+EnumProc]{
    param($h, $p)
    if ([W.Api]::IsWindowVisible($h)) {
        $sb = New-Object System.Text.StringBuilder 300
        [void][W.Api]::GetWindowTextW($h, $sb, 300)
        $title = $sb.ToString()
        $cb2 = New-Object System.Text.StringBuilder 200
        [void][W.Api]::GetClassNameW($h, $cb2, 200)
        if ($title) {
            $pid2 = 0
            [void][W.Api]::GetWindowThreadProcessId($h, [ref]$pid2)
            $pn = ''
            try { $pn = (Get-Process -Id $pid2 -ErrorAction Stop).ProcessName } catch { }
            [void]$rows.Add([pscustomobject]@{ Pid = $pid2; Proc = $pn; Class = $cb2.ToString(); Title = $title })
        }
    }
    return $true
}
[void][W.Api]::EnumWindows($cb, [IntPtr]::Zero)
"可见且有标题的顶层窗口: {0}" -f $rows.Count
$rows | Sort-Object Proc | Format-Table -AutoSize | Out-String -Width 220
"---- 名字里带面板/控制/Helper/PowerShell 的 ----"
$rows | Where-Object { $_.Title -match '控制|面板|Clevo|Helper|PowerShell' } |
    Format-Table Pid, Proc, Class, Title -AutoSize | Out-String -Width 220
