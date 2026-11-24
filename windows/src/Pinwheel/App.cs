using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using Pinwheel.Core;

namespace Pinwheel;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // pinwheel convert <format> <files…>: converts and quits, without the tray (for scripts and tests).
        if (args.Length > 0 && args[0].Equals("convert", StringComparison.OrdinalIgnoreCase))
            return CommandLine.Convert(args[1..]);

        using var instance = SingleInstance.Claim(args);
        if (instance is null) return 0;  // the running Pinwheel has the files now
        var app = new App(instance, args);
        return app.Run();
    }
}

/// <summary>Pinwheel: the tray icon, the wheel, and Settings.</summary>
sealed class App : Application
{
    public const string Website = "https://github.com/IliasPa/Pinwheel_file_converter";
    public static string Version => typeof(App).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}" : "0.1";

    readonly SingleInstance instance;
    readonly string[] startFiles;
    readonly string settingsPath = PinwheelSettings.DefaultPath;
    Converter converter = null!;
    Tray tray = null!;
    DragWatcher watcher = null!;
    WheelWindow wheel = null!;
    SettingsWindow? settingsWindow;

    public PinwheelSettings Settings { get; private set; } = new();

    public App(SingleInstance instance, string[] startFiles)
    {
        this.instance = instance;
        this.startFiles = startFiles;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Settings = PinwheelSettings.Load(settingsPath);
        converter = new Converter(() => Settings);
        wheel = new WheelWindow(() => converter.Ffmpeg, (files, format) => _ = Convert(files, format));
        tray = new Tray(this);

        watcher = new DragWatcher();
        watcher.ShiftDrag += () => { if (Settings.WheelOnShiftDrag) wheel.ShowForDrag(); };
        watcher.Released += wheel.MouseReleased;
        watcher.Start();

        instance.FilesReceived += files => Dispatcher.BeginInvoke(() => OpenWith(files));
        instance.Listen();

        if (startFiles.Length > 0) OpenWith(startFiles);
        else if (!Settings.WelcomeShown) ShowSettings(welcome: true);
    }

    /// <summary>Files from Send to (or a second start): the wheel opens at the pointer.</summary>
    public void OpenWith(IReadOnlyList<string> files)
    {
        var existing = files.Where(path => File.Exists(path) || Directory.Exists(path)).ToList();
        if (existing.Count > 0) wheel.ShowForClick(existing);
    }

    public void ChooseFiles()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Choose files to convert" };
        if (dialog.ShowDialog() == true) wheel.ShowForClick(dialog.FileNames, atPointer: false);
    }

    public void ShowSettings(bool welcome = false)
    {
        if (settingsWindow is { IsLoaded: true })
        {
            settingsWindow.Activate();
            return;
        }
        settingsWindow = new SettingsWindow(this, welcome);
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show();
        settingsWindow.Activate();
        if (welcome)
        {
            Settings.WelcomeShown = true;
            SaveSettings();
        }
    }

    public void SaveSettings()
    {
        try
        {
            Settings.Save(settingsPath);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            tray.Notify("Settings weren't saved", exception.Message);
        }
    }

    public string? Ffmpeg => converter.Ffmpeg;

    async Task Convert(IReadOnlyList<string> files, OutputFormat format)
    {
        var results = await converter.ConvertAsync(files, format);
        var done = results.Where(result => result.Succeeded).ToList();
        var failed = results.Where(result => !result.Succeeded).ToList();
        var outputs = done.Select(result => result.Output!).Distinct().ToList();
        var notes = done.Select(result => result.Note).Where(note => note is not null).Distinct().ToList();
        if (failed.Count == 0)
        {
            var title = outputs.Count == 1 ? $"Made {Path.GetFileName(outputs[0])}" : $"Made {outputs.Count} files";
            tray.Notify(title, notes.Count > 0 ? string.Join(" ", notes) : "Click to see it in Explorer.", outputs.FirstOrDefault());
        }
        else
        {
            var first = failed[0];
            var title = done.Count == 0
                ? (failed.Count == 1 ? $"{Path.GetFileName(first.Source)} wasn't converted" : $"{failed.Count} files weren't converted")
                : $"{done.Count} converted, {failed.Count} not";
            tray.Notify(title, first.Problem ?? "Something went wrong.", outputs.FirstOrDefault());
        }
    }

    public void Quit()
    {
        watcher.Dispose();
        tray.Dispose();
        wheel.AllowClose = true;
        wheel.Close();
        Shutdown();
    }
}
