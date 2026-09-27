# build-exe.ps1 - package ClevoHelper into a single ClevoHelper.exe.
#
# Why a launcher and not PS2EXE: no external module, no internet, no admin. The in-box
# C# compiler (csc.exe, .NET Framework 4.x - present on every Windows 10/11) builds a real
# Win32 GUI executable with an icon, with all the .ps1 files AND the bundled
# InsydeDCHU.dll embedded as resources. On every run it extracts them to
#   %LOCALAPPDATA%\ClevoHelper\app\
# and then starts the panel detached (WMI Win32_Process.Create, so the panel is not a child
# of the launcher and survives it), exactly like Start-Panel.ps1 does.
#
# The exe also handles autostart itself, without needing PowerShell:
#   ClevoHelper.exe --autostart on|off|status
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\src\build-exe.ps1
# Output: .\dist\ClevoHelper.exe

[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$root = Split-Path $src -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

# ---------------------------------------------------------------- payload ----
# Runtime files only. diag-*.ps1 / dotnet-*.ps1 / pe-exports.ps1 are development tools and
# stay out of the shipped exe.
$scripts = @(
    'ClevoHelper.ps1',    # the panel
    'dchu.ps1',           # DCHU bridge
    'fancurve.ps1',       # fan curve layer
    'fanctl.ps1',         # write layer
    'kbled.ps1',          # keyboard LED layer
    'gpu.ps1',            # GPU telemetry (NVML in-process, no nvidia-smi process)
    'misc.ps1',           # 杂项 tab: screen brightness / touchpad / NumLock (non-DCHU)
    'autostart.ps1',      # 开机自启：装一份到 %LOCALAPPDATA% + 写 Startup 的 .vbs（失败静默）
    'Install-DchuDriver.ps1', # installs the bundled ACPI bridge driver + service
    'Start-Panel.ps1',    # detached launcher (still useful in dev mode)
    'revert-worker.ps1'   # rollback watchdog worker
)
$libFile = Join-Path $src 'lib\InsydeDCHU.dll'
# The ACPI bridge driver package (ACPI\CLV0001 / ACPI\CLV0002 + DCHUService). Bundled so the
# app can install its own prerequisite instead of depending on the factory installer.
$driverDir = Join-Path $src 'driver'

foreach ($f in $scripts) {
    $p = Join-Path $src $f
    if (-not (Test-Path -LiteralPath $p)) { throw "missing payload file: $p" }
}
if (-not (Test-Path -LiteralPath $libFile)) {
    throw "missing $libFile - copy it from C:\Program Files (x86)\ControlCenter\DCHU\InsydeDCHU.dll"
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc" }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$work = Join-Path $env:TEMP ('clevo-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ------------------------------------------------------------------ icon ----
Add-Type -AssemblyName System.Drawing
# ONE icon, generated here, used in three places: the EXE's own icon (/win32icon),
# the panel WINDOW's icon (taskbar) and the TRAY icon. User request: "统一改为托盘内图标".
#
# Two things were wrong before:
#   1. the .ico carried a SINGLE 256x256 PNG entry, so Explorer/taskbar scaled it down and
#      the 16px tray-sized rendering looked nothing like the tray icon next to it;
#   2. the panel runs under powershell.exe, so without Window.Icon the taskbar button showed
#      POWERSHELL's icon no matter what the EXE carried.
# Now every size is drawn from the same code at that size (16/20/24/32/40/48/64 as classic
# BMP entries, 128/256 as PNG entries - the layout real icon editors emit, because the shell
# is happiest with DIBs at small sizes).
function New-AppIconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)          # 透明底：任务栏/开始菜单要靠它
    $s = $size / 256.0
    # 深色圆角方块底（和面板同一个底色 #141619）
    $m = [double](10 * $s)
    $r = [double](52 * $s)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $rect = New-Object System.Drawing.RectangleF($m, $m, ($size - 2 * $m), ($size - 2 * $m))
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 22, 25))), $path)
    # 蓝色圆盘 + 深色箭头（就是托盘那个图形）
    $pad = [double](28 * $s)
    $disc = $size - 2 * $pad
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(87, 176, 255))), $pad, $pad, $disc, $disc)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(20, 22, 25), ([float](26 * $s)))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $cx = $size / 2.0
    $g.DrawLine($pen, [float]$cx, [float](62 * $s), [float]$cx, [float](148 * $s))
    $g.DrawLine($pen, [float]$cx, [float](148 * $s), [float](82 * $s), [float](194 * $s))
    $g.DrawLine($pen, [float]$cx, [float](148 * $s), [float](174 * $s), [float](194 * $s))
    $pen.Dispose(); $g.Dispose()
    return $bmp
}

