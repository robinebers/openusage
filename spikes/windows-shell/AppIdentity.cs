using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace OpenUsageShell;

/// <summary>
/// Registers unpackaged toast identity: process AUMID + Start Menu shortcut + .ico
/// so Windows shows "OpenUsage" with the brand mark instead of "OpenUsageShell" + generic exe icon.
/// </summary>
internal static class AppIdentity
{
    public const string AppUserModelId = "OpenUsage.Windows";
    public const string DisplayName = "OpenUsage";

    private static bool _ensured;

    public static void EnsureRegistered()
    {
        if (_ensured)
        {
            return;
        }

        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("identity", $"AUMID set failed: {ex.Message}");
        }

        try
        {
            var icoPath = EnsureAppIconIco();
            EnsureStartMenuShortcut(icoPath);
            _ensured = true;
            ShellLogger.Instance.Info("identity", $"Registered AUMID={AppUserModelId}, icon={icoPath}");
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("identity", $"Start Menu shortcut failed: {ex.Message}");
        }
    }

    public static string EnsureAppIconIco()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenUsage");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "OpenUsage.ico");
        using var bmp = TrayIconRenderer.RenderAppIconBitmap(256);
        IconWriter.Save(path, bmp);
        return path;
    }

    private static void EnsureStartMenuShortcut(string icoPath)
    {
        var programs = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Microsoft", "Windows", "Start Menu", "Programs");
        Directory.CreateDirectory(programs);
        var lnkPath = Path.Combine(programs, $"{DisplayName}.lnk");
        var exePath = Environment.ProcessPath
            ?? Path.Combine(AppContext.BaseDirectory, "OpenUsageShell.exe");

        ShellLink.Create(lnkPath, exePath, icoPath, DisplayName, AppUserModelId);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}

internal static class IconWriter
{
    public static void Save(string path, Bitmap source)
    {
        var sizes = new[] { 16, 32, 48, 64, 128, 256 };
        using var fs = File.Create(path);
        using var bw = new BinaryWriter(fs);

        bw.Write((ushort)0);
        bw.Write((ushort)1);
        bw.Write((ushort)sizes.Length);

        var imageData = new List<byte[]>();
        var offset = 6 + (16 * sizes.Length);

        foreach (var size in sizes)
        {
            using var scaled = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(scaled))
            {
                g.Clear(Color.Transparent);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(source, 0, 0, size, size);
            }

            using var ms = new MemoryStream();
            scaled.Save(ms, ImageFormat.Png);
            var png = ms.ToArray();
            imageData.Add(png);

            bw.Write((byte)(size >= 256 ? 0 : size));
            bw.Write((byte)(size >= 256 ? 0 : size));
            bw.Write((byte)0);
            bw.Write((byte)0);
            bw.Write((ushort)1);
            bw.Write((ushort)32);
            bw.Write(png.Length);
            bw.Write(offset);
            offset += png.Length;
        }

        foreach (var png in imageData)
        {
            bw.Write(png);
        }
    }
}

internal static class ShellLink
{
    private static readonly Guid PkeyAppUserModelId = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    public static void Create(string lnkPath, string targetPath, string iconPath, string description, string aumid)
    {
        var link = (IShellLinkW)new CShellLink();
        try
        {
            link.SetPath(targetPath);
            link.SetWorkingDirectory(Path.GetDirectoryName(targetPath) ?? AppContext.BaseDirectory);
            link.SetDescription(description);
            link.SetIconLocation(iconPath, 0);

            var propStore = (IPropertyStore)link;
            var key = new PropertyKey(PkeyAppUserModelId, 5);
            var pv = PropVariant.FromString(aumid);
            try
            {
                propStore.SetValue(ref key, ref pv);
                propStore.Commit();
            }
            finally
            {
                PropVariant.Clear(ref pv);
            }

            ((IPersistFile)link).Save(lnkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class CShellLink
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] char[] pszFile, int cchMaxPath, IntPtr pfd, int fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] char[] pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] char[] pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] char[] pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] char[] pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
        void Resolve(IntPtr hwnd, int fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [In, MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        uint GetCount();
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;

        public PropertyKey(Guid fmtid, uint pid)
        {
            this.fmtid = fmtid;
            this.pid = pid;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr pointerValue;
        // Extra space for PROPVARIANT union on x64
        public IntPtr spacer1;
        public IntPtr spacer2;

        public static PropVariant FromString(string value) => new()
        {
            vt = 31, // VT_LPWSTR
            pointerValue = Marshal.StringToCoTaskMemUni(value)
        };

        public static void Clear(ref PropVariant pv)
        {
            PropVariantClear(ref pv);
            pv = default;
        }

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pvar);
    }
}
