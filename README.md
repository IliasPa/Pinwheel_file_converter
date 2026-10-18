# Pinwheel

Pinwheel is a small menu-bar app for your Mac that converts files with a
**drop wheel**. Start dragging files in Finder, hold **Shift**, and a wheel of
formats appears under your pointer. Drop the files on a format and Pinwheel
converts them. Everything happens on your Mac: nothing is uploaded.

- Hold **⇧ Shift** while dragging: the **format wheel** (PNG, JPEG, MP4, MP3…).
- Hold **⌥ Option + ⇧ Shift** while dragging: the **tools wheel** (Compress,
  Resize, Remove BG, Crop…, Edit…, Watermark…, Info…, Organize…, Normalize
  and more). Tools ending in "…" open a window where you choose the details
  first, like the crop's shape and size.
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
| `make test` | Runs the automated tests (about 185 of them, including real conversions). |
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
| **Images** (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP, camera RAW…) | PNG, JPEG, HEIC, TIFF, GIF, PDF; **Collage…** (two or more) | Compress, Resize, Remove BG, Crop…, Edit…, Add BG…, Markup…, Watermark…, Info… (also Strip Info, Get Text: see Settings › Tools wheel) |
| **Videos** (MOV, MP4, M4V; MKV, WebM, AVI with ffmpeg) | MP4, MOV, GIF\*, M4A, MP3\* | Compress, Strip Info, Get Audio, Mute, Edit… (trim, speed, turn, sound, GIF), Info… |
| **Audio** (MP3, M4A, WAV, AIFF, FLAC, OGG…) | MP3\*, M4A, WAV, AIFF, FLAC | Compress, Strip Info, Normalize, Edit… (trim, speed, fades, loudness), Info… (MP3/FLAC Strip Info and saving info need ffmpeg) |
| **PDFs** | PNG, JPEG, HEIC, TIFF (one image per page), Smaller PDF | Compress, Strip Info, Merge, Split Pages, Organize…, Get Text, Password…, Info… |

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
- **Remove BG:** keeps the subject (people, pets, objects) on a see-through
  PNG, `photo (no background).png`. Uses the same on-device model as
  Photos' "Lift subject". Logos, icons and drawings without a subject lose
  their plain background color instead (holes in letters too). If there's
  neither, nothing is saved and a notification says why.
- **Normalize** (audio): evens out the loudness to −16 LUFS, the level
  podcasts and Apple Music use, without letting peaks clip:
  `song (normalized).mp3`. A file that's already there is left alone.
- **Mute:** the same video without its sound, `clip (muted).mov`.
- **Merge** (two or more PDFs): one PDF with all their pages, in name order,
  `a (merged).pdf`. **Split Pages:** a folder with one PDF per page.
- **Get Text:** all the text as a `.txt` file. In PDFs, pages that are scans
  are read with on-device text recognition (about 30 languages, including
  English, French, German, Spanish and Russian, but not Greek).

---

## Tools that ask first (the "…" wedges)

Drop files on a wedge ending in "…" and a window opens. Nothing is saved
until you click **Save Copy**; the copy goes next to the original as usual
(`photo (edited).jpg`) and shows up in the progress window. While such a
window is open, Pinwheel appears in the Dock and in ⌘-Tab.

**The image editor** (Crop…, Edit…, Add BG…, Markup… and Watermark… open its tabs):

- **Crop:** drag the corners or edges, drag inside to move the box, or drag
  outside it to draw a new one. Pick a shape (Free, Original, Square, 4:3,
  3:2, 5:4, 16:9; Make Portrait/Landscape turns it). Type a **width and
  height** to get exactly that many pixels (say 1080 × 1080 for a post).
  **Straighten** a tilted horizon (±45°; the picture is enlarged just enough
  to leave no empty corners). Turn left or right and flip.
- **Adjust:** Auto Enhance, exposure, highlights, shadows, contrast,
  saturation, warmth, sharpness, vignette, and 11 filters. Right-click a
  slider to reset it.
- **Background:** remove the background; put the picture on a color, a
  gradient, a blurred copy of itself, or nothing (see-through); padding,
  rounded corners and a shadow; and a canvas shape (1:1, 4:5, 16:9…).
  Handy for screenshots and product photos.
