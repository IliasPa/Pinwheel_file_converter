using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pinwheel.Core;

namespace Pinwheel.Tests;

/// <summary>A folder of its own for each test, removed afterwards.</summary>
public sealed class Scratch : IDisposable
{
    public string Folder { get; } = Directory.CreateTempSubdirectory("pinwheel-test-").FullName;
    public string File(string name) => Path.Combine(Folder, name);
    public void Dispose()
    {
        try { Directory.Delete(Folder, recursive: true); } catch (IOException) { }
    }
}

static class Pictures
{
    /// <summary>
    /// 120 × 80: red on the left half, blue on the right, with a see-through
    /// 20 × 20 corner at the top left.
    /// </summary>
    public static BitmapSource Sample(bool seeThrough = true)
    {
        const int width = 120, height = 80;
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4;
                var left = x < width / 2;
                pixels[i] = (byte)(left ? 0 : 255);      // B
                pixels[i + 1] = 0;                        // G
                pixels[i + 2] = (byte)(left ? 255 : 0);   // R
                pixels[i + 3] = (byte)(seeThrough && x < 20 && y < 20 ? 0 : 255);
            }
        }
        var picture = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        picture.Freeze();
        return picture;
    }

    public static string SavePng(string path, BitmapSource picture)
    {
        File.WriteAllBytes(path, ImageWork.Encode(new PngBitmapEncoder(), picture));
        return path;
    }

    /// <summary>A JPEG that says it was taken with the camera turned (EXIF orientation 6: turn 90° right to view).</summary>
    public static string SaveTurnedJpeg(string path)
    {
        var metadata = new BitmapMetadata("jpg");
        metadata.SetQuery("/app1/ifd/{ushort=274}", (ushort)6);
        var encoder = new JpegBitmapEncoder { QualityLevel = 95 };
        encoder.Frames.Add(BitmapFrame.Create(ImageWork.Flatten(Sample(false), Colors.White), null, metadata, null));
        using var file = File.Create(path);
        encoder.Save(file);
        return path;
    }

    /// <summary>The color at a pixel, as (r, g, b, a).</summary>
    public static (byte R, byte G, byte B, byte A) Pixel(BitmapSource picture, int x, int y)
    {
        var bgra = ImageWork.Bgra(picture);
        var pixel = new byte[4];
        bgra.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0);
        return (pixel[2], pixel[1], pixel[0], pixel[3]);
    }
}

public class PictureConversionTests
{
    static Converter NewConverter() => new(() => new PinwheelSettings()) { Naming = new OutputNaming() };

    [Theory]
    [InlineData(OutputFormat.Jpeg, "jpg")]
    [InlineData(OutputFormat.Png, "png")]
    [InlineData(OutputFormat.Bmp, "bmp")]
    [InlineData(OutputFormat.Tiff, "tif")]
    [InlineData(OutputFormat.Gif, "gif")]
    [InlineData(OutputFormat.Ico, "ico")]
    public async Task APictureBecomesEachFormatBesideTheOriginal(OutputFormat format, string extension)
    {
        using var scratch = new Scratch();
        // PNG into PNG is left off the wheel, so the PNG case starts from a BMP.
        var source = await Sta.Run(() =>
        {
            var path = scratch.File(format == OutputFormat.Png ? "photo.bmp" : "photo.png");
            File.WriteAllBytes(path, format == OutputFormat.Png
                ? ImageWork.Encode(new BmpBitmapEncoder(), ImageWork.Flatten(Pictures.Sample(false), Colors.White))
                : ImageWork.Encode(new PngBitmapEncoder(), Pictures.Sample()));
            return path;
        });
        var results = await NewConverter().ConvertAsync([source], format);
        var result = Assert.Single(results);
        Assert.Null(result.Problem);
        Assert.Equal(scratch.File($"photo (converted).{extension}"), result.Output);
        if (format == OutputFormat.Ico) return;  // its sizes are checked below
        var (width, height, right, corner) = await Sta.Run(() =>
        {
            var (picture, _) = ImageWork.Load(result.Output!);
            return (picture.PixelWidth, picture.PixelHeight, Pictures.Pixel(picture, 100, 60), Pictures.Pixel(picture, 5, 5));
        });
        Assert.Equal(120, width);
        Assert.Equal(80, height);
        Assert.True(right.B > 200 && right.R < 60, $"blue stays blue in {format}: {right}");
        if (format is OutputFormat.Jpeg or OutputFormat.Bmp)
            Assert.True(corner.R > 240 && corner.G > 240 && corner.B > 240, $"see-through becomes white in {format}: {corner}");
        else if (format != OutputFormat.Png)
            Assert.True(corner.A < 20, $"see-through stays see-through in {format}: {corner}");
    }

