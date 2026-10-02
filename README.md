# Pinwheel

Pinwheel is a small menu-bar app for your Mac that converts files with a
**drop wheel**. Start dragging files in Finder, hold **Shift**, and a wheel of
formats appears under your pointer. Drop the files on a format and Pinwheel
converts them. Everything happens on your Mac: nothing is uploaded.

- Hold **⇧ Shift** while dragging: the **format wheel** (PNG, JPEG, MP4, MP3…).
- Hold **⌥ Option + ⇧ Shift** while dragging: the **tools wheel** (Compress,
  Resize, Strip Info, Get Audio).
- Let go of Shift, or drop in the middle or outside the wheel: nothing happens.

What changed in each version is listed in [CHANGES.md](CHANGES.md).

The new file is saved **next to the original**. Pinwheel never overwrites
anything: you get `photo (converted).png`, then `photo (converted 2).png`, and
so on. The tools use their own names, like `photo (compressed).jpg` or
`video (audio).m4a`.

---

## What you need

- A Mac with **macOS 26 (Tahoe) or newer** (Pinwheel uses Liquid Glass).
- **Apple's Command Line Tools** (free, no Apple Developer account needed). To
  check, open Terminal and type `swift --version`. If macOS offers to install
  the tools, click **Install**.
- **Homebrew**, **ffmpeg** and **pngquant** (optional). Without ffmpeg,
  everything works except MP3, GIFs from videos, and MKV/WebM/AVI/OGG-type
  files. Without pngquant, Compress can hardly shrink PNGs. To install:
  1. Get Homebrew from <https://brew.sh> (copy the command on that page into Terminal).
  2. In Terminal, run: `brew install ffmpeg pngquant`

You do **not** need Xcode.

---

## Build and run

Open **Terminal** (Applications › Utilities › Terminal) and go to the project folder:

```sh
cd ~/Library/CloudStorage/OneDrive-Personal/Εκπαίδευση/Εργασία/converter
```

Then use one of these commands:

| Command | What it does |
|---|---|
| `make run` | Builds Pinwheel and starts it (quits the old copy first). |
| `make install` | Builds Pinwheel, copies it into **/Applications**, and starts it from there. |
| `make test` | Runs the automated tests (about 80 of them, including real conversions). |
| `make build` | Only builds. |
| `make clean` | Deletes all build files, so the next build starts fresh. |
| `make uninstall` | Quits Pinwheel and removes it from /Applications. |
| `make icon` | Redraws the app icon from `scripts/make-icon.swift`. |

The first build takes a minute or two; later builds are quicker.

**Where things go:** the source code stays in this folder (and in OneDrive).
The built app goes to `~/Library/Developer/Pinwheel/Pinwheel.app`, outside
OneDrive, because OneDrive adds hidden file attributes that break app signing.

Look for the Pinwheel icon (a small six-wedge wheel) in the menu bar. On a
MacBook with a notch, too many menu-bar icons can hide it behind the notch;
quit a few other menu-bar apps if you can't see it.

---

## Give Pinwheel the Accessibility permission

Pinwheel has to notice the Shift key and the mouse while you drag in Finder.
macOS only allows that with the **Accessibility** permission. Everything about
it lives at the top of **Settings**, in the **Permission** section. If the
permission is missing when Pinwheel starts, Settings opens by itself (and the
menu shows "⚠︎ Accessibility permission needed…", which opens it too).

1. Click **Open System Settings** in the Permission section.
2. In **Privacy & Security › Accessibility**, find **Pinwheel** and turn its
   switch **on**. macOS may ask for your password or Touch ID.
3. If Pinwheel isn't in the list, click **+**, choose Pinwheel (in
   Applications, or in `~/Library/Developer/Pinwheel/`), and click **Open**.
4. Go back to Settings. The section turns green by itself within a second.

**The switch is on, but the wheel doesn't appear?** That's an old entry from
an earlier build. Click **Reset Permission…** in the Permission section: it
removes the old entry and asks again. Then switch Pinwheel on once more.

---

## Keep the permission after every rebuild

Without a paid developer account, each build is normally signed "to run
locally". macOS treats every such build as a **different app**, so it forgets
the Accessibility permission. The fix is a free **self-signed certificate**
called `Pinwheel Local Signing`: the build script uses it automatically, and
macOS then recognizes every new build as the same app.

**On this Mac the certificate already exists** (it was created in your login
keychain in v0.4, valid until 2036). One step is left, and only you can do it,
because macOS asks *you* before codesign may use a new certificate:

1. Open **Terminal**, go to the project folder, and run `make install`.
2. A dialog asks whether **codesign** may use the key "Pinwheel Local
   Signing". Enter your **Mac login password** and click **Always Allow**.
3. The build should say `Signing with your certificate "Pinwheel Local Signing"`.
4. Give the permission **one last time**: open Settings › Permission and click
   **Reset Permission…** (or remove the old Pinwheel entries with **−** in
   System Settings), then switch Pinwheel on.

