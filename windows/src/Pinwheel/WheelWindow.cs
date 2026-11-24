using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>
/// The round window under the pointer. While dragging files it takes the
/// drop; opened from "Send to" or the tray, a click on a wedge chooses.
/// </summary>
sealed class WheelWindow : Window
{
    readonly WheelView view = new();
    readonly Func<string?> ffmpeg;
    readonly Action<IReadOnlyList<string>, OutputFormat> convert;
    readonly DispatcherTimer hideAfterRelease;
    string[] files = [];
    bool clickMode;
    bool dropped;
    Native.POINT anchor;

    public WheelWindow(Func<string?> ffmpeg, Action<IReadOnlyList<string>, OutputFormat> convert)
    {
        this.ffmpeg = ffmpeg;
        this.convert = convert;
        Title = "Pinwheel";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        AllowDrop = true;
        Content = view;

        DragEnter += OnDragOver;
        DragOver += OnDragOver;
        DragLeave += (_, _) => view.Hovered = -1;
        Drop += OnDrop;
        MouseMove += (_, e) => { if (clickMode) Hover(e.GetPosition(view)); };
        MouseLeftButtonUp += OnClick;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Dismiss(); };
        Deactivated += (_, _) => { if (clickMode) Dismiss(); };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(new Action(PlaceAtAnchor), DispatcherPriority.Loaded);
        SourceInitialized += (_, _) =>
        {
            // A tool window, out of Alt+Tab.
            var handle = new WindowInteropHelper(this).Handle;
            var style = Native.GetWindowLongPtr(handle, Native.GWL_EXSTYLE).ToInt64() | Native.WS_EX_TOOLWINDOW;
            Native.SetWindowLongPtr(handle, Native.GWL_EXSTYLE, new IntPtr(style));
        };

        // Let go of the mouse without dropping on the wheel: it goes away.
        hideAfterRelease = new DispatcherTimer(DispatcherPriority.Normal, Dispatcher) { Interval = TimeSpan.FromMilliseconds(350) };
        hideAfterRelease.Tick += (_, _) =>
        {
            hideAfterRelease.Stop();
            if (!clickMode && !dropped) Dismiss();
        };
    }

    /// <summary>Set when Pinwheel quits; until then closing only hides the wheel.</summary>
    public bool AllowClose { get; set; }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true;
            Dismiss();
        }
        base.OnClosing(e);
    }

    /// <summary>Files are being dragged and Shift is held: show the wheel under the pointer. What's dragged is known once it moves over the wheel.</summary>
    public void ShowForDrag()
    {
        clickMode = false;
        dropped = false;
        files = [];
        view.Show([], new HashSet<OutputFormat>(), null, 0);
        Native.GetCursorPos(out anchor);
        Present(activate: false);
    }

    /// <summary>Files chosen another way (Send to, the tray): click a wedge.</summary>
    public void ShowForClick(IReadOnlyList<string> chosen, bool atPointer = true)
    {
        clickMode = true;
        dropped = false;
        SetFiles(chosen.ToArray());
        if (atPointer) Native.GetCursorPos(out anchor);
        else anchor = PrimaryScreenCenter();
        Present(activate: true);
    }

    /// <summary>The mouse button was let go somewhere: if it wasn't a drop on the wheel, close.</summary>
    public void MouseReleased()
    {
        if (IsVisible && !clickMode) hideAfterRelease.Start();
    }

    public void Dismiss()
    {
        hideAfterRelease.Stop();
        view.Hovered = -1;
        Hide();
    }

    void Present(bool activate)
    {
        ShowActivated = activate;
        if (!IsVisible) Show();
        PlaceAtAnchor();
        if (activate)
        {
            Activate();
            Focus();
        }
    }

    /// <summary>Centers the wheel on the pointer, kept inside the screen (in physical pixels, so every display scale works).</summary>
    void PlaceAtAnchor()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero || !Native.GetWindowRect(handle, out var rect)) return;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        var monitor = Native.MonitorFromPoint(anchor, Native.MONITOR_DEFAULTTONEAREST);
        double x = anchor.X, y = anchor.Y;
        if (Native.GetMonitorInfo(monitor, ref info))
        {
            var work = info.rcWork;
            (x, y) = WheelLayout.ClampedCenter(anchor.X, anchor.Y, width / 2.0, work.Left, work.Top, work.Right, work.Bottom);
        }
        Native.SetWindowPos(handle, Native.HWND_TOPMOST, (int)Math.Round(x - width / 2.0), (int)Math.Round(y - height / 2.0), 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    static Native.POINT PrimaryScreenCenter()
    {
        var area = System.Windows.Forms.Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1280, 800);
        return new Native.POINT { X = area.Left + area.Width / 2, Y = area.Top + area.Height / 2 };
    }

    void SetFiles(string[] chosen)
    {
        files = chosen;
        var wedges = Formats.For(files);
        var kinds = files.Select(FileKinds.Of).Distinct().ToList();
        var kind = kinds.Count == 1 ? kinds[0] : null;
        var hasFfmpeg = ffmpeg() is not null;
        var unavailable = new HashSet<OutputFormat>(hasFfmpeg ? Enumerable.Empty<OutputFormat>() : wedges.Where(format => files.Any(file => FileKinds.Of(file) is { } k && format.NeedsFfmpeg(k))));
        string? message = files.Length > 0 && wedges.Count == 0
            ? kinds.Contains(null) ? "These files can't be converted yet" : "Nothing converts all of these at once"
            : null;
        view.Show(wedges, unavailable, kind, files.Length, message);
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        e.Effects = DragDropEffects.None;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] dragged) return;
        if (!dragged.SequenceEqual(files)) SetFiles(dragged);
        var index = Hover(e.GetPosition(view));
        // A copy, whatever keys are held: the originals stay where they are.
        if (index >= 0) e.Effects = DragDropEffects.Copy;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] dragged) return;
        if (!dragged.SequenceEqual(files)) SetFiles(dragged);
        var index = Hover(e.GetPosition(view));
        dropped = true;
        e.Effects = index >= 0 ? DragDropEffects.Copy : DragDropEffects.None;
        if (index >= 0) Choose(index);
        else Dismiss();
    }

    void OnClick(object sender, MouseButtonEventArgs e)
    {
        if (!clickMode) return;
        var index = Hover(e.GetPosition(view));
        if (index >= 0) Choose(index);
        else Dismiss();
    }

    /// <summary>Lights the wedge under the point; its index, or -1 (the hub, outside, or one that needs ffmpeg).</summary>
    int Hover(Point point)
    {
        var hit = view.HitAt(point);
        view.Hovered = hit.Area == HitArea.Wedge ? hit.Index : -1;
        return hit.Area == HitArea.Wedge && view.IsAvailable(hit.Index) ? hit.Index : -1;
    }

    void Choose(int index)
    {
        var format = view.Wedges[index];
        var chosen = files.Where(path => File.Exists(path) || Directory.Exists(path)).ToList();
        Dismiss();
        if (chosen.Count > 0) convert(chosen, format);
    }
}
