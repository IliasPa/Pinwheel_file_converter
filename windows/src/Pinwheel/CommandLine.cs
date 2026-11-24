using System;
using System.Linq;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>
/// Pinwheel.exe convert &lt;format&gt; &lt;files…&gt;: converts without the
/// tray or the wheel, prints what it made, and quits (1 if anything failed).
/// </summary>
static class CommandLine
{
    public static int Convert(string[] args)
    {
        Native.AttachConsole(-1);  // print into the window it was started from
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: Pinwheel.exe convert <format> <files…>");
            Console.Error.WriteLine("Formats: " + string.Join(", ", Enum.GetValues<OutputFormat>().Select(f => f.Title().ToLowerInvariant())));
            return 2;
        }
        var name = args[0].TrimStart('.');
        var matches = Enum.GetValues<OutputFormat>().Where(f =>
            f.Title().Equals(name, StringComparison.OrdinalIgnoreCase) || (f.Extension() ?? "").Equals(name, StringComparison.OrdinalIgnoreCase)).ToList();
        if (matches.Count == 0)
        {
            Console.Error.WriteLine($"Pinwheel doesn't know the format \"{args[0]}\".");
            return 2;
        }
        var format = matches[0];
        var settings = PinwheelSettings.Load(PinwheelSettings.DefaultPath);
        var converter = new Converter(() => settings);
        var results = converter.ConvertAsync(args[1..], format).GetAwaiter().GetResult();
        foreach (var result in results)
        {
            if (result.Succeeded) Console.WriteLine(result.Output);
            else Console.Error.WriteLine($"{result.Source}: {result.Problem}");
            if (result.Note is not null) Console.WriteLine("  " + result.Note);
        }
        return results.All(result => result.Succeeded) ? 0 : 1;
    }
}
