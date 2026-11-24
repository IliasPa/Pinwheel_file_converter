using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pinwheel.Core;

namespace Pinwheel.Tests;

/// <summary>
/// Draws the wheel as it looks, into PNGs (kept by the build when
/// PINWHEEL_SNAPSHOTS names a folder), and checks what's under the pointer.
/// </summary>
public class WheelTests
{
    static byte[] Draw(IReadOnlyList<OutputFormat> formats, ISet<OutputFormat> unavailable, FileKind kind, int files, int hovered)
    {
        var view = new WheelView();
        view.Show(formats, unavailable, kind, files);
        view.Hovered = hovered;
        var size = new Size(WheelView.Diameter, WheelView.Diameter);
        view.Measure(size);
        view.Arrange(new Rect(size));
        view.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)(WheelView.Diameter * 2), (int)(WheelView.Diameter * 2), 192, 192, PixelFormats.Pbgra32);
        bitmap.Render(view);
        return ImageWork.Encode(new PngBitmapEncoder(), bitmap);
    }

    static void Keep(string name, byte[] png)
    {
        var folder = Environment.GetEnvironmentVariable("PINWHEEL_SNAPSHOTS");
        if (string.IsNullOrEmpty(folder)) return;
        Directory.CreateDirectory(folder);
        File.WriteAllBytes(Path.Combine(folder, name), png);
    }

    [Fact]
    public async Task TheWheelsDraw()
    {
        var pictures = await Sta.Run(() => Draw(Formats.For(FileKind.Image), new HashSet<OutputFormat>(), FileKind.Image, 3, 1));
        var videos = await Sta.Run(() => Draw(Formats.For(FileKind.Video), Formats.For(FileKind.Video).ToHashSet(), FileKind.Video, 1, 0));
        var sound = await Sta.Run(() => Draw(Formats.For(FileKind.Audio), new HashSet<OutputFormat>(), FileKind.Audio, 2, -1));
        var archive = await Sta.Run(() => Draw(Formats.For(FileKind.Archive), new HashSet<OutputFormat>(), FileKind.Archive, 1, 0));
        Keep("wheel-pictures.png", pictures);
        Keep("wheel-video-without-ffmpeg.png", videos);
        Keep("wheel-sound.png", sound);
        Keep("wheel-archive.png", archive);
        Assert.All(new[] { pictures, videos, sound, archive }, png => Assert.True(png.Length > 5000));
    }

    [Fact]
    public async Task TheHoveredWedgeIsTheOneUnderThePointer()
    {
        var (top, right, hub, past) = await Sta.Run(() =>
        {
            var view = new WheelView();
            view.Show(Formats.For(FileKind.Audio), new HashSet<OutputFormat> { OutputFormat.Wma }, FileKind.Audio, 1);
            var c = WheelView.Diameter / 2;
            return (view.HitAt(new Point(c, c - 120)), view.HitAt(new Point(c + 120, c - 40)), view.HitAt(new Point(c, c)), view.HitAt(new Point(1, 1)));
        });
        Assert.Equal(new WheelHit(HitArea.Wedge, 0), top);
        Assert.Equal(HitArea.Wedge, right.Area);
        Assert.Equal(1, right.Index);
        Assert.Equal(HitArea.Hub, hub.Area);
        Assert.Equal(HitArea.Outside, past.Area);
    }
}
