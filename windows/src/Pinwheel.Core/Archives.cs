using System.IO.Compression;

namespace Pinwheel.Core;

/// <summary>Opens ZIPs safely: a name that would land outside the folder is skipped, the rest opens.</summary>
public static class ZipExtractor
{
    public sealed record Result(int Files, IReadOnlyList<string> Skipped);

    public static Result Extract(string zipPath, string destination)
    {
        Directory.CreateDirectory(destination);
        var root = Path.GetFullPath(destination);
        if (!root.EndsWith(Path.DirectorySeparatorChar)) root += Path.DirectorySeparatorChar;
        var skipped = new List<string>();
        var files = 0;
        using var archive = ZipFile.OpenRead(zipPath);
        foreach (var entry in archive.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            var target = Path.GetFullPath(Path.Combine(root, name));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                skipped.Add(entry.FullName);
                continue;
            }
            if (name.EndsWith('/') || entry.Name.Length == 0)
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (File.Exists(target))
            {
                skipped.Add(entry.FullName);  // the same name twice in one ZIP: the first stays
                continue;
            }
            entry.ExtractToFile(target, overwrite: false);
            files++;
        }
        return new Result(files, skipped);
    }
}
