# 任务栏/开始菜单身份：把"开始菜单里那个快捷方式"写成 Windows 认的样子。
#
# 为什么需要它：任务栏按钮的**名字和图标**由窗口的 AppUserModelID 决定，而未打包应用让
# Windows 认识这个 AUMID 的正式做法，就是在开始菜单里放一个 System.AppUserModel.ID 与之
# 匹配的快捷方式。以前这儿只有一个手写的 .lnk：目标指着一个 .cmd、IconLocation 是空的
# （",0"）—— 于是任务栏/开始菜单拿到通用图标，表现就是"任务栏图标和托盘里那个不一样"。
#
# 这个脚本做三件事，且**每件都读回验证**：
#   1) 写/更新开始菜单快捷方式：目标=exe、工作目录=exe 目录、图标=exe 的第 0 号图标；
#   2) 给这个 .lnk 写 System.AppUserModel.ID = Yeguang.ClevoHelper；
#   3) 写 HKCU\SOFTWARE\Classes\AppUserModelId\Yeguang.ClevoHelper 的 DisplayName/IconUri/
#      RelaunchCommand（任务栏取名字和图标就是取这里）。
#
# 坑（踩过）：写完立刻用**同一个** IPropertyStore 读回来，读到的是缓存；而重新打开一个
# store 又可能因为上一个 COM 对象还没释放而失败（报"打不开"）。所以写完要
# Marshal.ReleaseComObject + GC，再重新打开读 —— 验证必须是一次新的读取。
#
# 用法：Set-ShortcutIdentity.ps1 -Exe "C:\path\ClevoHelper.exe" [-Aumid Yeguang.ClevoHelper] [-AlsoDesktop]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Aumid = 'Yeguang.ClevoHelper',
    [switch]$AlsoDesktop
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { throw "exe not found: $Exe" }
$Exe = (Get-Item -LiteralPath $Exe).FullName
$exeDir = Split-Path $Exe -Parent

if (-not ('ClevoIdentity.Lnk' -as [type])) {
    Add-Type -Namespace ClevoIdentity -Name Lnk -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
static extern int SHGetPropertyStoreFromParsingName(string path, System.IntPtr b, int flags, ref System.Guid iid, out IPropertyStore store);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
static extern int PSGetPropertyKeyFromName(string name, out PROPERTYKEY k);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack=4)]
public struct PROPERTYKEY { public System.Guid fmtid; public int pid; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct PROPVARIANT {
    [System.Runtime.InteropServices.FieldOffset(0)] public ushort vt;
    [System.Runtime.InteropServices.FieldOffset(8)] public System.IntPtr p;
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    int GetCount(out uint c);
    int GetAt(uint i, out PROPERTYKEY k);
    int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    int Commit();
}

static IPropertyStore Open(string path) {
    System.Guid iid = new System.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore store;
    // GPS_READWRITE = 2
    if (SHGetPropertyStoreFromParsingName(path, System.IntPtr.Zero, 2, ref iid, out store) != 0) return null;
    return store;
}

// 只负责写：写完把 COM 对象放掉。
//
// 验证**不能**在这里做 —— 这一点是踩出来的：写完立刻用一个新的 IPropertyStore 读回来，
// 读到的是"空(vt=0)"，看着像写失败；换一个进程、用 Shell.Application 的
// ExtendedProperty('System.AppUserModel.ID') 读同一个文件，读到的却是写进去的值。
// 也就是说进程内的属性库带着 shell 的缓存，会一本正经地骗你。
// 所以读回统一放在外面的 PowerShell 里用 Shell.Application 做（另一个进程 + 另一套 API）。
public static string SetAumid(string path, string aumid) {
    IPropertyStore store = Open(path);
    if (store == null) return "打不开快捷方式属性库";
    PROPERTYKEY k;
    if (PSGetPropertyKeyFromName("System.AppUserModel.ID", out k) != 0) {
        System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
        return "拿不到 System.AppUserModel.ID 这个键";
    }
    PROPVARIANT v = new PROPVARIANT();
    v.vt = 31;                                            // VT_LPWSTR
    v.p = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUni(aumid);
    int rcSet = store.SetValue(ref k, ref v);
    System.Runtime.InteropServices.Marshal.FreeCoTaskMem(v.p);
    int rcCommit = (rcSet == 0) ? store.Commit() : -1;
    System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
    return "rc=" + rcSet + "/" + rcCommit;
}
'@
}

