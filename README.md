# Pinwheel

**Convert, compress and edit files on your Mac with a drop wheel.**
Start dragging files in Finder, hold **⇧ Shift**, and a wheel of formats
appears under the pointer. Drop the files on one and Pinwheel does the rest.
Hold **⌥ Option** too for the tools. Free, open source, and everything
happens on your Mac: nothing is uploaded.

![The format wheel and the tools wheel](docs/wheels.png)

## What it does

**Convert** (⇧ Shift while dragging)
- Pictures (JPEG, PNG, HEIC, TIFF, GIF, WebP, camera RAW…) → PNG, JPEG, HEIC,
  TIFF, GIF or PDF. Several pictures → one PDF, or a **collage**.
- Videos (MOV, MP4, M4V; MKV, WebM, AVI with ffmpeg) → MP4, MOV, GIF, M4A, MP3.
- Audio (MP3, M4A, WAV, AIFF, FLAC, OGG…) → MP3, M4A, WAV, AIFF, FLAC.
- PDFs → PNG, JPEG, HEIC or TIFF (one picture per page), or a smaller PDF.

**Tools** (⌥ Option + ⇧ Shift while dragging)
- **Compress**, and **Size Limit…**: under 10 MB for an email, 25 MB for
  Gmail, or any size, for each file or all together. Pinwheel finds the
  highest quality that fits, and checks.
- **Image editor:** crop to any shape or exact pixels, straighten, adjust
  light and color, 11 filters, remove or replace the background, padding,
  rounded corners and shadows, markup (arrows, text, numbered steps, blur
  out), and watermarks, on one picture or many at once.
- **Remove BG:** cuts out people, pets and objects.
- **Video and audio editor:** trim, speed (pitch kept), turn, mute, fades,
  volume, even out the loudness; save a copy, a GIF of the part, or a frame.
- **Rename…** many files at once: replace text, remove characters, numbers,
  dates, case, patterns with the date taken or the camera, Greek to Latin,
  and more, with a live preview. Works on any file or folder.
- **Info…:** see and edit titles, authors, dates and places; remove the
  location or all hidden info.
- **Get Text** from pictures and scanned PDFs, and make scanned PDFs
  **searchable**. Greek too, with Tesseract.
- PDFs: **merge, split, organize** pages (reorder, turn, remove, from
  several PDFs), and **add a password**.
- **Custom actions:** several steps on one wedge, in your order, for
  example *crop 4:5 → fit 1080 px → watermark → JPEG*.

**And**
- **Undo** at the top of the menu-bar menu: new files go to the Trash and
  originals come back.
- In Finder: **right-click › Services › Convert with Pinwheel**, **Pinwheel
  Tools** or **Rename with Pinwheel**.
- In Terminal and Shortcuts: the **`pinwheel` command**.
- New files are saved next to the originals and never overwrite anything:
  `photo (converted).png`, `video (under 25 MB).mp4`.

![Renaming photos with a few rules](docs/rename.png)

## Install

You need a Mac with **Apple silicon** and **macOS 26 (Tahoe)** or newer.

