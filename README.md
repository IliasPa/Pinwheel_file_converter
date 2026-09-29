# Pinwheel

Pinwheel is a small menu-bar app for your Mac that converts files with a
**drop wheel**. Start dragging files in Finder, hold **Shift**, and a wheel of
formats appears under your pointer. Drop the files on a format and Pinwheel
converts them. Everything happens on your Mac: nothing is uploaded.

- Hold **⇧ Shift** while dragging: the **format wheel** (PNG, JPEG, MP4, MP3…).
- Hold **⌥ Option + ⇧ Shift** while dragging: the **tools wheel** (Compress,
  Resize 50%, Strip Info, Get Audio).
- Let go of Shift, or drop in the middle or outside the wheel: nothing happens.

The new file is saved **next to the original**. Pinwheel never overwrites
anything: you get `photo (converted).png`, then `photo (converted 2).png`, and
so on. The tools use their own names, like `photo (compressed).jpg` or
`video (audio).m4a`.

---

## What you need

- A Mac with **macOS 14 (Sonoma) or newer**. Liquid Glass needs macOS 26 or newer.
- **Apple's Command Line Tools** (free, no Apple Developer account needed). To
  check, open Terminal and type `swift --version`. If macOS offers to install
  the tools, click **Install**.
- **Homebrew** and **ffmpeg** (optional). Without ffmpeg, everything works except
  MP3, GIFs from videos, and MKV/WebM/AVI/OGG-type files. To install:
  1. Get Homebrew from <https://brew.sh> (copy the command on that page into Terminal).
  2. In Terminal, run: `brew install ffmpeg`

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
| `make test` | Runs the automated tests (about 60 of them, including real conversions). |
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
macOS only allows that with the **Accessibility** permission. The first time
Pinwheel starts, a welcome window walks you through it:

1. Click **Open System Settings** in the welcome window.
2. In **Privacy & Security › Accessibility**, find **Pinwheel** and turn its
   switch **on**. macOS may ask for your password or Touch ID.
3. If Pinwheel isn't in the list, click **+**, choose Pinwheel (in
   Applications, or in `~/Library/Developer/Pinwheel/`), and click **Open**.
4. Go back to the welcome window. It turns green when everything is ready.

You can open this window again at any time: menu-bar icon › **Permissions Help…**

---

## Keep the permission after every rebuild (do this once)

Without a paid developer account, each build is signed "to run locally". macOS
treats every new build as a **different app**, so it forgets the Accessibility
permission. The switch may still look **on**, but the wheel stops appearing.

The fix is a free **self-signed certificate**. Pinwheel's build script uses it
automatically when it exists, and macOS then recognizes every new build as
the same app.

### Create the certificate (about 5 minutes)

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
   **Continue**. Then click **Done**.
5. Close Keychain Access.

### Use it

1. In Terminal, run `make install`. The build should say
   `Signing with your certificate "Pinwheel Local Signing"`.
2. macOS may ask whether **codesign** can use the key in your keychain. Enter
   your Mac login password and click **Always Allow**.
3. Give the permission **one last time**. In **System Settings › Privacy &
   Security › Accessibility**, select every old **Pinwheel** entry and click
   **−**, then add Pinwheel again (the welcome window's button does this for
   you) and switch it on.

From now on, rebuilds keep the permission. (If you ever delete or recreate
the certificate, repeat step 3.)

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
| **Images** (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP, camera RAW…) | PNG, JPEG, HEIC, TIFF, GIF, PDF | Compress, Resize 50%, Strip Info |
| **Videos** (MOV, MP4, M4V; MKV, WebM, AVI with ffmpeg) | MP4, MOV, GIF\*, M4A, MP3\* | Compress, Strip Info, Get Audio |
| **Audio** (MP3, M4A, WAV, AIFF, FLAC, OGG…) | MP3\*, M4A, WAV, AIFF, FLAC | Compress, Strip Info (MP3/FLAC need ffmpeg) |
| **PDFs** | PNG, JPEG, HEIC, TIFF (one image per page), Smaller PDF | Compress, Strip Info |

\* needs ffmpeg. Without it, these wedges are grayed out and say why.

- **Mixed files** (e.g. a photo and a video) show only the formats that work
  for all of them. Here that's GIF.
- A file's own format is left out (a PNG doesn't get a PNG wedge).
- **PDF → images:** a one-page PDF becomes one image; a longer PDF becomes a
  folder, `report (converted)`, with `report page 01.png`, `report page 02.png`…
- **Compress:** photos get a lower quality setting (a transparent PNG becomes
  HEIC, an opaque one JPEG). Videos become HEVC MP4, audio becomes 128 kbps
  AAC (.m4a), and PDFs get their pictures shrunk. Text in PDFs stays sharp.
- **Resize 50%:** half the width and height, turned the right way up.
- **Strip Info:** removes location, camera model, dates, titles and authors.
  For photos in the same format, the picture itself isn't re-compressed.
- **Get Audio:** saves a video's sound as M4A.

The **progress window** (top right) shows each file, with ✕ to cancel and 🔍 to
show the result in Finder. It closes itself a few seconds after everything
succeeds. If something fails, it stays open with the reason.

---

## Settings

Menu-bar icon › **Settings…** (or ⌘, while the menu is open):

- **Glass (5 steps):** 1 Frosted · 2 Soft Glass · 3 Liquid Glass · 4 Clear
  Glass · 5 Crystal. The preview updates as you move the slider, and
  **Show on Desktop** shows the real wheel over your desktop for 3 seconds.
  Liquid Glass needs macOS 26+; older systems always use Frosted.
- **Trackpad tick:** a gentle haptic tick when you move onto a wedge.
- **After converting:** show the progress window; show new files in Finder.
- **Quality:** JPEG, HEIC and Compress quality; PDF page resolution; GIF size
  and frame rate.
- **System:** launch at login, Accessibility status, where ffmpeg is (or a
  custom location).
- **Reset to Defaults.**

---

## Troubleshooting

**The wheel doesn't appear.**
Check the menu-bar icon: if it shows "⚠︎ Accessibility permission needed",
follow that. If the switch in System Settings is already on, the permission
belongs to an older build: remove Pinwheel with **−** and add it again. The
certificate section above stops this from happening.

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
  `Pinwheel.app` (Info.plist, icon, signing).
- `Sources/PinwheelCore`: the conversion engine, format rules, file naming
  and wheel math. It has no user interface, so it can be tested.
- `Sources/Pinwheel`: the menu-bar app (AppKit + SwiftUI): drag detection,
  the wheel window, the progress window, Settings.
- `Tests/PinwheelCoreTests`: tests that make real images, videos, songs and
  PDFs, convert them, and check the results.
- Apple frameworks do the work: ImageIO (images), AVFoundation and Core Audio
  (video, audio, FLAC), PDFKit with a Quartz filter (PDFs). ffmpeg is used
  only for MP3, GIFs from video, and files macOS can't open. If macOS fails on
  a file, ffmpeg gets a second try.
- Build warnings about `search path '/Library/Developer/CommandLineTools/Developer/…' not found`
  come from Swift Package Manager itself when Xcode isn't installed. They're
  harmless, and the scripts hide exactly that line.
