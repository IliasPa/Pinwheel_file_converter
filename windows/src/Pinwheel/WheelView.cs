using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Microsoft.Win32;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>
/// Draws the wheel: a ring of wedges, one per format, around a hub that
/// says what the wedge under the pointer does.
/// </summary>
sealed class WheelView : FrameworkElement
{
    public const double OuterRadius = 168;
    public const double InnerRadius = 64;
    public const double ShadowRoom = 26;
    public const double Diameter = 2 * (OuterRadius + ShadowRoom);

    IReadOnlyList<OutputFormat> formats = [];
    ISet<OutputFormat> unavailable = new HashSet<OutputFormat>();
    FileKind? kind;
    int fileCount;
    int hovered = -1;
    string? message;

    public WheelView()
    {
        Width = Height = Diameter;
        Effect = new DropShadowEffect { BlurRadius = 22, ShadowDepth = 4, Direction = 270, Opacity = 0.32, Color = Colors.Black };
    }

    public WheelLayout Layout => new(formats.Count, InnerRadius, OuterRadius);
    public IReadOnlyList<OutputFormat> Wedges => formats;

    /// <summary>The wedges for these files; <paramref name="unavailable"/> are shown dimmed (they need ffmpeg).</summary>
    public void Show(IReadOnlyList<OutputFormat> formats, ISet<OutputFormat> unavailable, FileKind? kind, int fileCount, string? message = null)
    {
        this.formats = formats;
        this.unavailable = unavailable;
        this.kind = kind;
        this.fileCount = fileCount;
        this.message = message;
        hovered = -1;
        InvalidateVisual();
    }

    public int Hovered
    {
        get => hovered;
        set
        {
            if (hovered == value) return;
            hovered = value;
            InvalidateVisual();
        }
    }

    /// <summary>Where <paramref name="point"/> (in this view) is on the wheel.</summary>
    public WheelHit HitAt(Point point) => Layout.Hit(point.X - Diameter / 2, point.Y - Diameter / 2);

    public bool IsAvailable(int index) => index >= 0 && index < formats.Count && !unavailable.Contains(formats[index]);

    record Palette(Color Disc, Color Wedge, Color WedgeOff, Color Hub, Color Text, Color Secondary, Color Accent, Color OnAccent);

    static Palette Colors_ => IsDarkMode()
        ? new(Color.FromArgb(240, 38, 38, 42), Color.FromRgb(56, 56, 62), Color.FromRgb(46, 46, 50), Color.FromRgb(48, 48, 54),
              Color.FromRgb(245, 245, 247), Color.FromRgb(170, 170, 178), Color.FromRgb(56, 98, 238), Colors.White)
        : new(Color.FromArgb(240, 246, 246, 248), Color.FromRgb(228, 228, 232), Color.FromRgb(238, 238, 241), Color.FromRgb(234, 234, 238),
              Color.FromRgb(28, 28, 30), Color.FromRgb(110, 110, 118), Color.FromRgb(51, 85, 232), Colors.White);

    /// <summary>Windows' own light or dark choice for apps.</summary>
    static bool IsDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    static readonly Typeface Label = new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    static readonly Typeface Body = new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    static readonly Typeface Icons = new(new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

    protected override void OnRender(DrawingContext context)
    {
        var palette = Colors_;
        var center = new Point(Diameter / 2, Diameter / 2);
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        context.DrawEllipse(new SolidColorBrush(palette.Disc), new Pen(new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)), 1), center, OuterRadius + 6, OuterRadius + 6);

        var layout = Layout;
        for (var i = 0; i < formats.Count; i++)
        {
            var on = i == hovered && IsAvailable(i);
            var fill = new SolidColorBrush(on ? palette.Accent : IsAvailable(i) ? palette.Wedge : palette.WedgeOff);
            var geometry = Wedge(center, layout, i);
            var stroke = new Pen(fill, WedgeOutline.StrokeWidth(InnerRadius, OuterRadius, CornerRadius)) { LineJoin = PenLineJoin.Round };
            context.DrawGeometry(fill, formats.Count == 1 ? null : stroke, geometry);

            var textColor = on ? palette.OnAccent : IsAvailable(i) ? palette.Text : palette.Secondary;
            var (x, y) = WheelLayout.PointAt(center.X, center.Y, (InnerRadius + OuterRadius) / 2, layout.CenterAngle(i));
            var glyph = Text(formats[i].Glyph(), Icons, 22, textColor, dpi);
            var title = Text(formats[i].Title(), Label, 13.5, textColor, dpi);
            var top = y - (glyph.Height + 2 + title.Height) / 2;
            context.DrawText(glyph, new Point(x - glyph.Width / 2, top));
            context.DrawText(title, new Point(x - title.Width / 2, top + glyph.Height + 2));
        }

        // The hub.
        context.DrawEllipse(new SolidColorBrush(palette.Hub), null, center, InnerRadius - 6, InnerRadius - 6);
        var (heading, detail) = HubText();
        var head = Text(heading, Label, 15, palette.Text, dpi, maxWidth: 2 * InnerRadius - 22);
        var sub = Text(detail, Body, 11.5, palette.Secondary, dpi, maxWidth: 2 * InnerRadius - 26);
        head.MaxLineCount = 1;
        sub.MaxLineCount = 4;
        var block = head.Height + 2 + sub.Height;
        context.DrawText(head, new Point(center.X - (2 * InnerRadius - 22) / 2, center.Y - block / 2));
        context.DrawText(sub, new Point(center.X - (2 * InnerRadius - 26) / 2, center.Y - block / 2 + head.Height + 2));
    }

    const double Gap = 7;
    const double CornerRadius = 9;

    static Geometry Wedge(Point center, WheelLayout layout, int index)
    {
        if (layout.Count == 1)
        {
            // One wedge is the whole ring.
            return new CombinedGeometry(GeometryCombineMode.Exclude,
                new EllipseGeometry(center, OuterRadius, OuterRadius), new EllipseGeometry(center, InnerRadius, InnerRadius));
        }
        var points = WedgeOutline.Points(center.X, center.Y, InnerRadius, OuterRadius, layout.StartAngle(index), layout.EndAngle(index), Gap, CornerRadius);
        var geometry = new StreamGeometry();
        if (points.Count == 0) return geometry;
        using (var stream = geometry.Open())
        {
            stream.BeginFigure(new Point(points[0].X, points[0].Y), isFilled: true, isClosed: true);
            stream.PolyLineTo(points.Skip(1).Select(p => new Point(p.X, p.Y)).ToList(), isStroked: true, isSmoothJoin: true);
        }
        geometry.Freeze();
        return geometry;
    }

    (string Heading, string Detail) HubText()
    {
        if (hovered >= 0 && hovered < formats.Count)
        {
            var format = formats[hovered];
            if (!IsAvailable(hovered)) return (format.Title(), "Needs ffmpeg: see Settings");
            return (format.Title(), format.Detail(kind));
        }
        if (message is not null) return ("Pinwheel", message);
        var files = fileCount == 1 ? "1 file" : $"{fileCount} files";
        return fileCount == 0 ? ("Pinwheel", "Drop files on a format") : (files, "Drop on a format");
    }

    static FormattedText Text(string text, Typeface typeface, double size, Color color, double pixelsPerDip, double maxWidth = 0)
    {
        var formatted = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, typeface, size, new SolidColorBrush(color), pixelsPerDip);
        if (maxWidth > 0)
        {
            formatted.MaxTextWidth = maxWidth;
            formatted.TextAlignment = TextAlignment.Center;
            formatted.Trimming = TextTrimming.CharacterEllipsis;
        }
        return formatted;
    }
}