    [Fact]
    public async Task AnIconHasEverySizeUpToThePicture()
    {
        using var scratch = new Scratch();
        var source = await Sta.Run(() => Pictures.SavePng(scratch.File("logo.png"), Pictures.Sample()));
        var result = Assert.Single(await NewConverter().ConvertAsync([source], OutputFormat.Ico));
        var sizes = await Sta.Run(() =>
        {
            using var stream = File.OpenRead(result.Output!);
            var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            return decoder.Frames.Select(frame => frame.PixelWidth).ToList();
        });
        Assert.Equal(new[] { 16, 20, 24, 32, 40, 48, 64 }, sizes);
    }

    [Fact]
    public async Task NamesNeverReplaceAFile()
    {
        using var scratch = new Scratch();
        var source = await Sta.Run(() => Pictures.SavePng(scratch.File("photo.png"), Pictures.Sample()));
        File.WriteAllText(scratch.File("photo (converted).jpg"), "mine");
        var converter = NewConverter();
        var first = Assert.Single(await converter.ConvertAsync([source], OutputFormat.Jpeg));
        Assert.Equal(scratch.File("photo (converted 2).jpg"), first.Output);
        Assert.Equal("mine", File.ReadAllText(scratch.File("photo (converted).jpg")));
        var second = Assert.Single(await converter.ConvertAsync([source], OutputFormat.Jpeg));
        Assert.Equal(scratch.File("photo (converted 3).jpg"), second.Output);
    }

    [Fact]
    public async Task AJpegFromATurnedCameraComesOutUpright()
    {
        using var scratch = new Scratch();
        var source = await Sta.Run(() => Pictures.SaveTurnedJpeg(scratch.File("phone.jpg")));
        var result = Assert.Single(await NewConverter().ConvertAsync([source], OutputFormat.Png));
        Assert.Null(result.Problem);
        var (width, height, top) = await Sta.Run(() =>
        {
            var (picture, _) = ImageWork.Load(result.Output!);
            // Red was on the left; turned 90° to the right, it's on top.
            return (picture.PixelWidth, picture.PixelHeight, Pictures.Pixel(picture, 40, 10));
        });
        Assert.Equal(80, width);   // turned: 120 × 80 becomes 80 × 120
        Assert.Equal(120, height);
        Assert.True(top.R > 200 && top.B < 60, $"red on top: {top}");
    }

    [Fact]
    public async Task PicturesBecomeOnePdfWithAPageEach()
    {
        using var scratch = new Scratch();
        var first = await Sta.Run(() => Pictures.SavePng(scratch.File("a.png"), Pictures.Sample()));
        var second = await Sta.Run(() => Pictures.SavePng(scratch.File("b.png"), Pictures.Sample(false)));
        var results = await NewConverter().ConvertAsync([first, second], OutputFormat.Pdf);
        Assert.Equal(2, results.Count);
        Assert.All(results, result => Assert.Equal(scratch.File("a (converted).pdf"), result.Output));
        var text = Encoding.Latin1.GetString(File.ReadAllBytes(scratch.File("a (converted).pdf")));
        Assert.Contains("/Count 2", text);
        Assert.Equal(2, text.Split("/Subtype /Image").Length - 1);
        Assert.Single(Directory.GetFiles(scratch.Folder, "*.pdf"));
    }

    [Fact]
    public async Task WhatCantBeConvertedSaysWhy()
    {
        using var scratch = new Scratch();
        var broken = scratch.File("broken.png");
        File.WriteAllText(broken, "not a picture");
        var converter = new Converter(() => new PinwheelSettings { FfmpegPath = scratch.File("no-ffmpeg-here.exe") }) { Naming = new OutputNaming() };
        var result = Assert.Single(await converter.ConvertAsync([broken], OutputFormat.Jpeg));
        Assert.Null(result.Output);
        Assert.False(string.IsNullOrWhiteSpace(result.Problem));
        Assert.Empty(Directory.GetFiles(scratch.Folder, "*converted*"));
    }
}

