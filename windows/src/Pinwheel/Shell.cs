using System;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

namespace Pinwheel;

/// <summary>Pinwheel's places in Windows: Send to, starting at sign-in, and showing files in Explorer.</summary>
static class Shell
{
    static string Executable => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Pinwheel.exe");

    static string SendToShortcut =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Pinwheel.lnk");

    /// <summary>Right-click files › Send to › Pinwheel.</summary>
    public static bool IsInSendTo => File.Exists(SendToShortcut);

    public static void SetSendTo(bool on)
    {
        if (!on)
        {
            if (File.Exists(SendToShortcut)) File.Delete(SendToShortcut);
            return;
        }
        // Windows Script Host makes shortcuts; it's on every Windows.
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows Script Host isn't available.");
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic link = shell.CreateShortcut(SendToShortcut);
            link.TargetPath = Executable;
            link.WorkingDirectory = Path.GetDirectoryName(Executable);
            link.Description = "Convert with Pinwheel";
            link.IconLocation = Executable + ",0";
            link.Save();
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);
        }
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>Pinwheel starts when you sign in.</summary>
    public static bool StartsAtSignIn
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Pinwheel") is string value && value.Contains(Executable, StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void SetStartsAtSignIn(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) key.SetValue("Pinwheel", $"\"{Executable}\"");
        else key.DeleteValue("Pinwheel", throwOnMissingValue: false);
    }

    /// <summary>Opens Explorer with the file (or folder) selected.</summary>
    public static void ShowInExplorer(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = false });
        }
        catch (Exception)
        {
        }
    }

    public static void OpenLink(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception)
        {
        }
    }
}
