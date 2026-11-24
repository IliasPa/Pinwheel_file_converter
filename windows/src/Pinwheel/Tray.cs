using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

namespace Pinwheel;

/// <summary>Pinwheel's icon by the clock, with its menu and its messages.</summary>
sealed class Tray : IDisposable
{
    readonly NotifyIcon icon;
    string? reveal;

    public Tray(App app)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Convert Files…", null, (_, _) => app.ChooseFiles());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => app.ShowSettings());
        menu.Items.Add("Pinwheel on GitHub", null, (_, _) => Shell.OpenLink(App.Website));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit Pinwheel", null, (_, _) => app.Quit());

        icon = new NotifyIcon
        {
            Icon = LoadIcon(SystemInformation.SmallIconSize),
            Text = "Pinwheel: drag files, hold Shift",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.DoubleClick += (_, _) => app.ShowSettings();
        icon.BalloonTipClicked += (_, _) =>
        {
            if (reveal is not null) Shell.ShowInExplorer(reveal);
        };
    }

    /// <summary>A message by the clock; clicking it shows <paramref name="show"/> in Explorer.</summary>
    public void Notify(string title, string text, string? show = null)
    {
        reveal = show;
        icon.ShowBalloonTip(6000, title, text, ToolTipIcon.None);
    }

    public static Icon LoadIcon(Size size)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Pinwheel.ico");
        return stream is null ? SystemIcons.Application : new Icon(stream, size);
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