public class ArchiveTests
{
    [Fact]
    public async Task AZipOpensIntoAFolderBesideIt()
    {
        using var scratch = new Scratch();
        var zip = scratch.File("photos.zip");
        using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
        {
            using var writer = new StreamWriter(archive.CreateEntry("trip/notes.txt").Open());
            writer.Write("hello");
        }
        var result = Assert.Single(await new Converter(() => new PinwheelSettings()).ConvertAsync([zip], OutputFormat.Extract));
        Assert.Equal(scratch.File("photos (extracted)"), result.Output);
        Assert.Equal("hello", File.ReadAllText(Path.Combine(result.Output!, "trip", "notes.txt")));
    }

    [Fact]
    public async Task ATarGzOpensWithWindowsOwnTar()
    {
        var tar = Path.Combine(Environment.SystemDirectory, "tar.exe");
        if (!File.Exists(tar)) return;  // older Windows
        using var scratch = new Scratch();
        Directory.CreateDirectory(scratch.File("pack"));
        File.WriteAllText(scratch.File(Path.Combine("pack", "a.txt")), "inside");
        var archive = scratch.File("pack.tar.gz");
        using (var process = Process.Start(new ProcessStartInfo(tar) { ArgumentList = { "-czf", archive, "-C", scratch.Folder, "pack" }, UseShellExecute = false, CreateNoWindow = true })!)
            process.WaitForExit();
        var result = Assert.Single(await new Converter(() => new PinwheelSettings()).ConvertAsync([archive], OutputFormat.Extract));
        Assert.Null(result.Problem);
        Assert.Equal("inside", File.ReadAllText(Path.Combine(result.Output!, "pack", "a.txt")));
    }
}

/// <summary>Video and sound, when ffmpeg is installed (GitHub's Windows machines get it from Chocolatey).</summary>
public class FfmpegConversionTests
{
    static readonly string? Ffmpeg = FfmpegLocator.Find("");

    static string MakeClip(Scratch scratch, string name, bool video)
    {
        var path = scratch.File(name);
        var arguments = video
            ? new[] { "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                      "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path }
            : new[] { "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ac", "2", path };
        var start = new ProcessStartInfo(Ffmpeg!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, errors);
        return path;
    }

    [Theory]
    [InlineData(OutputFormat.WebM)]
    [InlineData(OutputFormat.Mkv)]
    [InlineData(OutputFormat.Avi)]
    [InlineData(OutputFormat.Wmv)]
    [InlineData(OutputFormat.Mov)]
    [InlineData(OutputFormat.Gif)]
    [InlineData(OutputFormat.Mp3)]
    [InlineData(OutputFormat.M4a)]
    public async Task AVideoBecomes(OutputFormat format)
    {
        if (Ffmpeg is null) return;
        using var scratch = new Scratch();
        var clip = MakeClip(scratch, "clip.mp4", video: true);
        var result = Assert.Single(await new Converter(() => new PinwheelSettings()).ConvertAsync([clip], format));
        Assert.True(result.Problem is null, result.Problem);
        Assert.True(new FileInfo(result.Output!).Length > 1000);
    }

    [Theory]
    [InlineData(OutputFormat.Mp3)]
    [InlineData(OutputFormat.M4a)]
    [InlineData(OutputFormat.Flac)]
    [InlineData(OutputFormat.Ogg)]
    [InlineData(OutputFormat.Opus)]
    [InlineData(OutputFormat.Wma)]
    public async Task SoundBecomes(OutputFormat format)
    {
        if (Ffmpeg is null) return;
        using var scratch = new Scratch();
        var song = MakeClip(scratch, "tone.wav", video: false);
        var result = Assert.Single(await new Converter(() => new PinwheelSettings()).ConvertAsync([song], format));
        Assert.True(result.Problem is null, result.Problem);
        Assert.True(new FileInfo(result.Output!).Length > 1000);
    }

    [Theory]
    [InlineData(OutputFormat.WebP)]
    [InlineData(OutputFormat.Avif)]
    public async Task APictureBecomesWebPOrAvif(OutputFormat format)
    {
        if (Ffmpeg is null) return;
        using var scratch = new Scratch();
        var source = await Sta.Run(() => Pictures.SavePng(scratch.File("photo.png"), Pictures.Sample()));
        var result = Assert.Single(await new Converter(() => new PinwheelSettings()).ConvertAsync([source], format));
        Assert.True(result.Problem is null, result.Problem);
        Assert.True(new FileInfo(result.Output!).Length > 100);
    }
}