function Get-IconDib([System.Drawing.Bitmap]$bmp) {
    # BITMAPINFOHEADER + bottom-up BGRA + AND mask (all zero = "use the alpha channel")
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($w * $h * 4)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
    $bmp.UnlockBits($data)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([UInt32]40); $bw.Write([int]$w); $bw.Write([int]($h * 2))
    $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
    $bw.Write([UInt32]($w * $h * 4)); $bw.Write([int]0); $bw.Write([int]0)
    $bw.Write([UInt32]0); $bw.Write([UInt32]0)
    for ($y = $h - 1; $y -ge 0; $y--) {
        $bw.Write($px, ($y * $w * 4), ($w * 4))          # BGRA 已经就是 DIB 的顺序
    }
    $maskRow = [int][Math]::Ceiling($w / 8.0)
    if ($maskRow % 4 -ne 0) { $maskRow += (4 - ($maskRow % 4)) }
    $bw.Write((New-Object byte[] ($maskRow * $h)))
    $bw.Flush()
    $out = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    # 逗号不能省：PowerShell 会把返回的 byte[] 展开成 Object[]，调用方拿到 Object[] 时
    # BinaryWriter.Write() 会挑错重载，写出来的 ICO 是坏的（csc 报"读取图标时出错：数据无效"）。
    return , $out
}

# 生成到 src\app.ico（不是临时目录）：开发模式的面板也要读同一张，图标只有一个来源
$ico = Join-Path $src 'app.ico'
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$entries = @()
foreach ($sz in $sizes) {
    $b = New-AppIconBitmap $sz
    if ($sz -le 64) { $bytes = [byte[]](Get-IconDib $b) }
    else {
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = [byte[]]$ms.ToArray()
        $ms.Dispose()
    }
    if ($bytes.Length -lt 40) { throw ("icon size {0} produced only {1} bytes - refusing to write a broken ICO" -f $sz, $bytes.Length) }
    $entries += [pscustomobject]@{ Size = $sz; Bytes = $bytes }
    $b.Dispose()
}
$bw = New-Object System.IO.BinaryWriter([System.IO.File]::Create($ico))
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $bw.Write([byte]$(if ($e.Size -ge 256) { 0 } else { $e.Size }))
    $bw.Write([byte]$(if ($e.Size -ge 256) { 0 } else { $e.Size }))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$e.Bytes.Length); $bw.Write([UInt32]$offset)
    $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $bw.Write($e.Bytes) }
$bw.Close()
Write-Host ('  icon: {0} ({1} sizes: {2})' -f (Split-Path $ico -Leaf), $entries.Count, ($sizes -join '/'))