- **Markup:** arrows, boxes, ovals, pen, highlighter, text, numbered steps
  (1, 2, 3…), and **Blur Out** to hide names, faces or numbers. Choose
  *Select* to move things, ⌘⌫ to delete.
- **Watermark:** your text (e.g. "© Ilias 2026") or a logo file, in one of
  nine spots or **tiled** across the picture, with size, opacity, margin and
  a soft shadow. Drop a whole folder's worth of photos on Watermark… to mark
  them all at once; Pinwheel remembers your last watermark.
- **Undo/Redo** (⌘Z, ⇧⌘Z) for everything; hold **Compare** to see the
  original; **Save as** keeps the format (or PNG when parts are
  see-through). Drop several pictures to save the same edit for each (the
  crop keeps its shape on pictures of other sizes).

**Info…** (any file): dimensions, camera and exposure, date and place (with
**Show in Maps**), codecs, pages and more. Edit the title, description,
author, copyright and keywords (photos), title/artist/album/genre/year
(music), or title/author/subject (PDFs); **remove the location**; or **Save
Copy Without Info**. The picture or sound itself is copied as it is, never
re-encoded.

**Edit…** (videos and audio): a timeline (frames, or the sound's waveform)
with yellow handles for the part to keep; Space plays it.
- **Speed** 0.25× to 4×; voices keep their pitch.
- **Turn** videos left or right (the picture isn't re-encoded).
- **Sound:** mute, fade in and out, louder or quieter, or **even out the
  loudness** to −16 LUFS (it shows the file's loudness first).
- **Save Copy**, **Save as GIF** (just the part, at that speed and turn;
  needs ffmpeg) or **Save Frame** (the frame under the playhead, as a JPEG).
- With several files, each keeps its own part; speed, turn and sound can be
  the same for all of them.
Only keeping a part copies the streams as they are (MP3 and FLAC need ffmpeg
for that; without it they become M4A). Changed sound is re-encoded (AAC in
videos), but the picture is copied whenever it can be.

**Collage…** (⇧ wheel, two or more pictures): a **grid** (cells of one
shape, photos cropped to fill them), **rows** (every photo keeps its shape)
or a **contact sheet** (each photo whole, with its name, and an optional
title). Choose how many across, spacing, margin, rounded corners,
background, width (1,500 to 6,000 pixels) and format. Drag the names to
change the order. Saved as `first (collage).jpg`.

**Organize…** (one or more PDFs): every page as a thumbnail. Drag pages to
reorder them (even between PDFs), turn them, remove them, reverse the order;
⌘-click and ⇧-click select several. **Save as One PDF** makes
`first (organized).pdf`.

**Password…** (PDFs): a copy that asks for the password to open.
Pinwheel doesn't remember it.

The **progress window** (top right) shows each file, with ✕ to cancel and 🔍 to
show the result in Finder, the size before and after (for example
`2.4 MB → 1.1 MB (−54%)`), and anything worth knowing (skipped and why, saved
in Downloads, original in Trash). It closes itself a few seconds after
everything succeeds; if something fails, it stays open with the reason. You
get a **notification** for conversions that take 10 seconds or more (click
it to see the files), and whenever something couldn't be saved or there was
nothing to do, with the reason.

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
  preview shows the hover effect once when Settings opens or the glass
  changes, and for as long as the pointer is over it (a moving preview
  keeps the processor busy, so it rests otherwise). **Show on Desktop**
  shows the real wheel over your desktop for 3 seconds.
- **Wheel feedback:** a click sound when the pointer moves onto a format
  (Tink, Pop, Bottle, Morse, Purr or Frog; volume; Test), and a trackpad
  vibration (Force Touch trackpads, felt only while your finger is on it).
- **After converting:** progress window; show new files in Finder; notify
  when a long conversion finishes or something isn't saved; **move the
  original to the Trash** (off by default; only after the new file is saved;
  never for Get Text, frames, collages and GIFs of a part).
- **Saving:** next to the original, in Downloads, or in a folder you choose.
- **Images and PDFs:** JPEG, HEIC and Compress quality; Resize size; combine
  several images into one PDF; PDF page resolution.
- **Tools wheel:** which tools the ⌥⇧ wheel shows for images, videos,
  audio and PDFs. A wheel holds up to 9, so images start without Strip Info
  and Get Text (Info… can remove the info too); switch one off to make room.
- **Video and audio:** video Compress quality (Smallest file / Balanced /
  Best quality) and size limit (keep, 4K, 1080p, 720p); audio Compress bit
  rate; GIF width, frame rate and length.
- **System:** launch at login; how many files to convert at the same time
  (**Automatic** uses most of your Mac's processor cores for images, PDFs
  and audio, and runs 2 videos at once, because the Mac's video engines are
  the limit there); where ffmpeg is (or a custom location); whether pngquant
  is installed.
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

**Remove BG says "No clear subject or plain background was found".**
The model looks for people, animals and objects that stand out; failing
that, Pinwheel removes a plain background color around the edges. Busy
scenes and landscapes have neither. Try Crop… first so the subject fills
more of the picture.

**Get Text finds nothing, or the wrong letters.**
Text recognition doesn't know every language (no Greek yet), and very small
or blurry text is hard to read. PDFs with real text don't need recognition
and work in any language.

**Launch at Login doesn't stick.**
Install into /Applications with `make install`, then turn it on again.

**A job says "Pinwheel's converter stopped unexpectedly".**
Each conversion runs in its own small helper program (see "For the
curious" below). That message means the helper crashed on this file, most
likely because the file is damaged. Pinwheel itself keeps running, and
anything half-written was deleted.

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
  app, and `scripts/build-app.sh` turns the compiled programs into
  `Pinwheel.app` (Info.plist, icon, signing). Release builds leave out the
  debugging names, which halves the programs' size; the full versions stay
  in the build folder. Swift 6 language mode, so the compiler checks for
  threading mistakes.
- `Sources/PinwheelCore`: the conversion engine. Each job is planned once
  (`OutputPlanner`: format, name, folder), then run by the right converter,
  then checked (Compress must really shrink the file). No user interface.
- `Sources/PinwheelWorker`: a small helper inside the app
  (`Pinwheel.app/Contents/MacOS/PinwheelWorker`). The app plans each job and
  picks its file name, then starts one helper per job and sends it the job;
  the helper converts, reports progress, and quits. So the memory the image
  and video encoders use goes back to macOS as soon as a job ends (the app
  stays around 30 MB), and a file that crashes a converter can't take the
  app down. Cancelling a job stops its helper, which deletes anything
  half-written. (`ConversionRunner.swift` is the app's side.)
- `Sources/PinwheelUI`: the menu-bar app (AppKit + SwiftUI, `@Observable`
  models, main thread by default): drag detection, the wheel window, the job
  queue, the progress window, Settings, notifications.
- `Sources/Pinwheel`: just the few lines that start the app.
- Jobs run side by side: by default up to two fewer than your Mac's
  processor cores (at most 8), with at most 2 videos. A PDF's pages are also
  drawn several at a time.
- `Tests/PinwheelCoreTests`: tests that make real images, videos, songs and
  PDFs, convert them, and check the results. `Tests/PinwheelUITests`: the job
  queue, settings, the wheel's labels, and that every glass level draws.
- The image editor's preview and the saved file are drawn by the same code
  (`StudioRenderer`: Core Image for turning, cropping and adjusting, Core
  Graphics for markup and frames). The edit itself (`ImageEdit`) is a small
  value with every position from 0 to 1, so it fits the preview, the
  full-size picture and other pictures alike. Editor windows start ordinary
  jobs with what was chosen (`JobParameters`), so saving runs in the worker.
- Apple frameworks do the work: ImageIO (images), AVFoundation and Core Audio
  (video, audio, FLAC), PDFKit with a Quartz filter (PDFs), Vision (subject
  cut-out and text recognition), AVAudioEngine (speed changes that keep the
  pitch). Loudness is measured the ITU-R BS.1770 way (LUFS).
- Waiting work (decoding sound, Vision, offline audio rendering) runs on
  threads of its own, not Swift's small shared thread pool: Apple's
  frameworks need that pool too, and filling it froze them. ffmpeg is used
  only for MP3, GIFs from video, and files macOS can't open; pngquant only
  for PNG compression. If macOS fails on a file, ffmpeg gets a second try.
- In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin only comes
  with Xcode, so view state lives in small `@Observable` objects passed in.
- Build warnings about `search path '/Library/Developer/CommandLineTools/Developer/…' not found`
  come from Swift Package Manager itself when Xcode isn't installed. They're
  harmless, and the scripts hide exactly that line.
