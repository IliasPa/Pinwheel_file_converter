using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using Pinwheel.Core;

namespace Pinwheel.Core.Tests;

public class FormatsTests
{
    [Fact]
    public void EachKindHasItsWedgesInOrder()
    {
        Assert.Equal(OutputFormat.Png, Formats.For(FileKind.Image)[0]);
        Assert.Equal(9, Formats.For(FileKind.Image).Count);
        Assert.Equal(OutputFormat.Mp4, Formats.For(FileKind.Video)[0]);
        Assert.Equal(new[] { OutputFormat.Extract }, Formats.For(FileKind.Archive));
        Assert.Equal(FileKind.Image, FileKinds.Of(@"C:\a\photo.HEIC"));
        Assert.Equal(FileKind.Archive, FileKinds.Of("backup.tar.gz"));
        Assert.Null(FileKinds.Of("notes.txt"));
    }

    [Fact]
    public void TheFormatFilesAlreadyHaveIsLeftOut()
    {
        var wedges = Formats.For(new[] { "a.png", "b.PNG" });
        Assert.DoesNotContain(OutputFormat.Png, wedges);
        Assert.Contains(OutputFormat.Jpeg, wedges);
        // Mixed: PNG stays, since the JPEG can become one.
        Assert.Contains(OutputFormat.Png, Formats.For(new[] { "a.png", "b.jpg" }));
    }

    [Fact]
    public void MixedKindsGetWhatEveryOneCanBecome()
    {
        Assert.Equal(new[] { OutputFormat.Gif }, Formats.For(new[] { "clip.mp4", "photo.jpg" }));
        Assert.Equal(new[] { OutputFormat.Mp3, OutputFormat.M4a }, Formats.For(new[] { "clip.mov", "song.flac" }));
        Assert.Empty(Formats.For(new[] { "photo.jpg", "notes.txt" }));
        Assert.Empty(Formats.For(Array.Empty<string>()));
    }

    [Fact]
    public void FfmpegIsNeededForVideoSoundWebPAndAvif()
    {
        Assert.True(OutputFormat.Gif.NeedsFfmpeg(FileKind.Video));
        Assert.False(OutputFormat.Gif.NeedsFfmpeg(FileKind.Image));
        Assert.True(OutputFormat.WebP.NeedsFfmpeg(FileKind.Image));
        Assert.False(OutputFormat.Extract.NeedsFfmpeg(FileKind.Archive));
        Assert.Equal("jpg", OutputFormat.Jpeg.Extension());
        Assert.Null(OutputFormat.Extract.Extension());
        Assert.All(Enum.GetValues<OutputFormat>(), format => Assert.NotEmpty(format.Glyph()));
    }
}

public class OutputNamingTests
{
    [Fact]
    public void NamesNeverReplaceAnything()
    {
        var folder = Path.Combine("x", "y");
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Path.Combine(folder, "photo (converted).png") };
        var naming = new OutputNaming { Exists = taken.Contains };
        var first = naming.Reserve(folder, "photo", "converted", "png");
        Assert.Equal(Path.Combine(folder, "photo (converted 2).png"), first);
        // Reserved but not written yet: the next job gets the next name.
        Assert.Equal(Path.Combine(folder, "photo (converted 3).png"), naming.Reserve(folder, "photo", "converted", "png"));
        naming.Release(first);
        // Windows ignores case: "Photo … .PNG" is the same name, free again.
        Assert.Equal(first, naming.Reserve(folder, "Photo", "converted", "PNG"), ignoreCase: true);
        Assert.Equal(Path.Combine(folder, "backup (extracted)"), naming.Reserve(folder, "backup", "extracted", null));
    }
}

public class WheelTests
{
    [Fact]
    public void HitsTheHubTheWedgesAndJustPastTheRim()
    {
        var layout = new WheelLayout(4, 60, 160);
        Assert.Equal(HitArea.Hub, layout.Hit(10, 10).Area);
        Assert.Equal(new WheelHit(HitArea.Wedge, 0), layout.Hit(0, -100));  // up (y is down)
        Assert.Equal(new WheelHit(HitArea.Wedge, 1), layout.Hit(100, 0));   // right
        Assert.Equal(new WheelHit(HitArea.Wedge, 2), layout.Hit(0, 100));   // down
        Assert.Equal(new WheelHit(HitArea.Wedge, 3), layout.Hit(-100, 0));  // left
        Assert.Equal(HitArea.Wedge, layout.Hit(0, -170).Area);              // past the rim, within the slack
        Assert.Equal(HitArea.Outside, layout.Hit(0, -200).Area);
        Assert.Equal(HitArea.Outside, new WheelLayout(0, 60, 160).Hit(0, -100).Area);
    }