# ---- 1) 开始菜单快捷方式 ----
$lnkPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'ClevoHelper.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = $Exe
$lnk.WorkingDirectory = $exeDir
$lnk.IconLocation = $Exe + ',0'
$lnk.Description = 'ClevoHelper - Clevo X370SN 控制中心（G-Helper 风格，单文件）'
$lnk.Save()
Write-Host ('  快捷方式: {0}' -f $lnkPath)
Write-Host ('    目标={0}' -f $Exe)
Write-Host ('    图标={0},0' -f $Exe)

# ---- 2) 快捷方式的 AUMID（写）＋ 用独立读取者验证 ----
$rc = [ClevoIdentity.Lnk]::SetAumid($lnkPath, $Aumid)
Write-Host ('    写 AUMID: {0}' -f $rc)
# 读回用 Shell.Application（另一个进程、另一套 API）：进程内的 IPropertyStore 会拿缓存骗人
$readBack = ''
try {
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace((Split-Path $lnkPath -Parent))
    $readBack = [string]$folder.ParseName((Split-Path $lnkPath -Leaf)).ExtendedProperty('System.AppUserModel.ID')
}
catch { $readBack = '(读回失败: ' + $_.Exception.Message + ')' }
Write-Host ('    读回 AUMID（Shell.Application 独立读）= "{0}"' -f $readBack)
if ($readBack -ne $Aumid) {
    Write-Host '    !! 快捷方式的 AUMID 没验证通过 —— 任务栏可能仍按通用/PowerShell 身份显示'
}

# ---- 3) AUMID 注册项（任务栏取名字/图标的地方）----
$key = 'HKCU:\SOFTWARE\Classes\AppUserModelId\' + $Aumid
if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -LiteralPath $key -Name 'DisplayName' -Value 'ClevoHelper' -Force
Set-ItemProperty -LiteralPath $key -Name 'IconUri' -Value $Exe -Force
Set-ItemProperty -LiteralPath $key -Name 'RelaunchCommand' -Value ('"' + $Exe + '"') -Force
Set-ItemProperty -LiteralPath $key -Name 'RelaunchDisplayNameResource' -Value 'ClevoHelper' -Force
$dn = (Get-ItemProperty -LiteralPath $key).DisplayName
$ic = (Get-ItemProperty -LiteralPath $key).IconUri
Write-Host ('  注册项: {0}' -f $key)
Write-Host ('    读回 DisplayName={0} IconUri={1}' -f $dn, $ic)
if ($dn -ne 'ClevoHelper' -or $ic -ne $Exe) { Write-Host '    !! 注册项读回与写入不一致' }

# ---- 4) 桌面快捷方式（可选）----
# 桌面放**快捷方式**而不是 9.6MB 的 exe 副本：exe 只有一份（%LOCALAPPDATA%\ClevoHelper），
# 桌面/开始菜单都指过去。用户以前把桌面那个 exe 删掉过 —— 删快捷方式不会让自启失效。
if ($AlsoDesktop) {
    $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ClevoHelper.lnk'
    $d = $ws.CreateShortcut($deskLnk)
    $d.TargetPath = $Exe
    $d.WorkingDirectory = $exeDir
    $d.IconLocation = $Exe + ',0'
    $d.Description = 'ClevoHelper - Clevo X370SN 控制中心（G-Helper 风格，单文件）'
    $d.Save()
    [void][ClevoIdentity.Lnk]::SetAumid($deskLnk, $Aumid)
    Write-Host ('  桌面快捷方式: {0} -> {1}' -f $deskLnk, $Exe)
}
