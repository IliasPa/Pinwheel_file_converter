using System.Text.Json;

namespace Pinwheel.Core;

/// <summary>Pinwheel's settings, kept in %APPDATA%\Pinwheel\settings.json.</summary>
public sealed class PinwheelSettings
{
    /// <summary>The wheel opens when Shift is held while dragging files.</summary>
    public bool WheelOnShiftDrag { get; set; } = true;
    /// <summary>50 to 100.</summary>
    public int JpegQuality { get; set; } = 85;
    /// <summary>Empty: found by itself (winget, Chocolatey, Scoop, PATH).</summary>
    public string FfmpegPath { get; set; } = "";
    public int GifWidth { get; set; } = 480;
    public int GifFramesPerSecond { get; set; } = 12;
    public int GifMaxSeconds { get; set; } = 15;
    /// <summary>Settings opened once, the first time, to say hello.</summary>
    public bool WelcomeShown { get; set; }

    public GifOptions Gif => new(GifWidth, GifFramesPerSecond, GifMaxSeconds);

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinwheel", "settings.json");

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    /// <summary>The saved settings, or the usual ones if there are none (or they can't be read).</summary>
    public static PinwheelSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return (JsonSerializer.Deserialize<PinwheelSettings>(File.ReadAllText(path), Options) ?? new PinwheelSettings()).Checked();
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
        }
        return new PinwheelSettings();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(Checked(), Options));
        File.Move(temporary, path, overwrite: true);
    }

    /// <summary>Numbers back inside what makes sense (a hand-edited file).</summary>
    PinwheelSettings Checked()
    {
        JpegQuality = Math.Clamp(JpegQuality, 50, 100);
        GifWidth = Math.Clamp(GifWidth, 120, 1920);
        GifFramesPerSecond = Math.Clamp(GifFramesPerSecond, 5, 30);
        GifMaxSeconds = Math.Clamp(GifMaxSeconds, 1, 120);
        FfmpegPath ??= "";
        return this;
    }
}

/// <summary>Finds ffmpeg.exe: where Settings says, beside Pinwheel, or where installers put it.</summary>
public static class FfmpegLocator
{
    /// <summary>
    /// The places looked at, in order. winget's Links folder is looked at
    /// directly: Pinwheel's own PATH doesn't change until it starts again.
    /// </summary>
    public static IEnumerable<string> Candidates(string custom, string? pathVariable, string localAppData, string userProfile, string programData, string? besidePinwheel)
    {
        if (!string.IsNullOrWhiteSpace(custom)) yield return custom.Trim().Trim('"');
        if (besidePinwheel is not null) yield return Path.Combine(besidePinwheel, "ffmpeg.exe");
        foreach (var folder in (pathVariable ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            yield return Path.Combine(folder.Trim('"'), "ffmpeg.exe");
        yield return Path.Combine(localAppData, "Microsoft", "WinGet", "Links", "ffmpeg.exe");
        yield return Path.Combine(programData, "chocolatey", "bin", "ffmpeg.exe");
        yield return Path.Combine(userProfile, "scoop", "shims", "ffmpeg.exe");
        yield return @"C:\ffmpeg\bin\ffmpeg.exe";
    }

    public static string? Find(string custom, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        var candidates = Candidates(
            custom,
            Environment.GetEnvironmentVariable("PATH"),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            AppContext.BaseDirectory);
        foreach (var candidate in candidates)
        {
            if (exists(candidate)) return candidate;
        }
        // winget's own folder, in case its Links folder wasn't made.
        var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Packages");
        try
        {
            if (Directory.Exists(packages))
            {
                foreach (var folder in Directory.EnumerateDirectories(packages, "*FFmpeg*"))
                {
                    var found = Directory.EnumerateFiles(folder, "ffmpeg.exe", SearchOption.AllDirectories).FirstOrDefault();
                    if (found is not null) return found;
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
        return null;
    }
}