1. Download **Pinwheel.zip** from the
   [latest release](https://github.com/IliasPa/Pinwheel_file_converter/releases/latest)
   and double-click it.
2. Move **Pinwheel** to your **Applications** folder and open it.
3. macOS says it can't check Pinwheel for malicious software, because
   Pinwheel isn't notarized (that needs a paid Apple developer account).
   Click **Done**, then open **System Settings › Privacy & Security**, scroll
   down to *"Pinwheel" was blocked…* and click **Open Anyway**. You only do
   this once.
4. Pinwheel opens its Settings and asks for the **Accessibility**
   permission, which it needs to notice Shift and the mouse while you drag.
   Follow the steps there; the section turns green when it's done.

Look for the small wheel in the menu bar. That's it: drag some files, hold
Shift, and drop.

**Optional extras** from [Homebrew](https://brew.sh):
`brew install ffmpeg pngquant tesseract`
- **ffmpeg:** MP3, GIFs from videos, and MKV, WebM, AVI or OGG files.
- **pngquant:** much smaller PNGs with Compress.
- **tesseract:** reading Greek text. Then click **Download Greek** in
  Settings › Text recognition.

Without them everything else works; wedges that need them are grayed out
and say why.

**Updates:** menu-bar icon › **Check for Updates…**. Replace the app in
Applications with the new one; your settings stay.

## Using it

| You want to… | Do this |
|---|---|
| Convert | Drag files, hold **⇧ Shift**, drop on a format |
| Use a tool | Drag files, hold **⌥ Option + ⇧ Shift**, drop on a tool |
| Change your mind | Let go of Shift, or drop in the middle |
| Choose from Finder | Right-click files › **Services** › **Pinwheel Tools**, then click a wedge |
| Take it back | Menu-bar icon › **Undo …** |
| See the original while editing a photo | Hold **Space** (or the Compare button) |

Tools whose names end in "…" open a window where you choose the details
first. The progress window shows each file, the size before and after, and
anything worth knowing; long jobs and anything that couldn't be saved also
get a notification.

**Settings** (menu-bar icon › Settings…): the wheel's glass look and sound,
where new files go, qualities and sizes, which tools are on the wheel,
**custom actions**, text recognition, and how to use Pinwheel from Finder
and Shortcuts.

**The `pinwheel` command** lives inside the app. In Terminal:

```sh
alias pinwheel=/Applications/Pinwheel.app/Contents/Helpers/pinwheel
pinwheel convert jpg ~/Desktop/*.heic
pinwheel size-limit 10MB video.mov
pinwheel run "Instagram" photo.jpg      # one of your custom actions
pinwheel help
```

In **Shortcuts**, add *Run Shell Script*, set *Pass Input* to *as arguments*
and write `/Applications/Pinwheel.app/Contents/Helpers/pinwheel compress "$@"`.
Switch on *Use as Quick Action › Finder* to have it in Finder's right-click
menu.

## Privacy

Pinwheel converts and edits on your Mac and sends nothing anywhere. It goes
online only when you ask it to: **Check for Updates…** asks GitHub for the
newest version, **Download Greek** gets Tesseract's Greek file from the
Tesseract project, and **Send Feedback…** sends your message (with your
email only if you add it, and Pinwheel's and macOS's version) to the
developer through [formsubmit.co](https://formsubmit.co).

The Accessibility permission is used only to notice the Shift and Option
keys and the mouse while you drag files. Pinwheel never records what you
type.

## Troubleshooting

**The wheel doesn't appear.** Open Settings and look at the Permission
section. If the switch in System Settings is on but the section stays
orange, click **Reset Permission…** and switch Pinwheel on again.

**"Pinwheel can't be opened".** See step 3 of [Install](#install).

**A wedge is gray.** Hover it: the middle of the wheel says why (usually
"Needs ffmpeg").

**Compress says "Already as small as it gets".** The compressed copy wasn't
clearly smaller, so the original is the better file and nothing was saved.

**Pinwheel isn't in Finder's right-click menu.** It's under **Services** at
the bottom. If not, switch it on in System Settings › Keyboard › Keyboard
Shortcuts › Services › Files and Folders.

**Get Text reads Greek wrong.** Apple's text recognition doesn't read Greek:
install Tesseract and click **Download Greek** in Settings › Text recognition.

## Ideas and bugs

Menu-bar icon › **Send Feedback…**: write up to 400 characters, and add your
email if you'd like to hear back (whether it was added, if it can't be done,
or when work on it starts). Or open an
[issue on GitHub](https://github.com/IliasPa/Pinwheel_file_converter/issues).
What changed in each version is in [CHANGES.md](CHANGES.md).

## Build it yourself

You need macOS 26 and Apple's **Command Line Tools** (`xcode-select --install`;
no Xcode needed).

```sh
git clone https://github.com/IliasPa/Pinwheel_file_converter.git
cd Pinwheel_file_converter
make install
```

| Command | What it does |
|---|---|
| `make run` | Builds Pinwheel and starts it. |
| `make install` | Builds it, copies it into /Applications, and starts it. |
| `make test` | Runs the tests (about 240, with real conversions). GitHub runs them on every push too. |
| `make release` | Builds and packs `Pinwheel-<version>.zip` for a GitHub release. |
| `make clean` | Deletes all build files. |
| `make icon` | Redraws the app icon from `scripts/make-icon.swift`. |

Builds go to `~/Library/Developer/Pinwheel`, outside the project folder.

**Keeping the Accessibility permission across rebuilds.** macOS treats each
build signed "to run locally" as a new app and forgets the permission. Make a
self-signed certificate once and the build script uses it: open **Keychain
Access › Certificate Assistant › Create a Certificate…**, name it exactly
`Pinwheel Local Signing`, Identity Type *Self Signed Root*, Certificate Type
*Code Signing*. The first build after that asks for your Mac password: click
**Always Allow**.

### How it's built

- **Swift Package Manager**, Swift 6, AppKit and SwiftUI. No other
  dependencies: the work is done by Apple's frameworks (ImageIO, Core Image,
  AVFoundation, PDFKit, Vision), with ffmpeg, pngquant and Tesseract used
  only when they're installed.
- `PinwheelCore` is the conversion engine (no user interface).
  `PinwheelUI` is the menu-bar app. `PinwheelWorker` is a small helper the
  app starts for each job, so the memory it used goes back to macOS right
  away and a damaged file can't crash Pinwheel. `PinwheelCLI` is the
  `pinwheel` command.
- The tests make real pictures, videos, songs and PDFs, convert them, and
  check the results. `Tests/PinwheelUITests/ReadmeImages.swift` draws the
  pictures in this README (`PINWHEEL_README_IMAGES=docs make test`).

## License

[MIT](LICENSE) © 2026 Ilias Paraskevas
