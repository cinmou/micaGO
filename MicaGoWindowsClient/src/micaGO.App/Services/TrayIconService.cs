using System.Runtime.InteropServices;

namespace MicaGo.App.Services;

public sealed record TrayContact(string Id, string Title);

public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private const uint WmCommand = 0x0111;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonUp = 0x0205;
    private const uint NimAdd = 0;
    private const uint NimDelete = 2;
    private const uint NimSetVersion = 4;
    private const uint NotifyIconVersion4 = 4;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint MfString = 0;
    private const uint MfPopup = 0x10;
    private const uint MfSeparator = 0x800;
    private const uint TpmRightButton = 2;
    private const uint ImageIcon = 1;
    private const uint LrLoadFromFile = 0x10;
    private const int OpenId = 1;
    private const int ExitId = 2;
    private const int RecentBaseId = 100;

    private readonly WndProc _wndProc;
    private readonly string _className = $"micaGO.Tray.{Guid.NewGuid():N}";
    private readonly IntPtr _instance;
    private IntPtr _window;
    private IntPtr _icon;
    private IReadOnlyList<TrayContact> _contacts = [];
    private bool _disposed;

    public event EventHandler? OpenRequested;
    public event EventHandler? ExitRequested;
    public event EventHandler<TrayContact>? ContactRequested;

    public TrayIconService(string iconPath)
    {
        _wndProc = WindowProc;
        _instance = GetModuleHandleW(null);
        var windowClass = new WndClass { Instance = _instance, ClassName = _className, WindowProcedure = Marshal.GetFunctionPointerForDelegate(_wndProc) };
        if (RegisterClassW(ref windowClass) == 0) throw new InvalidOperationException("Unable to register the micaGO tray window.");
        _window = CreateWindowExW(0, _className, "micaGO tray", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, _instance, IntPtr.Zero);
        if (_window == IntPtr.Zero) throw new InvalidOperationException("Unable to create the micaGO tray window.");
        _icon = LoadImageW(IntPtr.Zero, iconPath, ImageIcon, 0, 0, LrLoadFromFile);
        if (_icon == IntPtr.Zero) throw new InvalidOperationException("Unable to load the micaGO tray icon.");
        var data = IconData(NifMessage | NifIcon | NifTip);
        if (!Shell_NotifyIconW(NimAdd, ref data)) throw new InvalidOperationException("Unable to add the micaGO tray icon.");
        data.TimeoutOrVersion = NotifyIconVersion4;
        Shell_NotifyIconW(NimSetVersion, ref data);
    }

    public void UpdateRecentContacts(IEnumerable<TrayContact> contacts) => _contacts = contacts.Where(x => !string.IsNullOrWhiteSpace(x.Id)).Take(6).ToArray();

    private IntPtr WindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            var mouseMessage = unchecked((uint)lParam.ToInt64()) & 0xffff;
            if (mouseMessage == WmLButtonUp) OpenRequested?.Invoke(this, EventArgs.Empty);
            else if (mouseMessage == WmRButtonUp) ShowMenu();
            return IntPtr.Zero;
        }
        if (message == WmCommand)
        {
            var id = unchecked((int)(wParam.ToInt64() & 0xffff));
            if (id == OpenId) OpenRequested?.Invoke(this, EventArgs.Empty);
            else if (id == ExitId) ExitRequested?.Invoke(this, EventArgs.Empty);
            else if (id >= RecentBaseId && id < RecentBaseId + _contacts.Count) ContactRequested?.Invoke(this, _contacts[id - RecentBaseId]);
            return IntPtr.Zero;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = CreatePopupMenu();
        var recent = CreatePopupMenu();
        try
        {
            AppendMenuW(menu, MfString, new UIntPtr(OpenId), "Open micaGO");
            for (var i = 0; i < _contacts.Count; i++) AppendMenuW(recent, MfString, new UIntPtr((uint)(RecentBaseId + i)), _contacts[i].Title);
            AppendMenuW(menu, MfPopup, new UIntPtr(unchecked((nuint)recent.ToInt64())), _contacts.Count == 0 ? "Recent contacts (empty)" : "Recent contacts");
            AppendMenuW(menu, MfSeparator, UIntPtr.Zero, null);
            AppendMenuW(menu, MfString, new UIntPtr(ExitId), "Exit");
            GetCursorPos(out var point);
            SetForegroundWindow(_window);
            TrackPopupMenuEx(menu, TpmRightButton, point.X, point.Y, _window, IntPtr.Zero);
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private NotifyIconData IconData(uint flags) => new() { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = _window, Id = 1, Flags = flags, CallbackMessage = CallbackMessage, Icon = _icon, Tip = "micaGO" };

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        var data = IconData(0);
        Shell_NotifyIconW(NimDelete, ref data);
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        if (_window != IntPtr.Zero) DestroyWindow(_window);
        UnregisterClassW(_className, _instance);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WndClass { public uint Style; public IntPtr WindowProcedure; public int ClassExtra; public int WindowExtra; public IntPtr Instance; public IntPtr Icon; public IntPtr Cursor; public IntPtr Background; public string? MenuName; public string ClassName; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyIconData { public uint Size; public IntPtr Window; public uint Id; public uint Flags; public uint CallbackMessage; public IntPtr Icon; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip; public uint State; public uint StateMask; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info; public uint TimeoutOrVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle; public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X; public int Y; }
    private delegate IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? name);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern ushort RegisterClassW(ref WndClass windowClass);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool UnregisterClassW(string className, IntPtr instance);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowExW(uint exStyle,string className,string name,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProcW(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr LoadImageW(IntPtr instance,string name,uint type,int width,int height,uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)] private static extern bool Shell_NotifyIconW(uint message,ref NotifyIconData data);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool AppendMenuW(IntPtr menu,uint flags,UIntPtr item,string? text);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool TrackPopupMenuEx(IntPtr menu,uint flags,int x,int y,IntPtr window,IntPtr parameters);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
}