    [Fact]
    public void TheWheelStaysOnTheScreen()
    {
        Assert.Equal((200.0, 300.0), WheelLayout.ClampedCenter(10, 300, 200, 0, 0, 1920, 1080));
        Assert.Equal((1720.0, 880.0), WheelLayout.ClampedCenter(1900, 1070, 200, 0, 0, 1920, 1080));
        Assert.Equal((960.0, 540.0), WheelLayout.ClampedCenter(960, 540, 200, 0, 0, 1920, 1080));
    }

    [Fact]
    public void AWedgeOutlineStaysInsideItsRing()
    {
        var layout = new WheelLayout(6, 64, 168);
        var points = WedgeOutline.Points(200, 200, 64, 168, layout.StartAngle(1), layout.EndAngle(1), 7, 9);
        Assert.True(points.Count > 10);
        foreach (var (x, y) in points)
        {
            var r = Math.Sqrt((x - 200) * (x - 200) + (y - 200) * (y - 200));
            Assert.InRange(r, 64 + 9 - 0.01, 168 - 9 + 0.01);
            Assert.Equal(HitArea.Wedge, layout.Hit(x - 200, y - 200).Area);
            Assert.Equal(1, layout.Hit(x - 200, y - 200).Index);
        }
        Assert.Empty(WedgeOutline.Points(0, 0, 64, 70, 0, 0.01, 7, 9));
    }
}

public class FfmpegArgumentsTests
{
    [Fact]
    public void NeverOverwritesAndWritesLast()
    {
        var args = FfmpegArguments.For(OutputFormat.Mp4, FileKind.Video, "in.mov", "out.mp4");
        Assert.True(args.ToList().IndexOf("-n") < args.ToList().IndexOf("-i"));
        Assert.Equal("out.mp4", args[^1]);
        Assert.Contains("libx264", args);
        Assert.Contains("+faststart", args);
    }

    [Fact]
    public void MusicKeepsItsCoverAndVideosGiveJustTheSound()
    {
        var fromSong = FfmpegArguments.For(OutputFormat.Mp3, FileKind.Audio, "a.flac", "a.mp3");
        Assert.Contains("0:v?", fromSong);
        Assert.Contains("attached_pic", fromSong);
        var fromVideo = FfmpegArguments.For(OutputFormat.Mp3, FileKind.Video, "a.mp4", "a.mp3");
        Assert.DoesNotContain("0:v?", fromVideo);
        Assert.Contains("libmp3lame", fromVideo);
        Assert.Contains("-ac", FfmpegArguments.For(OutputFormat.Wma, FileKind.Audio, "a.wav", "a.wma"));
    }

    [Fact]
    public void GifsFollowTheSettings()
    {
        var args = FfmpegArguments.For(OutputFormat.Gif, FileKind.Video, "a.mp4", "a.gif", new GifOptions(640, 15, 10));
        var filter = args[args.ToList().IndexOf("-vf") + 1];
        Assert.Contains("fps=15", filter);
        Assert.Contains("min(640,iw)", filter);
        Assert.Contains("palettegen", filter);
        Assert.Equal("10", args[args.ToList().IndexOf("-t") + 1]);
    }

    [Fact]
    public void WhatFfmpegDoesntMakeIsRefused()
    {
        Assert.Throws<ArgumentException>(() => FfmpegArguments.For(OutputFormat.Png, FileKind.Video, "a.mp4", "a.png"));
        Assert.Throws<ArgumentException>(() => FfmpegArguments.For(OutputFormat.Gif, FileKind.Image, "a.png", "a.gif"));
    }

    [Fact]
    public void TheReasonIsTheLastLines()
    {
        Assert.Equal("ffmpeg stopped without saying why.", FfmpegArguments.Reason(" \n"));
        Assert.Equal("b c", FfmpegArguments.Reason("a\nb\r\nc\n"));
    }
}

public class WriterTests
{
    [Fact]
    public void AnIconHasEachSize()
    {
        var bytes = IcoWriter.Write([(new byte[] { 1, 2, 3 }, 16), (new byte[] { 4, 5 }, 256)]);
        Assert.Equal(new byte[] { 0, 0, 1, 0, 2, 0 }, bytes[..6]);
        Assert.Equal(16, bytes[6]);
        Assert.Equal(0, bytes[6 + 16]);  // 256 is written as 0
        Assert.Equal(6 + 32, BitConverter.ToInt32(bytes, 6 + 12));
        Assert.Equal(new byte[] { 4, 5 }, bytes[^2..]);
    }