# ---------------------------------------------------------------- launcher ---
$cs = Join-Path $work 'Launcher.cs'
$launcher = @'
// ClevoHelper.exe - launcher for the ClevoHelper PowerShell/WPF control panel.
//
// It carries the whole application as embedded resources (the .ps1 files plus a local copy
// of InsydeDCHU.dll, so the panel does not depend on the factory Control Center folder
// still existing), unpacks them under %LOCALAPPDATA%\ClevoHelper\app and starts the panel
// through WMI so the panel is not a child of this process.
//
// Switches:
//   (none)                 start the panel (does nothing if one is already running)
//   --self-test            start the panel with -SelfTest (drives itself, then exits)
//   --autostart on|off     enable/disable start-at-logon
//   --autostart status     report the state
//   --help                 this text
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    const string AppName = "ClevoHelper";
    const string PanelScript = "ClevoHelper.ps1";
    const string VbsName = "ClevoHelper.vbs";

    // 第二次双击 EXE 时用来"叫"已经在跑的那个面板。面板每 400ms 检查一次这个文件，
    // 看到就删掉并把窗口 Show + Activate —— 这对"最小化到托盘"（窗口真的被 Hide 了）
    // 也有效，而 SetForegroundWindow 对隐藏窗口是叫不回来的。
    const string ShowFlagName = "show.request";

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr p);

    static string ExePath { get { return Assembly.GetExecutingAssembly().Location; } }
    static string AppDir
    {
        get
        {
            return Path.Combine(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName),
                "app");
        }
    }
    static string ShowFlag
    {
        get { return Path.Combine(Path.GetDirectoryName(AppDir), ShowFlagName); }
    }
    static string StartupVbs
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Startup), VbsName);
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        string mode = args.Length > 0 ? args[0].Trim().ToLowerInvariant() : "";

        if (mode == "--help" || mode == "-h" || mode == "/?")
        {
            MessageBox.Show(
                "ClevoHelper - Clevo X370SN control panel\r\n\r\n" +
                "  (no switch)              start the panel\r\n" +
                "  --self-test              start, drive itself, exit\r\n" +
                "  --autostart on|off       start-at-logon on/off\r\n" +
                "  --autostart status       show start-at-logon state\r\n" +
                "  --tray                   start, but go straight to the tray (no window)\r\n" +
                "  --driver-status          show the DCHU driver/service state\r\n" +
                "  --install-driver         install/repair the bundled DCHU driver (UAC)\r\n\r\n" +
                "Installed automatically to: " + AppDir,
                AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        if (mode == "--autostart")
        {
            string what = args.Length > 1 ? args[1].Trim().ToLowerInvariant() : "status";
            if (what == "status")
            {
                bool on = File.Exists(StartupVbs);
                Console.WriteLine("autostart: " + (on ? "on" : "off"));
                Console.WriteLine(StartupVbs);
                return 0;
            }
            if (what == "on") { WriteAutostart(true); Console.WriteLine("autostart: on"); return 0; }
            if (what == "off") { WriteAutostart(false); Console.WriteLine("autostart: off"); return 0; }
            MessageBox.Show("usage: ClevoHelper.exe --autostart on|off|status", AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 2;
        }

        // Install/repair the bundled ACPI bridge driver + DCHU service. Kernel-mode devices
        // need administrator rights, so this elevates itself through a UAC prompt.
        if (mode == "--install-driver" || mode == "--driver-status")
        {
            try
            {
                string app = Extract();
                string script = Path.Combine(AppDir, "Install-DchuDriver.ps1");
                string extra = mode == "--driver-status" ? " -Status" : " -Apply";
                // --driver-status 的结果要看得见，所以留一个控制台；--install-driver 会弹 UAC，
                // 那一个窗口是用户预期之内的（要看着它跑完）。
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + script + "\"" + extra);
                psi.UseShellExecute = true;
                if (mode == "--install-driver") psi.Verb = "runas";   // UAC
                psi.WorkingDirectory = AppDir;
                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show("driver action failed:\r\n\r\n" + ex.Message, AppName,
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        try
        {
            string panel = Extract();
            // --tray：启动后直接收进托盘（开机自启走这条路），不显示窗口
            return Launch(panel, mode == "--self-test", mode == "--tray");
        }
        catch (Exception ex)
        {
            MessageBox.Show("ClevoHelper failed to start:\r\n\r\n" + ex, AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // --- unpack ------------------------------------------------------------------
    static string Extract()
    {
        Directory.CreateDirectory(AppDir);
        Directory.CreateDirectory(Path.Combine(AppDir, "lib"));
        Assembly asm = Assembly.GetExecutingAssembly();
        string panel = null;
        foreach (string res in asm.GetManifestResourceNames())
        {
            string target;
            if (res.StartsWith("ps1.", StringComparison.Ordinal))
                target = Path.Combine(AppDir, res.Substring(4));
            else if (res.StartsWith("lib.", StringComparison.Ordinal))
                target = Path.Combine(Path.Combine(AppDir, "lib"), res.Substring(4));
            else if (res.StartsWith("img.", StringComparison.Ordinal))
                // 关于页的头像：跟着 EXE 走，不依赖任何外部文件（和 SICAU 工具同一个约定：
                // 程序只有一个 EXE）
                target = Path.Combine(AppDir, res.Substring(4));
            else if (res.StartsWith("driver.", StringComparison.Ordinal))
            {
                Directory.CreateDirectory(Path.Combine(AppDir, "driver"));
                target = Path.Combine(Path.Combine(AppDir, "driver"), res.Substring(7));
            }
            else
                continue;

            // best effort: the running panel may hold a handle on its own copy
            try
            {
                using (Stream s = asm.GetManifestResourceStream(res))
                using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write))
                    s.CopyTo(fs);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }

            if (res.Equals("ps1." + PanelScript, StringComparison.Ordinal)) panel = target;
        }
        if (panel == null || !File.Exists(panel))
            throw new FileNotFoundException("panel script was not unpacked", panel);
        return panel;
    }

    /// <summary>
    /// 用 WMI 起一个**完全不显示窗口**的进程。
    /// 只写 `powershell.exe ... -WindowStyle Hidden` 是不够的：控制台窗口在进程创建时就被
    /// 系统分配好了，PowerShell 再把自己藏起来 —— 中间那一瞬就是用户看到的"启动时闪一下
    /// 黑窗口"。正确做法是创建时就告诉系统 SW_HIDE（Win32_ProcessStartup.ShowWindow = 0），
    /// 窗口从一开始就不存在。同时保留 WMI 父进程关系，面板不会被启动器的 job 带走。
    /// </summary>
    static void StartHidden(string cmd)
    {
        using (ManagementClass mc = new ManagementClass("Win32_Process"))
        using (ManagementClass sc = new ManagementClass("Win32_ProcessStartup"))
        using (ManagementBaseObject inParams = mc.GetMethodParameters("Create"))
        using (ManagementBaseObject startup = sc.CreateInstance())
        {
            startup["ShowWindow"] = (ushort)0;                 // SW_HIDE
            inParams["CommandLine"] = cmd;
            inParams["ProcessStartupInformation"] = startup;
            using (ManagementBaseObject outParams = mc.InvokeMethod("Create", inParams, null))
            {
                uint rc = (uint)outParams["ReturnValue"];
                if (rc != 0) throw new Exception("Win32_Process.Create failed, ReturnValue=" + rc);
            }
        }
    }

    // --- start -------------------------------------------------------------------
    static int Launch(string panel, bool selfTest, bool toTray)
    {
        int running = FindPanelByMutex();
        if (running == 0) running = FindRunning(panel);
        if (running != 0) return ActivateExisting(running, panel, selfTest);

        string exe = ExePath;
        string cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                   + panel + "\" -HostExe \"" + exe + "\"";
        if (toTray) cmd += " -StartHidden";
        if (selfTest) cmd += " -SelfTest";

        StartHidden(cmd);
        return 0;
    }

    /// <summary>
    /// 已经有面板在跑时**不能再默默退出**。以前这里是 `if (AlreadyRunning(panel)) return 0;`，
    /// 结果用户把 EXE 拷到桌面双击时什么都不会发生 —— 从用户角度就是"这个 exe 用不了"。
    /// 现在：写一个信号文件让面板自己 Show + Activate（对托盘里的隐藏窗口也有效），
    /// 顺手把已经可见的窗口提到前面；要是面板 3 秒都没反应（卡死），问用户要不要再开一个。
    /// </summary>
    static int ActivateExisting(int pid, string panel, bool selfTest)
    {
        try { File.WriteAllText(ShowFlag, DateTime.Now.ToString("o")); } catch { }

        IntPtr h = FindWindowOf(pid);
        if (h != IntPtr.Zero)
        {
            ShowWindow(h, 9);              // SW_RESTORE
            SetForegroundWindow(h);
        }

        for (int i = 0; i < 12; i++)
        {
            Thread.Sleep(250);
            if (!File.Exists(ShowFlag)) return 0;      // 面板把信号吃掉了 = 它活着并已显示
        }

        DialogResult r = MessageBox.Show(
            "已经有一个 ClevoHelper 面板在运行，但它没有响应。\r\n\r\n" +
            "要再启动一个吗？（原来那个可能卡住了，可以用任务管理器结束它）",
            AppName, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (r == DialogResult.Yes)
        {
            try { File.Delete(ShowFlag); } catch { }
            string cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                       + panel + "\" -HostExe \"" + ExePath + "\"";
            if (selfTest) cmd += " -SelfTest";
            using (ManagementClass mc = new ManagementClass("Win32_Process"))
            using (ManagementBaseObject inParams = mc.GetMethodParameters("Create"))
            {
                inParams["CommandLine"] = cmd;
                mc.InvokeMethod("Create", inParams, null);
            }
        }
        return 0;
    }

    static IntPtr FindWindowOf(int pid)
    {
        IntPtr found = IntPtr.Zero;
        try
        {
            EnumWindows(delegate(IntPtr h, IntPtr p)
            {
                uint wpid;
                GetWindowThreadProcessId(h, out wpid);
                if (wpid != (uint)pid) return true;
                var sb = new System.Text.StringBuilder(256);
                GetWindowTextW(h, sb, 256);
                string t = sb.ToString();
                if (t.StartsWith("ClevoHelper", StringComparison.OrdinalIgnoreCase))
                {
                    found = h;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
        }
        catch { }
        return found;
    }

    // Start-Panel.ps1 learned this the hard way: a loose "*ClevoHelper*" match hits the
    // caller itself, so match the exact -File "<path>" form and never our own process.
    // 这是**兜底**判据：主判据是命名互斥体（见 FindPanelByMutex），它不看命令行，
    // 所以开发模式跑 src 目录的实例也能被认出来。
    const string MutexName = "Local\\ClevoHelper.Panel";

    static int FindPanelByMutex()
    {
        // 互斥体本身不带 pid，所以先判断"有人在跑"，再用命令行找出那个进程好把窗口提到前面。
        try
        {
            using (Mutex m = Mutex.OpenExisting(MutexName)) { }
        }
        catch (WaitHandleCannotBeOpenedException) { return 0; }
        catch { return 0; }

        int me = Process.GetCurrentProcess().Id;
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
            {
                foreach (ManagementBaseObject o in s.Get())
                {
                    int pid = Convert.ToInt32(o["ProcessId"]);
                    string cl = o["CommandLine"] as string;
                    if (pid != me && cl != null && cl.IndexOf("ClevoHelper.ps1", StringComparison.OrdinalIgnoreCase) >= 0)
                        return pid;
                }
            }
        }
        catch { }
        return 0;
    }

    static int FindRunning(string panel)
    {
        string needle = "-File \"" + panel + "\"";
        int me = Process.GetCurrentProcess().Id;
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
            {
                foreach (ManagementBaseObject o in s.Get())
                {
                    int pid = Convert.ToInt32(o["ProcessId"]);
                    string cl = o["CommandLine"] as string;
                    if (pid != me && cl != null && cl.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
                        return pid;
                }
            }
        }
        catch { }
        return 0;
    }

    // --- autostart ----------------------------------------------------------------
    static void WriteAutostart(bool on)
    {
        if (!on)
        {
            if (File.Exists(StartupVbs)) File.Delete(StartupVbs);
            return;
        }
        // Inner quotes are doubled because this is a VBS string literal - the old
        // Install-Autostart.ps1 embedded them raw and produced an unrunnable script.
        // --tray：开机自启**不弹窗口**，直接躺在托盘里（用户要求"自动收束到托盘"）。
        string cmd = ("\"" + ExePath + "\" --tray").Replace("\"", "\"\"");
        File.WriteAllText(StartupVbs,
            "CreateObject(\"WScript.Shell\").Run \"" + cmd + "\", 0, False\r\n");
    }
}
'@
Set-Content -LiteralPath $cs -Value $launcher -Encoding UTF8

# ----------------------------------------------------------------- compile ---
$exe = Join-Path $OutDir 'ClevoHelper.exe'
$resArgs = @()
foreach ($f in $scripts) { $resArgs += ('/resource:"{0}",ps1.{1}' -f (Join-Path $src $f), $f) }
$resArgs += ('/resource:"{0}",lib.InsydeDCHU.dll' -f $libFile)
# 关于页的头像（用户提供的 avatar.png，128x128）：嵌成资源，EXE 依然是单文件
$avatarFile = Join-Path $src 'avatar.png'
if (-not (Test-Path -LiteralPath $avatarFile)) { throw "missing $avatarFile - the 关于 page shows it" }
$resArgs += ('/resource:"{0}",img.avatar.png' -f $avatarFile)
# 图标：和 /win32icon 用的是同一个文件，解包出来后窗口图标和托盘图标都读它 ——
# "应用图标统一为托盘图标"靠的就是三处只有一个来源。
$resArgs += ('/resource:"{0}",img.app.ico' -f $ico)
$driverFiles = @(Get-ChildItem -LiteralPath $driverDir -File -ErrorAction SilentlyContinue)
foreach ($f in $driverFiles) { $resArgs += ('/resource:"{0}",driver.{1}' -f $f.FullName, $f.Name) }

$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    ('/out:"{0}"' -f $exe),
    ('/win32icon:"{0}"' -f $ico),
    '/reference:System.dll', '/reference:System.Windows.Forms.dll',
    '/reference:System.Management.dll', '/reference:System.Core.dll'
) + $resArgs + @('"' + $cs + '"')

Write-Host 'compiling...'
# 先删旧产物再编译，并且检查 csc 的退出码：只判断 Test-Path 的话，编译失败时会"成功"输出
# 上一次的 exe（这次就被坑了一次 —— app.ico 是坏的，csc 报错，但脚本照样打印 built:）。
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
$out = & $csc $cscArgs 2>&1
$code = $LASTEXITCODE
$out | Where-Object { $_ -notmatch 'warning CS' } | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
    throw ("csc failed (exit {0}) - the exe was NOT rebuilt`n{1}" -f $code, ($out -join "`n"))
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
$fi = Get-Item -LiteralPath $exe

# ------------------------------------------------- 部署到本机（可重复）---
# 构建产物落在 dist\，但**用户实际运行的那一份**在 %LOCALAPPDATA%\ClevoHelper\ClevoHelper.exe：
# 桌面、开始菜单、AUMID、开机自启全都指向它（用户把桌面 exe 删掉过 —— 自启写死桌面路径就是这么
# 炸的，会每次登录弹「系统找不到指定的文件」）。这一步把 dist 的产物复制过去并刷新那些指向。
$installScript = Join-Path $src 'Install-ClevoHelper.ps1'
if (Test-Path -LiteralPath $installScript) {
    Write-Host 'deploy:'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Source $fi.FullName
    if ($LASTEXITCODE -ne 0) { Write-Host ('  deploy exit {0}' -f $LASTEXITCODE) }
}
else { Write-Host ('  deploy script missing: {0}' -f $installScript) }

Write-Host ''
Write-Host ('built: {0}' -f $fi.FullName)
Write-Host ('  size : {0:N0} KB' -f ($fi.Length / 1KB))
Write-Host ('  files: {0} scripts + lib\InsydeDCHU.dll + {1} driver files embedded' -f $scripts.Count, $driverFiles.Count)
