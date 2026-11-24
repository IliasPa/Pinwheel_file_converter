using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>What became of one file: its new file (or folder), or why not.</summary>
sealed record JobResult(string Source, string? Output, string? Problem, string? Note = null)
{
    public bool Succeeded => Output is not null;
}

/// <summary>
/// Converts dropped files, several at a time, into new files beside them.
/// Nothing is ever overwritten, and the originals are never touched.
/// </summary>
sealed class Converter(Func<PinwheelSettings> settings)
{
    public OutputNaming Naming { get; init; } = OutputNaming.Shared;

    /// <summary>Pictures at once (one per core, up to four); ffmpeg two at a time (it uses every core itself).</summary>
    readonly SemaphoreSlim pictures = new(Math.Clamp(Environment.ProcessorCount, 1, 4));
    readonly SemaphoreSlim ffmpegJobs = new(2);

    public string? Ffmpeg => FfmpegLocator.Find(settings().FfmpegPath);

    public async Task<IReadOnlyList<JobResult>> ConvertAsync(IReadOnlyList<string> files, OutputFormat format)
    {
        // Pictures into PDF: one PDF with a page for each.
        if (format == OutputFormat.Pdf && files.Count > 0 && files.All(file => FileKinds.Of(file) == FileKind.Image))
            return await PicturesIntoPdf(files);
        var jobs = files.Select(file => ConvertOne(file, format));
        return await Task.WhenAll(jobs);
    }

    async Task<JobResult> ConvertOne(string source, OutputFormat format)
    {
        var kind = FileKinds.Of(source);
        if (kind is null || !Formats.For(kind.Value).Contains(format))
            return new JobResult(source, null, $"{Path.GetFileName(source)} can't become {format.Title()}.");
        var folder = Path.GetDirectoryName(Path.GetFullPath(source))!;
        var output = Naming.Reserve(folder, Path.GetFileNameWithoutExtension(source), format == OutputFormat.Extract ? "extracted" : "converted", format.Extension());
        try
        {
            string? note = null;
            if (kind == FileKind.Archive)
                note = await Extract(source, output);
            else if (format.NeedsFfmpeg(kind.Value))
                await FfmpegJob(source, kind.Value, format, output);
            else
                await PictureJob(source, format, output);
            return new JobResult(source, output, null, note);
        }
        catch (Exception exception)
        {
            TryDelete(output);
            return new JobResult(source, null, Reason(exception));
        }
        finally
        {
            Naming.Release(output);
        }
    }

    async Task PictureJob(string source, OutputFormat format, string output)
    {
        await pictures.WaitAsync();
        try
        {
            var quality = settings().JpegQuality;
            await Sta.Run(() =>
            {
                var picture = LoadPicture(source);
                ImageWork.Save(picture, format, output, quality);
            });
        }
        finally
        {
            pictures.Release();
        }
    }

    async Task<IReadOnlyList<JobResult>> PicturesIntoPdf(IReadOnlyList<string> files)
    {
        var first = files[0];
        var output = Naming.Reserve(Path.GetDirectoryName(Path.GetFullPath(first))!, Path.GetFileNameWithoutExtension(first), "converted", "pdf");
        await pictures.WaitAsync();
        try
        {
            var quality = settings().JpegQuality;
            await Sta.Run(() => ImageWork.SavePdf(files.Select(LoadPicture).ToList(), output, quality));
            var note = files.Count > 1 ? $"All {files.Count} pictures are in it." : null;
            return [new JobResult(first, output, null, note), .. files.Skip(1).Select(file => new JobResult(file, output, null))];
        }
        catch (Exception exception)
        {
            TryDelete(output);
            return files.Select(file => new JobResult(file, null, Reason(exception))).ToList();
        }
        finally
        {
            pictures.Release();
            Naming.Release(output);
        }
    }

