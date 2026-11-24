namespace Pinwheel.Core;

/// <summary>The kinds of files the wheel knows.</summary>
public enum FileKind { Image, Video, Audio, Archive }

/// <summary>What a file can become: a wedge on the wheel.</summary>
public enum OutputFormat
{
    Png, Jpeg, WebP, Avif, Gif, Pdf, Tiff, Bmp, Ico,
    Mp4, Mkv, WebM, Mov, Avi, Wmv,
    Mp3, M4a, Wav, Flac, Ogg, Opus, Wma,
    Extract,
}

public static class FileKinds
{
    static readonly Dictionary<string, FileKind> ByExtension = Build();

    static Dictionary<string, FileKind> Build()
    {
        var map = new Dictionary<string, FileKind>(StringComparer.OrdinalIgnoreCase);
        // WebP, HEIC and AVIF open with Microsoft's free extensions (or ffmpeg).
        foreach (var e in "jpg jpeg jpe jfif png bmp dib gif tif tiff ico webp heic heif avif jxr wdp".Split(' ')) map[e] = FileKind.Image;
        foreach (var e in "mp4 m4v mov mkv webm avi wmv mts m2ts ts flv mpg mpeg 3gp".Split(' ')) map[e] = FileKind.Video;
        foreach (var e in "mp3 m4a aac wav flac ogg oga opus wma aiff aif".Split(' ')) map[e] = FileKind.Audio;
        foreach (var e in "zip 7z rar tar gz tgz bz2 xz".Split(' ')) map[e] = FileKind.Archive;
        return map;
    }

    /// <summary>The kind, from the file's extension; null for anything else.</summary>
    public static FileKind? Of(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.');
        return ByExtension.TryGetValue(extension, out var kind) ? kind : null;
    }
}

public static class Formats
{
    /// <summary>The wedges for one kind of file, clockwise from the top.</summary>
    public static IReadOnlyList<OutputFormat> For(FileKind kind) => kind switch
    {
        FileKind.Image => [OutputFormat.Png, OutputFormat.Jpeg, OutputFormat.WebP, OutputFormat.Avif, OutputFormat.Gif, OutputFormat.Pdf, OutputFormat.Tiff, OutputFormat.Bmp, OutputFormat.Ico],
        FileKind.Video => [OutputFormat.Mp4, OutputFormat.Mkv, OutputFormat.WebM, OutputFormat.Mov, OutputFormat.Avi, OutputFormat.Wmv, OutputFormat.Gif, OutputFormat.Mp3, OutputFormat.M4a],
        FileKind.Audio => [OutputFormat.Mp3, OutputFormat.M4a, OutputFormat.Wav, OutputFormat.Flac, OutputFormat.Ogg, OutputFormat.Opus, OutputFormat.Wma],
        FileKind.Archive => [OutputFormat.Extract],
        _ => [],
    };

    /// <summary>
    /// The wedges for these files: the formats every one of them can become,
    /// leaving out the format they all already are.
    /// </summary>
    public static IReadOnlyList<OutputFormat> For(IReadOnlyCollection<string> files)
    {
        if (files.Count == 0) return [];
        IEnumerable<OutputFormat>? common = null;
        foreach (var file in files)
        {
            var kind = FileKinds.Of(file);
            if (kind is null) return [];
            common = common is null ? For(kind.Value) : common.Intersect(For(kind.Value));
        }
        var already = files.Select(Matching).Distinct().ToList();
        return common!.Where(format => !(already.Count == 1 && already[0] == format)).ToList();
    }

