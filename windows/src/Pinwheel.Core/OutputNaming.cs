namespace Pinwheel.Core;

/// <summary>
/// Picks names that never overwrite anything, beside the original:
/// "photo (converted).png", then "photo (converted 2).png" and so on.
/// Names handed out but not written yet are remembered, so two jobs running
/// at the same time can't pick the same one.
/// </summary>
public sealed class OutputNaming
{
    public static OutputNaming Shared { get; } = new();

    readonly object gate = new();
    // Windows disks ignore case: "Photo.png" and "photo.png" are one file.
    readonly HashSet<string> reserved = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether something is there already (tests give their own).</summary>
    public Func<string, bool> Exists { get; init; } = path => File.Exists(path) || Directory.Exists(path);

    /// <summary><paramref name="extension"/> null means a folder.</summary>
    public string Reserve(string folder, string baseName, string suffix, string? extension)
    {
        lock (gate)
        {
            for (var attempt = 1; ; attempt++)
            {
                var path = Candidate(folder, baseName, suffix, extension, attempt);
                if (!reserved.Contains(path) && !Exists(path))
                {
                    reserved.Add(path);
                    return path;
                }
            }
        }
    }

    /// <summary>Call once the file is written (or the job failed).</summary>
    public void Release(string path)
    {
        lock (gate) reserved.Remove(path);
    }

    public static string Candidate(string folder, string baseName, string suffix, string? extension, int attempt)
    {
        var label = attempt == 1 ? suffix : $"{suffix} {attempt}";
        var name = $"{baseName} ({label})";
        if (extension is not null) name += "." + extension;
        return Path.Combine(folder, name);
    }
}