    /// <summary>
    /// A picture Windows can open; else, with ffmpeg, a copy ffmpeg makes
    /// (HEIC or AVIF without Microsoft's extensions).
    /// </summary>
    BitmapSource LoadPicture(string source)
    {
        try
        {
            return ImageWork.Load(source).Picture;
        }
        catch (Exception exception) when (exception is NotSupportedException or FileFormatException or ArgumentException or InvalidOperationException
                                          or System.Runtime.InteropServices.COMException)
        {
            var ffmpeg = Ffmpeg ?? throw new ConversionException(
                $"Windows can't open {Path.GetFileName(source)}. For HEIC and AVIF, get \"HEIF Image Extensions\" or \"AV1 Video Extension\" from the Microsoft Store, or install ffmpeg (Settings).");
            var temporary = TemporaryFile("png");
            try
            {
                RunFfmpeg(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-n", "-i", source, "-frames:v", "1", temporary]).GetAwaiter().GetResult();
                return ImageWork.Load(temporary).Picture;
            }
            finally
            {
                TryDelete(temporary);
            }
        }
    }

    async Task FfmpegJob(string source, FileKind kind, OutputFormat format, string output)
    {
        var ffmpeg = Ffmpeg ?? throw new ConversionException($"{format.Title()} needs ffmpeg: see Settings › ffmpeg.");
        await ffmpegJobs.WaitAsync();
        string? temporary = null;
        try
        {
            var input = source;
            if (kind == FileKind.Image)
            {
                // A still picture goes through Windows first (turned upright, read
                // the way Windows reads it); an animated one goes as it is, to stay animated.
                var still = await Sta.Run(() =>
                {
                    var (picture, frames) = TryLoad(source);
                    if (picture is null || frames > 1) return null;
                    var path = TemporaryFile("png");
                    var ready = format == OutputFormat.Avif ? ImageWork.Flatten(picture, System.Windows.Media.Colors.White) : picture;
                    ImageWork.Save(ready, OutputFormat.Png, path, 100);
                    return path;
                });
                if (still is not null) input = temporary = still;
            }
            await RunFfmpeg(ffmpeg, FfmpegArguments.For(format, kind, input, output, settings().Gif));
            if (!File.Exists(output)) throw new ConversionException("ffmpeg didn't write the file.");
        }
        finally
        {
            ffmpegJobs.Release();
            if (temporary is not null) TryDelete(temporary);
        }
    }

    static (BitmapSource? Picture, int Frames) TryLoad(string path)
    {
        try
        {
            return ImageWork.Load(path);
        }
        catch (Exception)
        {
            return (null, 0);
        }
    }

    static async Task RunFfmpeg(string ffmpeg, IReadOnlyList<string> arguments)
    {
        var start = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new ConversionException("ffmpeg didn't start.");
        var errors = process.StandardError.ReadToEndAsync();
        var output = process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        await output;
        if (process.ExitCode != 0) throw new ConversionException(FfmpegArguments.Reason(await errors));
    }

    /// <summary>ZIPs open here; 7Z, RAR, TAR and GZ with Windows' own tar (Windows 11 opens them all).</summary>
    static async Task<string?> Extract(string source, string folder)
    {
        if (Path.GetExtension(source).Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            var result = await Task.Run(() => ZipExtractor.Extract(source, folder));
            return result.Skipped.Count == 0 ? null
                : $"{result.Skipped.Count} item{(result.Skipped.Count == 1 ? "" : "s")} left out (a name outside the folder, or twice): {string.Join(", ", result.Skipped.Take(3))}";
        }
        Directory.CreateDirectory(folder);
        var tar = Path.Combine(Environment.SystemDirectory, "tar.exe");
        if (!File.Exists(tar)) throw new ConversionException("This Windows has no tar.exe to open it with.");
        var start = new ProcessStartInfo(tar) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "-xf", source, "-C", folder }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new ConversionException("tar didn't start.");
        var errors = process.StandardError.ReadToEndAsync();
        await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        if (process.ExitCode != 0)
        {
            var reason = (await errors).Trim();
            throw new ConversionException(string.IsNullOrEmpty(reason) ? "Windows couldn't open this archive." : reason);
        }
        return null;
    }

    static string TemporaryFile(string extension)
    {
        var folder = Path.Combine(Path.GetTempPath(), "Pinwheel");
        Directory.CreateDirectory(folder);
        return Path.Combine(folder, $"{Guid.NewGuid():N}.{extension}");
    }

    static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            else if (Directory.Exists(path) && !Directory.EnumerateFileSystemEntries(path).Any()) Directory.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    static string Reason(Exception exception) => exception switch
    {
        ConversionException => exception.Message,
        FileNotFoundException => "The file isn't there any more.",
        UnauthorizedAccessException => "Windows didn't let Pinwheel write in that folder.",
        IOException when exception.HResult == unchecked((int)0x80070070) => "The disk is full.",
        NotSupportedException or FileFormatException => "Windows can't read this picture.",
        _ => exception.Message,
    };
}

/// <summary>
/// Runs work on a thread of its own in a single-threaded apartment, which
/// Windows' imaging and drawing need.
/// </summary>
static class Sta
{
    public static Task Run(Action work) => Run<object?>(() =>
    {
        work();
        return null;
    });

    public static Task<T> Run<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                done.SetResult(work());
            }
            catch (Exception exception)
            {
                done.SetException(exception);
            }
        })
        { IsBackground = true, Name = "Pinwheel picture" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }
}