From now on, rebuilds keep the permission. If a build ever prints
`macOS didn't let codesign use "Pinwheel Local Signing" yet`, it still
works (signed the old way); just run `make install` in Terminal and click
**Always Allow** again.

### Making the certificate yourself (another Mac, or after deleting it)

1. Open **Keychain Access**. It's hidden on recent macOS, so press **⌘ Space**,
   type `Keychain Access`, and press Return. If that doesn't find it: in
   Finder choose **Go › Go to Folder…**, paste
   `/System/Library/CoreServices/Applications/` and double-click **Keychain Access**.
2. In the menu bar choose **Keychain Access › Certificate Assistant › Create a Certificate…**
3. Fill in exactly:
   - **Name:** `Pinwheel Local Signing` (spelled exactly like this)
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create**. If a warning says the certificate is self-signed, click
   **Continue**. Then click **Done**, and follow the four steps above.

You can see the certificate in Keychain Access under **login › My
Certificates**. It's normal that it says "not trusted": that only matters for
apps you give to other people.

---

## Put Pinwheel in your Applications folder

Run:

```sh
make install
```

This copies Pinwheel to **/Applications** and starts it. Once it's there,
you can also open it from Launchpad or Spotlight like any other app. Run
`make install` again whenever you want the newest build.

**Launch at login:** menu-bar icon › **Launch at Login** (or Settings ›
System). This works best when Pinwheel is in /Applications. If macOS asks,
allow Pinwheel in **System Settings › General › Login Items & Extensions**.

---

## What converts to what

| You drag… | ⇧ Shift wheel | ⌥⇧ Option + Shift wheel |
|---|---|---|
| **Images** (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP, camera RAW…) | PNG, JPEG, HEIC, TIFF, GIF, PDF | Compress, Resize, Strip Info |
| **Videos** (MOV, MP4, M4V; MKV, WebM, AVI with ffmpeg) | MP4, MOV, GIF\*, M4A, MP3\* | Compress, Strip Info, Get Audio |
| **Audio** (MP3, M4A, WAV, AIFF, FLAC, OGG…) | MP3\*, M4A, WAV, AIFF, FLAC | Compress, Strip Info (MP3/FLAC need ffmpeg) |
| **PDFs** | PNG, JPEG, HEIC, TIFF (one image per page), Smaller PDF | Compress, Strip Info |

\* needs ffmpeg. Without it, these wedges are grayed out and say why.

- **Mixed files** (e.g. a photo and a video) show only the formats that work
  for all of them. Here that's GIF.
- A file's own format is left out (a PNG doesn't get a PNG wedge).
- **PDF → images:** a one-page PDF becomes one image; a longer PDF becomes a
  folder, `report (converted)`, with `report page 01.png`, `report page 02.png`…
- **Several images → PDF:** they become **one** PDF with a page per image, in
  name order: `photo1 (combined).pdf`. (Settings can switch this off.)
- **Compress** keeps the format: JPEG and HEIC get a lower quality setting,
  PNGs stay PNG and are shrunk by pngquant, and big formats (TIFF, BMP, RAW)
  become HEIC. Videos become HEVC MP4 at the quality and size you choose
  (the original size is kept by default), audio becomes AAC (.m4a), and PDFs
  get their pictures shrunk while text stays sharp. **If the result isn't
  clearly smaller, nothing is saved** and the progress window says so.
- **Resize:** 25%, 50% or 75%, or "fit within" 1280/1920/2560/3840 pixels
  (Settings › Images). The picture is turned the right way up. An image
  that's already small enough is left alone.
- **GIFs from videos** use only the first 15 seconds by default (Settings ›
  Video and audio), because GIFs get very big very fast.
- **Strip Info:** removes location, camera model, dates, titles and authors.
  For photos in the same format, the picture itself isn't re-compressed.
- **Get Audio:** saves a video's sound as M4A.

The **progress window** (top right) shows each file, with ✕ to cancel and 🔍 to
show the result in Finder, the size before and after (for example
`2.4 MB → 1.1 MB (−54%)`), and anything worth knowing (skipped and why, saved
in Downloads, original in Trash). It closes itself a few seconds after
everything succeeds; if something fails, it stays open with the reason. For
conversions that take 10 seconds or more you also get a **notification**
(click it to see the files).

**Where files are saved:** next to the original by default, or in Downloads,
or in a folder you choose (Settings › Saving). If that place can't be written
to, for example a disk image or a read-only shared drive, the file goes to
**Downloads** instead and the progress window tells you.

---

## Settings

Menu-bar icon › **Settings…** (or ⌘, while the menu is open):

- **Permission:** whether Accessibility is on, what to do if it isn't, and
  **Reset Permission…** for stale entries. It updates by itself.
