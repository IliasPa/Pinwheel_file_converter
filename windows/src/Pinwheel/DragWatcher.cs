using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Pinwheel;

/// <summary>
/// Notices a drag that starts in File Explorer (or on the desktop) and Shift
/// being held during it: that's when the wheel opens, as on the Mac. A
/// low-level mouse hook sees the button and the movement; it never changes
/// or holds back any input.
/// </summary>
sealed class DragWatcher : IDisposable
{
    readonly Native.LowLevelMouseProc callback;
    readonly DispatcherTimer timer;
    IntPtr hook;
    bool buttonDown;
    bool dragging;
    bool wheelOpened;
    bool? fromExplorer;
    Native.POINT downAt;
    uint downProcess;

    /// <summary>Files (probably) being dragged from Explorer, and Shift is down.</summary>
    public event Action? ShiftDrag;
    /// <summary>The button was let go after the wheel opened.</summary>
    public event Action? Released;

    public DragWatcher()
    {
        callback = OnMouse;  // kept in a field so it isn't collected while Windows calls it
        timer = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(30) };
        timer.Tick += (_, _) => Check();
    }

    public void Start()
    {
        if (hook != IntPtr.Zero) return;
        hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, callback, Native.GetModuleHandle(null), 0);
        timer.Start();
    }

    public bool IsRunning => hook != IntPtr.Zero;

    IntPtr OnMouse(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(data);
            switch ((int)message)
            {
                case Native.WM_LBUTTONDOWN:
                    buttonDown = true;
                    dragging = false;
                    wheelOpened = false;
                    fromExplorer = null;
                    downAt = info.pt;
                    // Only the window is noted here: hooks must answer quickly.
                    var window = Native.GetAncestor(Native.WindowFromPoint(info.pt), Native.GA_ROOT);
                    Native.GetWindowThreadProcessId(window, out downProcess);
                    break;
                case Native.WM_MOUSEMOVE when buttonDown && !dragging:
                    if (Math.Abs(info.pt.X - downAt.X) > Native.GetSystemMetrics(Native.SM_CXDRAG)
                        || Math.Abs(info.pt.Y - downAt.Y) > Native.GetSystemMetrics(Native.SM_CYDRAG))
                        dragging = true;
                    break;
                case Native.WM_LBUTTONUP:
                    buttonDown = false;
                    dragging = false;
                    if (wheelOpened)
                    {
                        wheelOpened = false;
                        Released?.Invoke();
                    }
                    break;
            }
        }
        return Native.CallNextHookEx(hook, code, message, data);
    }

    void Check()
    {
        if (!dragging || wheelOpened || !Native.IsKeyDown(Native.VK_SHIFT)) return;
        fromExplorer ??= IsExplorer(downProcess);
        if (fromExplorer != true) return;
        wheelOpened = true;
        ShiftDrag?.Invoke();
    }

    static bool IsExplorer(uint processId)
    {
        try
        {
            using var process = Process.GetProcessById((int)processId);
            return process.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }

    public void Dispose()
    {
        timer.Stop();
        if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }
}
