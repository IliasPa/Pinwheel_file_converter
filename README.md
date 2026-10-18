# Pinwheel

Pinwheel is a small menu-bar app for your Mac that converts files with a
**drop wheel**. Start dragging files in Finder, hold **Shift**, and a wheel of
formats appears under your pointer. Drop the files on a format and Pinwheel
converts them. Everything happens on your Mac: nothing is uploaded.

- Hold **⇧ Shift** while dragging: the **format wheel** (PNG, JPEG, MP4, MP3…).
- Hold **⌥ Option + ⇧ Shift** while dragging: the **tools wheel** (Compress,
  Size Limit…, Resize, Remove BG, Crop…, Edit…, Watermark…, Rename…, Info…,
  Organize…, Searchable and more, plus **your own custom actions**). Tools
  ending in "…" open a window where you choose the details first, like the
  crop's shape and size.
- Let go of Shift, or drop in the middle or outside the wheel: nothing happens.
- Or **right-click files in Finder › Services**, or use the `pinwheel`
  command (Terminal, Shortcuts): see [Finder and Shortcuts](#finder-and-shortcuts).
- Something not what you wanted? **Undo** is at the top of the menu-bar
  menu: new files go to the Trash and originals come back.

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
- **Homebrew**, **ffmpeg**, **pngquant** and **Tesseract** (optional).
  Without ffmpeg, everything works except MP3, GIFs from videos, and
  MKV/WebM/AVI/OGG-type files. Without pngquant, Compress can hardly shrink
  PNGs. Without Tesseract, text recognition can't read Greek. To install:
  1. Get Homebrew from <https://brew.sh> (copy the command on that page into Terminal).
  2. In Terminal, run: `brew install ffmpeg pngquant tesseract`
  3. For Greek, click **Download Greek** in Settings › Text recognition (9 MB).

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
| `make test` | Runs the automated tests (about 240 of them, including real conversions). GitHub runs them too, on every push. |
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
| **Images** (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP, camera RAW…) | PNG, JPEG, HEIC, TIFF, GIF, PDF; **Collage…** (two or more) | Compress, Size Limit…, Resize, Remove BG, Crop…, Edit…, Watermark…, Info…, Rename… (also Add BG…, Markup…, Strip Info, Get Text: see Settings › Tools wheel) |
| **Videos** (MOV, MP4, M4V; MKV, WebM, AVI with ffmpeg) | MP4, MOV, GIF\*, M4A, MP3\* | Compress, Size Limit…, Strip Info, Get Audio, Mute, Edit… (trim, speed, turn, sound, GIF), Info…, Rename… |
| **Audio** (MP3, M4A, WAV, AIFF, FLAC, OGG…) | MP3\*, M4A, WAV, AIFF, FLAC | Compress, Size Limit…, Strip Info, Normalize, Edit… (trim, speed, fades, loudness), Info…, Rename… (MP3/FLAC Strip Info and saving info need ffmpeg) |
| **PDFs** | PNG, JPEG, HEIC, TIFF (one image per page), Smaller PDF | Compress, Size Limit…, Merge, Split Pages, Organize…, Searchable, Password…, Info…, Rename… (also Strip Info, Get Text) |
| **Anything else** (documents, folders…) | — | Rename… |

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
  are read with on-device text recognition: Apple's (about 30 languages,
  not Greek) or, for **Greek**, Tesseract (see Settings › Text recognition).