- **Appearance › Glass (5 steps):** 1 Frosted (the classic blur, not glass) ·
  2 Tinted Glass · 3 Liquid Glass · 4 Clear Glass (with a light shade) ·
  5 Crystal (fully clear). The whole wheel is one piece of glass, with the
  icons and thin dividers inside it; only the chosen wedge is colored. The
  preview updates as you move the slider, and **Show on Desktop** shows the
  real wheel over your desktop for 3 seconds.
- **Wheel feedback:** a click sound when the pointer moves onto a format
  (Tink, Pop, Bottle, Morse, Purr or Frog; volume; Test), and a trackpad
  vibration (Force Touch trackpads, felt only while your finger is on it).
- **After converting:** progress window; show new files in Finder; notify
  when a long conversion finishes; **move the original to the Trash** (off by
  default; only after the new file is saved).
- **Saving:** next to the original, in Downloads, or in a folder you choose.
- **Images and PDFs:** JPEG, HEIC and Compress quality; Resize size; combine
  several images into one PDF; PDF page resolution.
- **Video and audio:** video Compress quality (Smallest file / Balanced /
  Best quality) and size limit (keep, 4K, 1080p, 720p); audio Compress bit
  rate; GIF width, frame rate and length.
- **System:** launch at login; how many files to convert at the same time;
  where ffmpeg is (or a custom location); whether pngquant is installed.
- **Reset to Defaults.**

---

## Troubleshooting

**The wheel doesn't appear.**
Open Settings and look at the Permission section at the top. If it's orange,
follow its steps. If the switch in System Settings is already on but the
section stays orange, the entry belongs to an older build: click **Reset
Permission…** and switch Pinwheel on again. The certificate section above
stops this from happening.

**Compress says "Already as small as it gets".**
That's on purpose: the compressed version wasn't clearly smaller, so the
original is the better file and nothing was saved. For PNGs, make sure
pngquant is installed (Settings › System shows it).

**A file was saved in Downloads instead of next to the original.**
The original's folder can't be written to (a disk image, a read-only shared
drive, some cloud folders). The progress window says so; you can also pick
a fixed folder in Settings › Saving.

**No click sound.**
Check Settings › Wheel feedback (Click sound on, volume up) and your Mac's
sound volume. The sound plays only on formats you can use, not on gray ones.

**The wheel appears but a format is gray.**
Hover it: the middle of the wheel says why (usually "Needs ffmpeg").

**"ffmpeg not found" in the menu.**
Install it with `brew install ffmpeg`. Pinwheel finds it straight away; no
restart needed. If you installed it somewhere unusual, set the path in
Settings › System.

**`make test` says "plugin for module 'TestingMacros' not found".**
Run `make clean` and then `make test` again.

**Launch at Login doesn't stick.**
Install into /Applications with `make install`, then turn it on again.

**I want to start completely fresh.**
`make uninstall`, `make clean`, remove Pinwheel from the Accessibility list,
then `make install`.

---

## Uninstall

```sh
make uninstall
make clean
```

Then remove Pinwheel from **System Settings › Privacy & Security ›
Accessibility** and from **Login Items**. Its settings are stored in
`~/Library/Preferences/com.iliasmac.Pinwheel.plist` (safe to delete).

---

## For the curious: how it's built

- **Swift Package Manager** instead of Xcode: `Package.swift` describes the
  app, and `scripts/build-app.sh` turns the compiled program into
  `Pinwheel.app` (Info.plist, icon, signing). Swift 6 language mode, so the
  compiler checks for threading mistakes.
- `Sources/PinwheelCore`: the conversion engine. Each job is planned once
  (`OutputPlanner`: format, name, folder), then run by the right converter,
  then checked (Compress must really shrink the file). No user interface.
- `Sources/PinwheelUI`: the menu-bar app (AppKit + SwiftUI, `@Observable`
  models, main thread by default): drag detection, the wheel window, the job
  queue, the progress window, Settings, notifications.
- `Sources/Pinwheel`: just the few lines that start the app.
- `Tests/PinwheelCoreTests`: tests that make real images, videos, songs and
  PDFs, convert them, and check the results. `Tests/PinwheelUITests`: the job
  queue, settings, the wheel's labels, and that every glass level draws.
- Apple frameworks do the work: ImageIO (images), AVFoundation and Core Audio
  (video, audio, FLAC), PDFKit with a Quartz filter (PDFs). ffmpeg is used
  only for MP3, GIFs from video, and files macOS can't open; pngquant only
  for PNG compression. If macOS fails on a file, ffmpeg gets a second try.
- In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin only comes
  with Xcode, so view state lives in small `@Observable` objects passed in.
- Build warnings about `search path '/Library/Developer/CommandLineTools/Developer/…' not found`
  come from Swift Package Manager itself when Xcode isn't installed. They're
  harmless, and the scripts hide exactly that line.
