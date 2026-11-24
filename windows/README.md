# Pinwheel for Windows (beta)

**Convert files on Windows with a drop wheel.** Start dragging files in
File Explorer, hold **Shift**, and a wheel of formats appears under the
pointer. Drop the files on one and the new files appear beside the
originals, which stay as they are. Free, open source, and everything
happens on your PC: nothing is uploaded.

This is a first version. The Mac app ([the main README](../README.md)) does
much more; Windows has the drop wheel and these conversions so far.

## What it does

- **Pictures** (JPEG, PNG, BMP, GIF, TIFF, ICO, WebP, HEIC, AVIF, JPEG XR)
  → PNG, JPEG, GIF (the 256 colors that suit the picture), TIFF, BMP, ICO
  (every size from 16 to 256 pixels), and **PDF** (several pictures make one
  PDF, a page each). With ffmpeg, also **WebP** and **AVIF**. Phone photos
  come out upright. JPEG and BMP get white where the picture was
  see-through.
- **Videos** (MP4, MOV, MKV, WebM, AVI, WMV, MTS, FLV…) → MP4, MKV, WebM,
  MOV, AVI, WMV, an animated **GIF** of the clip, or just the sound as MP3
  or M4A. Needs ffmpeg.
- **Sound** (MP3, M4A, WAV, FLAC, OGG, Opus, WMA, AIFF…) → MP3, M4A, WAV,
  FLAC, OGG, Opus, WMA. A song's cover comes along into MP3, M4A and FLAC.
  Needs ffmpeg.
- **Archives** (ZIP, 7Z, RAR, TAR, GZ) → **Extract** into a folder beside
  them. 7Z and RAR need Windows 11.
- New files are named like `photo (converted).png` and never replace
  anything.

Other ways to open the wheel: right-click files › **Send to › Pinwheel**
(switch it on in Settings), or the tray icon › **Convert Files…**. Then click
a format.

## Install

1. Download **Pinwheel-Windows-x64.zip** (or **-Arm64** for Arm PCs such as
   Snapdragon laptops) from the release, and unzip it.
2. Put **Pinwheel.exe** where it can stay, for example in a `Pinwheel`
   folder in your user folder, and double-click it.
3. Windows may say *"Windows protected your PC"*, because Pinwheel isn't
   signed (that needs a paid certificate). Click **More info › Run anyway**.
   You only do this once.
4. Pinwheel opens its Settings to say hello, and then lives in the tray by
   the clock (click **^** if you don't see its icon).

**Optional:** for video, sound, WebP and AVIF, install the free
[ffmpeg](https://ffmpeg.org). Open Terminal and run
`winget install Gyan.FFmpeg`. Pinwheel finds it straight away.

Needs Windows 10 (version 2004 or newer) or Windows 11.

## Build it yourself

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download).

```powershell
dotnet test windows/tests/Pinwheel.Core.Tests
dotnet test windows/tests/Pinwheel.Tests
dotnet publish windows/src/Pinwheel/Pinwheel.csproj -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o out
```

`Pinwheel.exe convert <format> <files…>` converts from the command line
(for scripts), for example `Pinwheel.exe convert jpg photo.png`.

| Folder | What's in it |
|---|---|
| `src/Pinwheel.Core` | What isn't tied to Windows: formats, names, the wheel's shape, ffmpeg's settings, the PDF, icon and ZIP code |
| `src/Pinwheel` | The app: tray icon, the wheel, noticing Shift while you drag, Settings, and pictures with Windows' own imaging |
| `tests/` | Tests for both; GitHub's Windows machines run them on every change (`.github/workflows/windows.yml`) |