    /// <summary>The format a file already is, when it's one Pinwheel writes.</summary>
    public static OutputFormat? Matching(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant() switch
    {
        "png" => OutputFormat.Png,
        "jpg" or "jpeg" or "jpe" or "jfif" => OutputFormat.Jpeg,
        "webp" => OutputFormat.WebP,
        "avif" => OutputFormat.Avif,
        "gif" => OutputFormat.Gif,
        "pdf" => OutputFormat.Pdf,
        "tif" or "tiff" => OutputFormat.Tiff,
        "bmp" or "dib" => OutputFormat.Bmp,
        "ico" => OutputFormat.Ico,
        "mp4" or "m4v" => OutputFormat.Mp4,
        "mkv" => OutputFormat.Mkv,
        "webm" => OutputFormat.WebM,
        "mov" => OutputFormat.Mov,
        "avi" => OutputFormat.Avi,
        "wmv" => OutputFormat.Wmv,
        "mp3" => OutputFormat.Mp3,
        "m4a" => OutputFormat.M4a,
        "wav" => OutputFormat.Wav,
        "flac" => OutputFormat.Flac,
        "ogg" or "oga" => OutputFormat.Ogg,
        "opus" => OutputFormat.Opus,
        "wma" => OutputFormat.Wma,
        _ => null,
    };

    public static string Title(this OutputFormat format) => format switch
    {
        OutputFormat.Png => "PNG",
        OutputFormat.Jpeg => "JPEG",
        OutputFormat.WebP => "WebP",
        OutputFormat.Avif => "AVIF",
        OutputFormat.Gif => "GIF",
        OutputFormat.Pdf => "PDF",
        OutputFormat.Tiff => "TIFF",
        OutputFormat.Bmp => "BMP",
        OutputFormat.Ico => "ICO",
        OutputFormat.Mp4 => "MP4",
        OutputFormat.Mkv => "MKV",
        OutputFormat.WebM => "WebM",
        OutputFormat.Mov => "MOV",
        OutputFormat.Avi => "AVI",
        OutputFormat.Wmv => "WMV",
        OutputFormat.Mp3 => "MP3",
        OutputFormat.M4a => "M4A",
        OutputFormat.Wav => "WAV",
        OutputFormat.Flac => "FLAC",
        OutputFormat.Ogg => "OGG",
        OutputFormat.Opus => "Opus",
        OutputFormat.Wma => "WMA",
        OutputFormat.Extract => "Extract",
        _ => format.ToString(),
    };

    /// <summary>The new file's extension; null when the result is a folder.</summary>
    public static string? Extension(this OutputFormat format) => format switch
    {
        OutputFormat.Jpeg => "jpg",
        OutputFormat.Tiff => "tif",
        OutputFormat.Extract => null,
        _ => format.ToString().ToLowerInvariant(),
    };

    /// <summary>One short line for the middle of the wheel.</summary>
    public static string Detail(this OutputFormat format, FileKind? from) => format switch
    {
        OutputFormat.Png => "Lossless, keeps transparency",
        OutputFormat.Jpeg => "Small files, works everywhere",
        OutputFormat.WebP => "Small files for websites",
        OutputFormat.Avif => "The smallest files, sharp details",
        OutputFormat.Gif => from == FileKind.Video ? "An animated GIF of the clip" : "Works in any browser or chat",
        OutputFormat.Pdf => "All the pictures in one PDF, a page each",
        OutputFormat.Tiff => "Lossless, for print and editing",
        OutputFormat.Bmp => "Uncompressed, for older apps",
        OutputFormat.Ico => "Windows icon, 16 to 256 pixels",
        OutputFormat.Mp4 => "Plays everywhere",
        OutputFormat.Mkv => "Keeps every sound track; plays in VLC",
        OutputFormat.WebM => "For websites: VP9 picture, Opus sound",
        OutputFormat.Mov => "QuickTime movie",
        OutputFormat.Avi => "For older players and TVs",
        OutputFormat.Wmv => "For Windows Media Player",
        OutputFormat.Mp3 => from == FileKind.Video ? "Just the sound, MP3" : "Plays on any device",
        OutputFormat.M4a => from == FileKind.Video ? "Just the sound, AAC" : "AAC, small and good quality",
        OutputFormat.Wav => "Uncompressed, universal",
        OutputFormat.Flac => "Lossless and compressed",
        OutputFormat.Ogg => "Ogg Vorbis, an open format",
        OutputFormat.Opus => "The best sound for its size",
        OutputFormat.Wma => "Windows Media Audio",
        OutputFormat.Extract => "Everything inside, in a folder beside it",
        _ => "",
    };

    /// <summary>Whether ffmpeg makes it (from this kind of file).</summary>
    public static bool NeedsFfmpeg(this OutputFormat format, FileKind from) =>
        from is FileKind.Video or FileKind.Audio || format is OutputFormat.WebP or OutputFormat.Avif;

    /// <summary>A Segoe Fluent Icons (or MDL2 Assets) glyph for the wedge.</summary>
    public static string Glyph(this OutputFormat format) => format switch
    {
        OutputFormat.Png or OutputFormat.Bmp or OutputFormat.Avif or OutputFormat.Ico => "",  // Picture
        OutputFormat.Jpeg => "",  // Camera
        OutputFormat.WebP or OutputFormat.WebM => "",  // Globe
        OutputFormat.Gif => "",  // Play
        OutputFormat.Pdf or OutputFormat.Tiff => "",  // Document
        OutputFormat.Mp4 or OutputFormat.Mkv or OutputFormat.Mov or OutputFormat.Avi or OutputFormat.Wmv => "",  // Video
        OutputFormat.Mp3 or OutputFormat.Ogg or OutputFormat.Wma => "",  // MusicNote
        OutputFormat.Opus => "",  // Microphone
        OutputFormat.M4a or OutputFormat.Wav or OutputFormat.Flac => "",  // Audio
        OutputFormat.Extract => "",  // FolderOpen
        _ => "",
    };
}
