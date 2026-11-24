namespace Pinwheel.Core;

/// <summary>Settings for GIFs made from videos.</summary>
public sealed record GifOptions(int Width = 480, int FramesPerSecond = 12, int MaxSeconds = 15);

/// <summary>What ffmpeg is told for each format.</summary>
public static class FfmpegArguments
{
    /// <summary>
    /// The arguments that turn <paramref name="input"/> into
    /// <paramref name="output"/>. ffmpeg never overwrites (-n): Pinwheel
    /// only writes to names that are free.
    /// </summary>
    public static IReadOnlyList<string> For(OutputFormat format, FileKind from, string input, string output, GifOptions? gif = null)
    {
        var args = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error", "-n", "-i", input };
        var audioOnly = from == FileKind.Audio;
        switch (format)
        {
            // Videos: the picture and every sound track.
            case OutputFormat.Mp4 or OutputFormat.Mov:
                args.AddRange(["-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                               "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]);
                break;
            case OutputFormat.Mkv:
                // Copied as they are: quick, and nothing is lost.
                args.AddRange(["-map", "0:v", "-map", "0:a?", "-c", "copy"]);
                break;
            case OutputFormat.WebM:
                args.AddRange(["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                               "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k", "-af", OpusLayouts]);
                break;
            case OutputFormat.Avi:
                args.AddRange(["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid", "-c:a", "libmp3lame", "-b:a", "192k"]);
                break;
            case OutputFormat.Wmv:
                args.AddRange(["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k", "-ac", "2"]);
                break;
            case OutputFormat.Gif when from == FileKind.Video:
                {
                    var options = gif ?? new GifOptions();
                    // One palette made for this clip, finely mixed: no bands.
                    args.AddRange(["-t", options.MaxSeconds.ToString(), "-vf",
                        $"fps={options.FramesPerSecond},scale='min({options.Width},iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                        "-loop", "0"]);
                    break;
                }

            // Sound. From a music file its cover comes along where the format holds one.
            case OutputFormat.Mp3:
                args.AddRange(audioOnly ? WithCover : JustSound);
                if (audioOnly) args.AddRange(["-id3v2_version", "3"]);
                args.AddRange(["-c:a", "libmp3lame", "-q:a", "0"]);
                break;
            case OutputFormat.M4a:
                args.AddRange(audioOnly ? WithCover : JustSound);
                args.AddRange(["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]);
                break;
            case OutputFormat.Flac:
                args.AddRange(audioOnly ? WithCover : JustSound);
                args.AddRange(["-c:a", "flac"]);
                break;
            case OutputFormat.Wav:
                args.AddRange(["-map", "0:a:0", "-c:a", "pcm_s16le"]);
                break;
            case OutputFormat.Ogg:
                args.AddRange(["-map", "0:a:0", "-c:a", "libvorbis", "-q:a", "6"]);
                break;
            case OutputFormat.Opus:
                args.AddRange(["-map", "0:a:0", "-c:a", "libopus", "-b:a", "160k", "-af", OpusLayouts]);
                break;
            case OutputFormat.Wma:
                // WMA holds two channels at most: 5.1 is mixed down.
                args.AddRange(["-map", "0:a:0", "-c:a", "wmav2", "-b:a", "192k", "-ac", "2"]);
                break;

            // Pictures ffmpeg writes (Windows can't): an animated GIF stays animated as WebP.
            case OutputFormat.WebP:
                args.AddRange(["-c:v", "libwebp", "-quality", "85", "-loop", "0"]);
                break;
            case OutputFormat.Avif:
                args.AddRange(["-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "28", "-cpu-used", "6", "-pix_fmt", "yuv420p"]);
                break;

            default:
                throw new ArgumentException($"ffmpeg doesn't make {format.Title()} from {from}.", nameof(format));
        }
        args.Add(output);
        return args;
    }

    /// <summary>
    /// Opus takes mono, stereo, 5.1 and 7.1 in its own channel order; this
    /// lets ffmpeg put "5.1 (side)" and the like into one of those.
    /// </summary>
    static readonly string[] WithCover = ["-map", "0:a:0", "-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic"];
    static readonly string[] JustSound = ["-map", "0:a:0"];

    const string OpusLayouts = "aformat=channel_layouts=7.1|5.1|stereo|mono";

    /// <summary>A short reason from ffmpeg's error output.</summary>
    public static string Reason(string errorOutput)
    {
        var lines = errorOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length == 0) return "ffmpeg stopped without saying why.";
        var last = string.Join(" ", lines.TakeLast(2));
        return last.Length > 300 ? last[..300] + "…" : last;
    }
}
