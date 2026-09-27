# 快捷方式里到底写了什么（尤其是 System.AppUserModel.ID）—— 任务栏的图标/名字有可能
# 是从"匹配 AUMID 的快捷方式"取来的，所以这个必须看清楚。
# SHGetPropertyStoreFromParsingName 全量枚举属性，别只挑一个看。
param([Parameter(Mandatory = $true)][string]$Path)
Add-Type -Namespace Lnk -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SHGetPropertyStoreFromParsingName(string path, System.IntPtr b, int flags, ref System.Guid iid, out IPropertyStore store);
[System.Runtime.InteropServices.DllImport("ole32.dll")] public static extern void PropVariantClear(ref PROPVARIANT v);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int PSGetPropertyKeyFromName(string name, out PROPERTYKEY k);
[System.Runtime.InteropServices.DllImport("propsys.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int PSGetNameFromPropertyKey(ref PROPERTYKEY k, out System.IntPtr name);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack=4)]
public struct PROPERTYKEY { public System.Guid fmtid; public int pid; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct PROPVARIANT {
    [System.Runtime.InteropServices.FieldOffset(0)] public ushort vt;
    [System.Runtime.InteropServices.FieldOffset(8)] public System.IntPtr p;
    [System.Runtime.InteropServices.FieldOffset(8)] public int i;
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    int GetCount(out uint c);
    int GetAt(uint i, out PROPERTYKEY k);
    int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    int Commit();
}

public static string NameOf(ref PROPERTYKEY k) {
    System.IntPtr p;
    if (PSGetNameFromPropertyKey(ref k, out p) != 0 || p == System.IntPtr.Zero) return "(canonical?)";
    return System.Runtime.InteropServices.Marshal.PtrToStringUni(p);
}

public static string ValueOf(ref PROPVARIANT v) {
    if (v.vt == 31 || v.vt == 8) return (v.p == System.IntPtr.Zero) ? "(null)" : System.Runtime.InteropServices.Marshal.PtrToStringUni(v.p);
    if (v.vt == 19) return v.i.ToString();
    return "(vt=" + v.vt + ")";
}

// 全在 C# 里做完再返回字符串：跨 COM 的 out 参数回到 PowerShell 就成了 __ComObject，
// 在上面调 GetCount 会直接失败（踩过）。
public static string[] Dump(string path) {
    var list = new System.Collections.Generic.List<string>();
    System.Guid iid = new System.Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore store;
    int rc = SHGetPropertyStoreFromParsingName(path, System.IntPtr.Zero, 2, ref iid, out store);
    if (rc != 0 || store == null) { list.Add("打开失败 rc=" + rc); return list.ToArray(); }
    uint c;
    if (store.GetCount(out c) != 0) { list.Add("GetCount 失败"); return list.ToArray(); }
    list.Add("属性数: " + c);
    for (uint i = 0; i < c; i++) {
        PROPERTYKEY k;
        if (store.GetAt(i, out k) != 0) continue;
        PROPVARIANT v;
        if (store.GetValue(ref k, out v) != 0) continue;
        list.Add(NameOf(ref k) + " = " + ValueOf(ref v));
        PropVariantClear(ref v);
    }
    return list.ToArray();
}
'@

[Lnk.Api]::Dump($Path) | ForEach-Object { "  $_" }
