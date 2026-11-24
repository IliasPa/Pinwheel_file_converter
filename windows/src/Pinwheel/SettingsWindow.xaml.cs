using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>Settings: the wheel, pictures, GIFs from videos, and ffmpeg.</summary>
partial class SettingsWindow : Window
{
    readonly App app;

    internal SettingsWindow(App app, bool welcome)
    {
        this.app = app;
        InitializeComponent();
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Pinwheel.ico"))
        {
            if (stream is not null) Icon = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        }
        Welcome.Visibility = welcome ? Visibility.Visible : Visibility.Collapsed;
        VersionText.Text = $"Pinwheel for Windows {App.Version} (beta)";
        Fill(app.Settings);
        Wire(app.Settings);
    }

    void Fill(PinwheelSettings settings)
    {
        ShiftDrag.IsChecked = settings.WheelOnShiftDrag;
        SendTo.IsChecked = Shell.IsInSendTo;
        SignIn.IsChecked = Shell.StartsAtSignIn;
        Quality.Value = settings.JpegQuality;
        QualityValue.Text = settings.JpegQuality.ToString();
        Choices(GifWidth, [320, 480, 640, 800, 1080], settings.GifWidth, value => $"{value} pixels");
        Choices(GifFps, [8, 10, 12, 15, 20, 24, 30], settings.GifFramesPerSecond, value => value.ToString());
        Choices(GifSeconds, [5, 10, 15, 30, 60], settings.GifMaxSeconds, value => $"{value} seconds");
        FfmpegPath.Text = settings.FfmpegPath;
        ShowFfmpeg();
    }

    static void Choices(ComboBox box, int[] values, int current, Func<int, string> title)
    {
        var all = values.Contains(current) ? values : values.Append(current).Order().ToArray();
        box.ItemsSource = all.Select(value => new KeyValuePair<int, string>(value, title(value))).ToList();
        box.DisplayMemberPath = "Value";
        box.SelectedValuePath = "Key";
        box.SelectedValue = current;
    }

    void Wire(PinwheelSettings settings)
    {
        ShiftDrag.Click += (_, _) => Save(() => settings.WheelOnShiftDrag = ShiftDrag.IsChecked == true);
        SendTo.Click += (_, _) => Try(() => Shell.SetSendTo(SendTo.IsChecked == true), () => SendTo.IsChecked = Shell.IsInSendTo);
        SignIn.Click += (_, _) => Try(() => Shell.SetStartsAtSignIn(SignIn.IsChecked == true), () => SignIn.IsChecked = Shell.StartsAtSignIn);
        Quality.ValueChanged += (_, _) =>
        {
            QualityValue.Text = ((int)Quality.Value).ToString();
            Save(() => settings.JpegQuality = (int)Quality.Value);
        };
        GifWidth.SelectionChanged += (_, _) => { if (GifWidth.SelectedValue is int value) Save(() => settings.GifWidth = value); };
        GifFps.SelectionChanged += (_, _) => { if (GifFps.SelectedValue is int value) Save(() => settings.GifFramesPerSecond = value); };
        GifSeconds.SelectionChanged += (_, _) => { if (GifSeconds.SelectedValue is int value) Save(() => settings.GifMaxSeconds = value); };
        FfmpegPath.LostFocus += (_, _) =>
        {
            Save(() => settings.FfmpegPath = FfmpegPath.Text.Trim().Trim('"'));
            ShowFfmpeg();
        };
        ChooseFfmpeg.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Choose ffmpeg.exe", Filter = "ffmpeg|ffmpeg.exe|Programs|*.exe" };
            if (dialog.ShowDialog(this) != true) return;
            FfmpegPath.Text = dialog.FileName;
            Save(() => settings.FfmpegPath = dialog.FileName);
            ShowFfmpeg();
        };
        CopyCommand.Click += (_, _) => Try(() => Clipboard.SetText(InstallCommand.Text), null);
        GitHubLink.Click += (_, _) => Shell.OpenLink(App.Website);
        Activated += (_, _) => ShowFfmpeg();  // installed meanwhile? say so
    }

    void Save(Action change)
    {
        change();
        app.SaveSettings();
    }

    void Try(Action action, Action? undo)
    {
        try
        {
            action();
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Pinwheel", MessageBoxButton.OK, MessageBoxImage.Warning);
            undo?.Invoke();
        }
    }

    void ShowFfmpeg()
    {
        var found = app.Ffmpeg;
        FfmpegStatus.Text = found is not null
            ? $"Found: {found}. MP4, MKV, WebM, AVI, MOV, WMV, GIFs from videos, MP3, M4A, WAV, FLAC, OGG, Opus, WMA, WebP and AVIF are on the wheel."
            : "Not installed: the wedges for video, sound, WebP and AVIF are grayed out. Everything else works.";
        FfmpegInstall.Visibility = found is null ? Visibility.Visible : Visibility.Collapsed;
        if (!string.IsNullOrWhiteSpace(app.Settings.FfmpegPath) && !File.Exists(app.Settings.FfmpegPath.Trim().Trim('"')))
            FfmpegStatus.Text = $"There's no ffmpeg at {app.Settings.FfmpegPath}. " + FfmpegStatus.Text;
    }
}