- **Searchable** (PDFs): scanned pages get an invisible layer with their
  text, like a scanner's "OCR" option, so the PDF can be searched and its
  text selected and copied: `scan (searchable).pdf`. Pages that already have
  text are left as they are, and every page looks exactly as before.

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
- **Undo/Redo** (⌘Z, ⇧⌘Z) for everything; hold **Compare** (or **Space**,
  when you're not typing) to see the original; **Save as** keeps the format (or PNG when parts are
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
reorder them (even between PDFs): a colored bar shows where they'll go,
before or after the page under the pointer (or "Put at the end" below the
last). Turn them, remove them, reverse the order; ⌘-click and ⇧-click
select several. **Save as One PDF** makes `first (organized).pdf`.

**Size Limit…** (any kind): how big may it be? 1, 2, 5, 8, 10, 20, 25 or
50 MB, or exactly what you type, for **each file** or **all together** (to
fit in one email; the size is shared out by how big each file is). Pinwheel
works out the highest quality that fits, and checks: pictures go down in
quality first and get smaller in size only if needed; videos get the bit
rate (and if needed the picture size) that fits; audio gets the bit rate
(mono when it's very tight); PDFs get their pictures shrunk step by step.
`video (under 25 MB).mp4`. Files that already fit are left alone, and if
something can't get that small (a long video in 1 MB), nothing is saved
and you're told how much it would need.

**Rename…** (any files, even ones Pinwheel can't convert, and folders):
rules run from top to bottom, and the list on the right shows every new
name before anything happens, in orange when it would clash with another
or with a file already there. The rules:
- **Replace text** (any case or exact, all/first/last, regular expressions
  with $1, the extension too if you like).
- **Remove characters:** the first or last few (e.g. "delete the last 3
  characters"), from a position, all but the first/last few, everything up
  to or from some text, or between two marks like ( and ).
- **Remove kinds of text:** digits, spaces, special characters, text in
  brackets, emoji, accents, Finder's "copy" and "(1)", Latin or Greek letters.
- **Add text:** at the start, the end, after or before a number of
  characters, or before/after some text.
- **Change case:** lowercase, UPPERCASE, Title Case, Sentence case,
  camelCase, PascalCase, snake_case, kebab-case (Greek capitals lose their
  accents, as they should).
- **Spaces and separators:** spaces to _ - or ., or back; tidy up.
- **Numbering:** start, step, digits (001), 1 2 3 / a b c / A B C / I II III,
  before, after or instead of the name.
- **New name from a pattern:** `{name}`, `{n}`, `{date}` (taken), `{created}`,
  `{modified}`, `{today}`, `{folder}`, `{width}x{height}`, `{camera}`,
  `{duration}`, `{original}`, `{ext}`.
- **Add a date:** taken, created, modified or today, in many formats.
- **Greek to Latin:** Greeklish by the Greek standard (ELOT 743:
  Αθήνα → Athina), classical, or any script to Latin.
- **Pad numbers** with zeros, **swap** around a separator ("Artist - Title"
  → "Title - Artist"), and the **extension** (lower/upper case, change, remove).

Rules can be switched off, moved, duplicated, and saved as **presets**. The
order (for numbering) is by name, date taken, created, modified, size, kind,
or the way you drag the names. Renaming is all or nothing, and can be undone
from the menu bar.

**Custom actions** (made in Settings › Tools wheel, under each kind of file):
several steps on one wedge, in the order you choose, e.g. *Crop 4:5 → Fit
1080 px → Watermark → To JPEG*. Steps: convert, compress, size limit, resize,
crop to a shape, turn, flip, remove background, auto enhance, filter,
background and frame, watermark, remove location, strip info, get text,
searchable (PDFs), get audio, mute, even out loudness, speed, fades and
volume (video and audio). Each step works on what the step before made (a
video can become audio halfway, a picture a PDF), and the result is named
after the action: `photo (Instagram).jpg`. A step with nothing to do (a
picture already small enough) is passed over and the progress window says so.

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
  audio and PDFs, and **New Custom Action…** for each. A wheel holds up to
  9, so images start without Add BG…, Markup… (they're tabs of the same
  editor), Strip Info and Get Text; PDFs without Strip Info and Get Text.
  Switch one off to make room. Tools new in an update join your wheel only
  where there's room, so a wheel you arranged keeps what you chose.
- **Text recognition:** Apple's (built in) or Tesseract (for Greek); shows
  whether Tesseract is installed and downloads its Greek file.
- **Finder and Shortcuts:** how to use Pinwheel from Finder's right-click
  menu and from Shortcuts, with the command to copy.
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

## Undo

The menu-bar menu starts with **Undo** and what it would take back, e.g.
"Undo Compress (3 files)", with when it happened. It puts the new files in
the Trash, brings originals back out of the Trash (when Pinwheel had moved
them there), and gives renamed files their old names. Press it again for
the step before (up to 20, while Pinwheel runs). If something can't be
undone (a file moved since, or the Trash emptied), it says which.

---

## Finder and Shortcuts

**Finder:** select files, right-click, and at the bottom choose **Services ›
Convert with Pinwheel**, **Pinwheel Tools** or **Rename with Pinwheel**.
The wheel opens under the pointer: click a wedge, or click the middle to
switch between formats and tools; Esc or a click elsewhere closes it. If
they're missing, switch them on in System Settings › Keyboard › Keyboard
Shortcuts › Services › Files and Folders.

**The `pinwheel` command** is inside the app:
`/Applications/Pinwheel.app/Contents/Helpers/pinwheel`. It asks Pinwheel to
do the job (starting it if needed), so jobs show in the progress window and
can be undone, then prints the new files' paths:

```sh
pinwheel convert jpg ~/Desktop/*.heic
pinwheel size-limit 10MB video.mov
pinwheel run "Instagram" photo.jpg      # one of your custom actions
pinwheel show tools *.pdf               # the wheel, to click
pinwheel help                           # everything it can do
```

**Shortcuts:** add **Run Shell Script**, set **Pass Input** to **as
arguments**, and write `"/Applications/Pinwheel.app/Contents/Helpers/pinwheel" compress "$@"`
(or any other command). Switch on **Use as Quick Action › Finder** in the
shortcut's details to have it in Finder's right-click **Quick Actions**.
(Shortcuts' own Pinwheel actions would need Xcode to build; the command
works without it.)

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

**Get Text or Searchable finds nothing, or the wrong letters.**
Apple's text recognition doesn't read Greek: install Tesseract
(`brew install tesseract`) and click **Download Greek** in Settings › Text
recognition. Very small or blurry text is hard to read either way. PDFs
with real text don't need recognition and work in any language.

**Pinwheel isn't in Finder's right-click menu.**
Look under **Services** at the bottom of the menu. If it isn't there, switch
it on in System Settings › Keyboard › Keyboard Shortcuts › Services › Files
and Folders. `make install` also tells macOS about them.

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
  queue, the progress window, Settings, notifications, Undo, Finder's
  Services, and `CommandCenter` (requests from the `pinwheel` command).
- `Sources/PinwheelCLI`: the `pinwheel` command (Foundation only), in
  `Pinwheel.app/Contents/Helpers`. It and the app talk with distributed
  notifications, which never leave the Mac.
- `Sources/Pinwheel`: just the few lines that start the app.
- Jobs run side by side: by default up to two fewer than your Mac's
  processor cores (at most 8), with at most 2 videos. A PDF's pages are also
  drawn several at a time.
- `Tests/PinwheelCoreTests`: tests that make real images, videos, songs and
  PDFs, convert them, and check the results. `Tests/PinwheelUITests`: the job
  queue, settings, the wheel's labels, that every glass level draws, the
  editor windows' logic, Undo, and the `pinwheel` command talking to the app.
  `.github/workflows/tests.yml` runs them all on GitHub for every push.
- Size Limit aims and checks: pictures by halving the quality range, videos
  by bit rate with a cap per second (Apple's encoder treats the average as a
  wish), then aiming again with how much the last change saved.
- Custom actions run each step as an ordinary job on what the step before
  made, in a private folder, inside the worker.
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