    [Fact]
    public void APdfHasAPageForEachPictureAndRightOffsets()
    {
        var jpeg = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 };
        var pdf = PdfWriter.Write([new PdfWriter.Page(jpeg, 300, 150, 150), new PdfWriter.Page(jpeg, 100, 100)]);
        var text = Encoding.Latin1.GetString(pdf);
        Assert.StartsWith("%PDF-1.4", text);
        Assert.EndsWith("%%EOF\n", text);
        Assert.Contains("/Count 2", text);
        Assert.Contains("/MediaBox [0 0 144 72]", text);  // 300 px at 150 dpi is 2 inches
        Assert.Contains("/MediaBox [0 0 100 100]", text);
        // Every object starts where the cross-reference table says.
        var xref = int.Parse(Regex.Match(text, @"startxref\n(\d+)").Groups[1].Value);
        var entries = Regex.Matches(text[xref..], @"(\d{10}) 00000 n").Select(m => int.Parse(m.Groups[1].Value)).ToList();
        Assert.Equal(8, entries.Count);
        for (var i = 0; i < entries.Count; i++) Assert.StartsWith($"{i + 1} 0 obj", text[entries[i]..]);
    }
}

public class ZipExtractorTests
{
    [Fact]
    public void ANameOutsideTheFolderIsSkippedAndTheRestOpens()
    {
        var folder = Directory.CreateTempSubdirectory("pinwheel-zip-").FullName;
        try
        {
            var zip = Path.Combine(folder, "a.zip");
            using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                Write(archive, "docs/readme.txt", "hello");
                Write(archive, "../escape.txt", "nope");
                Write(archive, "Γειά.txt", "greek");
            }
            var target = Path.Combine(folder, "a (extracted)");
            var result = ZipExtractor.Extract(zip, target);
            Assert.Equal(2, result.Files);
            Assert.Equal(new[] { "../escape.txt" }, result.Skipped);
            Assert.Equal("hello", File.ReadAllText(Path.Combine(target, "docs", "readme.txt")));
            Assert.True(File.Exists(Path.Combine(target, "Γειά.txt")));
            Assert.False(File.Exists(Path.Combine(folder, "escape.txt")));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }

        static void Write(ZipArchive archive, string name, string text)
        {
            using var writer = new StreamWriter(archive.CreateEntry(name).Open());
            writer.Write(text);
        }
    }
}

public class SettingsTests
{
    [Fact]
    public void SettingsComeBackAndOddNumbersAreKeptInRange()
    {
        var folder = Directory.CreateTempSubdirectory("pinwheel-settings-").FullName;
        try
        {
            var path = Path.Combine(folder, "Pinwheel", "settings.json");
            Assert.Equal(85, PinwheelSettings.Load(path).JpegQuality);
            new PinwheelSettings { JpegQuality = 140, GifWidth = 640, WheelOnShiftDrag = false }.Save(path);
            var back = PinwheelSettings.Load(path);
            Assert.Equal(100, back.JpegQuality);
            Assert.Equal(640, back.GifWidth);
            Assert.False(back.WheelOnShiftDrag);
            File.WriteAllText(path, "{ not json");
            Assert.True(PinwheelSettings.Load(path).WheelOnShiftDrag);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void FfmpegIsLookedForWhereInstallersPutIt()
    {
        var candidates = FfmpegLocator.Candidates("", @"C:\Tools;C:\Other", @"C:\Users\me\AppData\Local", @"C:\Users\me", @"C:\ProgramData", null).ToList();
        Assert.Equal(Path.Combine(@"C:\Tools", "ffmpeg.exe"), candidates[0]);
        Assert.Contains(Path.Combine(@"C:\Users\me\AppData\Local", "Microsoft", "WinGet", "Links", "ffmpeg.exe"), candidates);
        Assert.Equal(@"D:\ff\ffmpeg.exe", FfmpegLocator.Candidates("\"D:\\ff\\ffmpeg.exe\"", null, "", "", "", null).First());
        Assert.Equal(@"D:\ff\ffmpeg.exe", FfmpegLocator.Find(@"D:\ff\ffmpeg.exe", path => path == @"D:\ff\ffmpeg.exe"));
    }
}
