using System.Runtime.InteropServices;

namespace UsageMeter.App;

internal sealed class TrayIconManager : IDisposable
{
    private const uint NimAdd = 0;
    private const uint NimDelete = 2;
    private const uint NifMessage = 0x1;
    private const uint NifIcon = 0x2;
    private const uint NifTip = 0x4;
    private const uint CallbackMessage = 0x8000 + 0x401;
    private const int GwlpWndProc = -4;
    private const int WmLButtonUp = 0x0202;
    private const int WmLButtonDoubleClick = 0x0203;
    private const int WmRButtonUp = 0x0205;
    private const int IdiApplication = 32512;
    private const uint ImageIcon = 1;
    private const uint LrLoadFromFile = 0x10;
    private const uint LrDefaultSize = 0x40;
    private const string WindowClassName = "UsageMeterTrayWindow";

    private readonly IntPtr _messageHwnd;
    private readonly IntPtr _iconHandle;
    private readonly Action _activate;
    private readonly WndProc _wndProc;
    private bool _disposed;

    public TrayIconManager(Action activate)
    {
        _activate = activate;
        _wndProc = OnWindowMessage;
        RegisterTrayWindowClass();
        _messageHwnd = CreateWindowEx(0, WindowClassName, "UsageMeter Tray", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (_messageHwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException("Unable to create tray message window.");
        }

        _iconHandle = LoadAppIcon();
        var data = CreateData();
        if (!ShellNotifyIcon(NimAdd, ref data))
        {
            throw new InvalidOperationException("Unable to add tray icon.");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        var data = CreateData();
        ShellNotifyIcon(NimDelete, ref data);
        DestroyWindow(_messageHwnd);
        if (_iconHandle != IntPtr.Zero)
        {
            DestroyIcon(_iconHandle);
        }

        _disposed = true;
    }

    private IntPtr OnWindowMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            var mouseMessage = lParam.ToInt32();
            if (mouseMessage is WmLButtonUp or WmLButtonDoubleClick or WmRButtonUp)
            {
                _activate();
                return IntPtr.Zero;
            }
        }

        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private NotifyIconData CreateData()
    {
        return new NotifyIconData
        {
            cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
            hWnd = _messageHwnd,
            uID = 1,
            uFlags = NifMessage | NifIcon | NifTip,
            uCallbackMessage = CallbackMessage,
            hIcon = _iconHandle == IntPtr.Zero ? LoadIcon(IntPtr.Zero, new IntPtr(IdiApplication)) : _iconHandle,
            szTip = "UsageMeter"
        };
    }

    private static IntPtr LoadAppIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "App", "UsageMeter.ico");
        return File.Exists(iconPath)
            ? LoadImage(IntPtr.Zero, iconPath, ImageIcon, 0, 0, LrLoadFromFile | LrDefaultSize)
            : IntPtr.Zero;
    }

    private void RegisterTrayWindowClass()
    {
        var windowClass = new WindowClass
        {
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            lpszClassName = WindowClassName
        };
        RegisterClass(ref windowClass);
    }

    private delegate IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;

        public uint uTimeoutOrVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;

        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ShellNotifyIcon(uint dwMessage, ref NotifyIconData lpData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClass(ref WindowClass lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int x,
        int y,
        int nWidth,
        int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadIcon(IntPtr hInstance, IntPtr lpIconName);

    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadImage(
        IntPtr hInst,
        string name,
        uint type,
        int cx,
        int cy,
        uint fuLoad);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);
}
