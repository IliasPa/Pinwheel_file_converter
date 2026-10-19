# Changes

What changed in each version of Pinwheel. Newest first. Each version has a
matching git tag (for example `v0.4`).

## v1.1 — 2026-10-19

**New**
- **Send Feedback…** in the menu-bar menu: an idea, a problem or a change,
  in up to 400 characters, straight to Pinwheel's developer. Add an email
  address to hear back (whether it was added, if it can't be done, or when
  work starts); it's optional, and remembered on this Mac only. Messages go
  through formsubmit.co with Pinwheel's and macOS's version, nothing else.
  If sending doesn't work, **Send It by Email Instead** opens the message
  in the Mail app.

## v1.0 — 2026-10-19

Ready for everyone: a download on GitHub, a README for new users, a
license, and a cleaned-up, smaller app.

**Fixed**
- **Collage…** and **Organize…** with several files made one job per file
  (a "collage" of each picture alone, or a PDF missing the other files'
  pages). This was so since v0.8: the job queue kept only Merge and
  images-into-one-PDF together. Found by the unused-code check below; a
  test now goes through the job queue the way the windows do.

**New**
- **About Pinwheel** and **Check for Updates…** in the menu-bar menu. The
  check asks GitHub for the newest release only when chosen.
- Downloadable from GitHub Releases as **Pinwheel.zip** (`make release`
  makes it), with install steps in the README (new, with pictures).
- **MIT License.**

**Smaller**
- The app is **5.4 MB** (was 6.5 MB) and uses about **13 MB** of memory
  when idle. Release builds are optimized for size (15% smaller programs;
  the conversions measured just as fast), and the icon is 40% smaller with
  no visible change.

**Under the hood**
- Unused code removed, found with Periphery: two crop helpers, an editor
  flag, a menu label, a naming helper only the tests used (now in the
  tests), unused parameters and properties. Types used only inside the
  engine are no longer public. No unused imports or libraries were found;
  Pinwheel depends only on Apple's frameworks.

## v0.9.2 — 2026-10-19

**Fixed**
- Compressing a video (also Size Limit, and custom actions with those
  steps) left a stray copy beside the result on macOS 27, named like
  `clip (compressed).mp4.sb-43f18260-IOwLl9`: the not-yet-optimized
  version, which the system forgets to delete. Pinwheel now removes it.
  Found by trying the installed app; a test now checks for it.

## v0.9.1 — 2026-10-19

Fixes found by the new tests on GitHub (a 3-core Mac with macOS 26 and
Xcode 26).

**Fixed**
- Compress and Size Limit for video and audio could stop forever on a Mac
  with few cores: they read the file on Swift's shared threads, and on
  macOS 26 the decoder needs those threads itself. Reading now has a
  thread of its own, as audio decoding already did.
- The `pinwheel` command now notices when Pinwheel quits during a job
  (it asks again every 10 seconds and gives up after 35 seconds of
  silence) instead of waiting for hours.
- Builds with the Swift in Xcode 26 too: two long expressions are split
  up, and settings sliders and pickers no longer pass functions where
  that Swift's compiler crashed.

**Under the hood**
- GitHub runs the tests with the newest Xcode on its Mac; all 239 pass
  there, Greek text recognition included.

## v0.9 — 2026-10-18

Undo, custom actions, file size limits, batch rename, Greek text, and
Pinwheel from Finder and Shortcuts.

**Undo** (top of the menu-bar menu)
- "Undo Compress (3 files)": new files go to the Trash, originals come back
  out of it, renamed files get their old names. Up to 20 steps back; says
  what couldn't be undone and why.

**Custom actions** (Settings › Tools wheel › New Custom Action…)
- Several steps on one wedge, in the order you choose (e.g. Crop 4:5 → Fit
  1080 px → Watermark → To JPEG), for images, videos, audio or PDFs. 23
  kinds of step, each with its choices; kinds can change along the way
  (video → audio, picture → PDF). Steps with nothing to do are passed over.

**Size Limit…** (all kinds)
- Under 1–50 MB or any size, each file or all together (shared out by
  size). Pictures: the highest quality that fits, then a smaller picture
  only if needed. Videos: the bit rate (and if needed the picture size) that
  fits, checked and aimed again. Audio: the bit rate that fits (mono when
  tight). PDFs: their pictures, step by step.

**Rename…** (any files and folders)
- 13 kinds of rule: replace (with regular expressions), remove characters
  (first/last few, from a position, up to/from some text, between marks),
  remove kinds of text, add text, change case (8 styles), separators,
  numbering (1/a/A/I), patterns with tokens ({date}, {camera}…), dates,
  Greek to Latin (ELOT 743 Greeklish), pad numbers, swap, extension.
- A live preview with clashes in orange, presets, order by name/date/size
  or by dragging, all-or-nothing renaming, and Undo.

**Greek text and searchable PDFs**
- Text recognition with **Tesseract** (Homebrew) for Greek: Settings › Text
  recognition downloads its Greek file (9 MB) and shows what's in use.
  Automatic picks Tesseract once it has Greek.
- **Searchable** (PDFs): scanned pages get an invisible text layer, to
  search and copy; the pages look exactly as before.

**Finder and Shortcuts**
- Finder's right-click › Services: **Convert with Pinwheel**, **Pinwheel
  Tools** (the wheel opens under the pointer, to click; the middle switches
  formats/tools) and **Rename with Pinwheel**.
- The **`pinwheel` command** (`Pinwheel.app/Contents/Helpers/pinwheel`):
  convert, compress, size-limit, run a custom action, show the wheel, open a
  window… It hands the job to the app (starting it if needed) and prints
  the new files. Use it in Shortcuts' Run Shell Script, also as a Quick
  Action. (Shortcuts' own actions would need Xcode.)

**Smaller things**
- Image editor: **hold Space** to see the original (not while typing).
- Organize…: a **bar shows where dragged pages land**, before or after the
  page under the pointer, and "Put at the end" below the last page.
- Video editor: the timeline's frames now turn with the picture.
- Resize: Fit 1080 px and Fit 2048 px.

**The wheel**
- New tools join a wheel only where there's room: a wheel arranged by hand
  keeps what was chosen (the new tools wait, switched off, in Settings).
  Untouched wheels get 0.9's choice: images hide Add BG… and Markup… (tabs
  of the same editor), PDFs hide Strip Info and Get Text.
- Files Pinwheel can't convert (documents, folders) get Rename… on the
  tools wheel.

**Fixed**
- File sizes were read from a cache: the same file written again (Size
  Limit's second try) still reported its first size.

**Under the hood**
- Tests run on GitHub for every push (`.github/workflows/tests.yml`),
  with ffmpeg, pngquant and Tesseract with Greek.
- New tests: every rename rule, clashes, swapping and rolled-back renames,
  size limits for pictures/PDFs/audio/video (noisy and phone-shaped),
  custom actions, Tesseract's table and Greek, searchable PDFs, Undo, the
  settings upgrade, the command end to end, Rename/Size Limit/Organize
  logic, Space, the click wheel, Finder's Services, and the video editor
  playing a real portrait video.

## v0.8 — 2026-10-18

More editing, for photos, videos, sound and PDFs.

**Photos**
- **Straighten** (image editor › Crop): level a tilted horizon, ±45°. The
  picture is enlarged just enough to leave no empty corners.
- **Watermark…**: text or a logo, in one of nine spots or tiled across the
  picture, with size, opacity, margin and a soft shadow. Works on many
  photos at once, and remembers your last watermark.
- **Collage…** (⇧ wheel, two or more pictures): grid, rows (every photo
  keeps its shape) or contact sheet (names and a title); columns, spacing,
  margin, corners, background, width and format; drag to reorder.
- **Remove BG** now does something useful when there's no subject: logos,
  icons and drawings lose their plain background color (holes in letters
  too). When there's neither, a **notification** says so.

**Videos and audio**
- **Edit…** replaces Trim…: a timeline with frames or the waveform, yellow
  handles for the part, and **speed** (0.25×–4×, pitch kept), **turn**
  (picture not re-encoded), **mute**, **fades**, **volume** and **loudness**
  (to −16 LUFS, showing the file's loudness). Save the result, **a GIF of
  just the part** (at that speed and turn), or one frame. Several files keep
  their own part and can share the rest.
- **Normalize** (audio, one drop): evens out the loudness to −16 LUFS
  without clipping peaks; a file already there is left alone.

**PDFs**
- **Organize…**: every page of one or more PDFs as thumbnails; drag to
  reorder (also between PDFs), turn, remove, reverse; save as one PDF.

**Feedback**
- A notification whenever a file couldn't be saved or there was nothing to
  do, with the reason (not only for long conversions), and the progress
  window stays up longer to show it.

**Fixed**
- Cancelling a running job crashed its helper program instead of letting it
  clean up (its "stop" handler ran on the wrong thread under Swift 6), which
  could leave an ffmpeg process running. It now stops cleanly.

**Under the hood**
- The tools wheel holds 9 wedges (images now have 11 tools; Settings picks).
- Waiting work (decoding sound, Vision, offline audio) runs on threads of
  its own; filling Swift's shared thread pool with it froze Apple's frameworks.
- Get Text, frames, collages and GIFs of a part never send their source to
  the Trash.
- New tests: straighten, watermarks, plain backgrounds, collage layouts,
  page organizing, BS.1770 loudness (a −20 dBFS tone reads −20 LUFS),
  normalize, fades, speed, turning, GIF of a part, turned frames, the new
  windows' logic, the notifications, and Remove BG in the helper process.

## v0.7 — 2026-10-18

Edit, not just convert. Wedges that end in "…" now open a window where you
choose the details first, and the tools wheel has new one-drop tools.

**New: the image editor** (⌥⇧ wheel › Crop…, Edit…, Add BG… or Markup…)
- **Crop:** drag the box (corners, edges, or inside to move it; drag outside
  to draw a new one). Shapes: Free, Original, Square, 4:3, 3:2, 5:4, 16:9,
  each in portrait or landscape. Type a **width × height** to get exactly
  that many pixels. Turn left/right and flip.
- **Adjust:** Auto Enhance; exposure, highlights, shadows, contrast,
  saturation, warmth, sharpness, vignette; 11 filters (Vivid, Mono, Noir,
  Sepia, Chrome, Fade…) with live previews.
- **Background:** remove the background (keeps people, pets and objects);
  put the picture on a color, a gradient, a blurred copy of itself, or
  nothing; padding, rounded corners and shadow sliders; canvas shapes (1:1,
  4:5, 16:9…) for posts and slides.
- **Markup:** arrows, boxes, ovals, pen, highlighter, text, numbered steps,
  and **Blur Out** for names, faces and numbers. Select to move, ⌘⌫ to
  delete, eight colors, three sizes.
- Undo/Redo for everything, **hold Compare** to see the original, choose
  the format (Automatic keeps it, or PNG when parts are see-through). Drop
  several pictures and the same edit is saved for each. Saved as
  `photo (edited).jpg`; the preview and the saved file come from the same
  drawing code, so what you see is what you get.

**New tools**
- **Remove BG** (images): the subject on a see-through PNG, in one drop.
- **Info…** (every kind of file): see dimensions, camera, exposure, date,
  place (with Show in Maps), codecs, pages…; edit the title, author,
  description, keywords, artist, album, genre…; remove the location; or
  save a copy without any info. The picture or sound is copied as it is.
- **Trim…** (videos and audio): QuickTime-style handles; the part is cut
  without re-encoding. Videos can also **Save This Frame** as a JPEG.
- **Mute** (videos): the same video without sound.
- **Merge** and **Split Pages** (PDFs): several PDFs into one (name order),
  or one PDF per page in a folder.
- **Password…** (PDFs): a copy that asks for a password to open.
- **Get Text** (PDFs, and images if you switch it on): all the text as a
  .txt file. Scanned PDF pages are read with on-device text recognition.

**Tools wheel**
- Images now have more tools than fit on one wheel (8 at most). Settings ›
  Tools wheel chooses which show, for each kind of file. Strip Info and
  Get Text start off the image wheel (Info… can remove the info too).

**Also**
- While an editor window is open, Pinwheel shows in the Dock and ⌘-Tab, and
  the usual Edit menu shortcuts (⌘C, ⌘V, ⌘Z) work in its text fields.

**Under the hood**
- Jobs from editor windows carry what was chosen (`JobParameters`) and run
  in the worker like any other job.
- Vision (subject lifting, text recognition) takes turns within a process:
  running several requests at once could deadlock.
- New tests: turning and flipping, crop math, sizes, every filter, markup,
  frames, subject cut-out, text recognition, PDF merge/split/password, mute,
  trim, frames from video, metadata round trips for photos, PDFs, M4A, MOV
  and MP3, and the editor's crop, markup, undo and save.

## v0.6 — 2026-10-03

Faster and lighter. Every number below was measured on an M5 MacBook,
before and after.

**Fixed**
- **Settings no longer keeps the Mac busy.** Its glass preview moved the
  highlight every 1.6 seconds forever, even after you closed Settings
  (about 14% of one processor core until you quit Pinwheel). Now the
  closed Settings window is freed (0%), and while it's open the preview
  shows the hover effect once (when Settings opens or the glass changes)
  and whenever the pointer is over it, then rests (0%).
- **No more invisible wheel left on screen.** Hiding the wheel waited for
  macOS's "fade finished" signal; if that never came, the see-through wheel
  window stayed up and later hide requests were ignored. It now goes away
  on a timer. (30 rounds of random show/hide: nothing left behind.)

**Faster**
- **More files at the same time, automatically.** "Convert at the same
  time" now defaults to **Automatic**: up to two fewer than your Mac's
  processor cores (at most 8) for images, PDFs and audio, and 2 videos at
  once (the Mac's video engines are the limit there). 24 photos to JPEG:
  1.2 s → 0.48 s. You can still pick a fixed number (1–8).
- **PDF pages are drawn side by side**, one per processor core. A 40-page
  PDF to PNG: 3.1 s → 0.57 s; to JPEG: 0.6 s → 0.25 s.

**Lighter**
- **Each conversion runs in its own small helper program**
  (`PinwheelWorker`, inside the app) that quits when the job is done. The
  image and video encoders' memory goes back to macOS right away: after
  converting 6 photos, Pinwheel stays around 31 MB instead of 131 MB. A
  file that crashes a converter now only stops that job, not Pinwheel.
  Cancelling a job stops its helper, which deletes anything half-written.
- **Smaller app:** release builds leave out debugging names. The main
  program went from 2.0 MB to 1.1 MB; the whole app is 2.7 MB with the new
  helper (was 3.1 MB).
- **No more checking the permission every 3 seconds** once it's granted.
  macOS announces changes, and the menu and Settings check when they open.

**Under the hood**
- The engine is split into `prepare` (plan and reserve the file name, in
  the app) and `perform` (convert, in the helper), so jobs in different
  helpers can never pick the same name.
- Reading a helper's output now waits for the very end of it, in order, so
  its last message can't get lost.
- New tests: jobs through the helper, helper errors, a crashing helper,
  cancelling mid-job, PDF pages landing in the right files, video slots in
  the queue, Automatic limits, and freeing the Settings window (95 tests).

## v0.5.1 — 2026-10-02

**Fixed**
- **Liquid Glass now really shows on the desktop.** The wheel and the progress
  window were drawn in borderless windows, where macOS 26 can't show what's
  behind the glass, so it turned into a flat gray disc (only the Settings
  preview looked right). They're now titled windows with the title bar
  hidden, the kind of window where glass does show the desktop. Found by
  testing six ways of drawing glass side by side.
- **Labels stay readable on Clear Glass and Crystal**, even over a white
  document: a soft halo behind the text (dark in Dark Mode, light in Light
  Mode), a 25% shade under Clear Glass and a 10% shade under Crystal.

## v0.5 — 2026-10-02

**Redesigned**
- **Liquid Glass, done properly.** The whole wheel is now one piece of glass,
  with the icons, labels and thin dividers inside it as its content (so
  Liquid Glass keeps them legible). The gray wedge fills that made it look
  like frosted plastic are gone; only the chosen wedge is colored. The five
  steps are now: Frosted, Tinted Glass, Liquid Glass, Clear Glass (with a
  light shade) and Crystal (fully clear). Crystal is the clearest version of
  the same wheel instead of separate bubbles. The progress window uses the
  same glass.

**Compress, Resize and friends**
- **Compress checks its result.** If the file isn't clearly smaller (at least
  3%), nothing is saved and the progress window says "Already as small as it
  gets".
- **PNGs stay PNG.** Compress shrinks them with pngquant (installed with
  Homebrew). JPEG and HEIC keep their format too; TIFF, BMP and RAW become HEIC.
- **Video Compress settings:** quality (Smallest file / Balanced / Best
  quality) and size (keep the original size, 4K, 1080p, 720p). It no longer
  shrinks 4K videos to 1080p behind your back, never aims above the
  original's bit rate, and copies an already-small soundtrack as it is.
- **Resize settings:** 25%, 50%, 75%, or fit within 1280/1920/2560/3840
  pixels. The wedge shows the choice ("Fit 1920 px"); images already small
  enough are left alone.
- **GIF length limit:** GIFs from videos use the first 5/10/15/30/60 seconds
  or the whole video (default 15 seconds).
- **Several images → one PDF:** dropping several images on PDF makes one
  PDF with a page per image, in name order (can be switched off).
- **Read-only folders:** if the original's folder can't be written to (a disk
  image, a read-only share), the file is saved in Downloads and you're told.
- **Choose where files go:** next to the original, Downloads, or a folder.

**Extras**
- Notification when a conversion of 10 seconds or more finishes (click it to
  see the files).
- Every finished job shows its size before and after.
- Audio Compress bit rate and "files at the same time" are settings now.
- Settings shows whether pngquant is installed.

**Cleaner code**
- Each job is planned once (format, name, folder) and the converters just
  follow the plan; planning now happens in the background, not when you drop.
- One shared "try Apple's frameworks, then ffmpeg" helper instead of two copies.
- Fixed numbers (bit rates, PDF picture resolution, parallel jobs) moved into
  the options and Settings.
- Minimum macOS is now 26: no more version checks, Apple's newer
  video-export API, `@Observable` models, Swift 6 language mode with the app
  code on the main thread by default.
- The app code is a library (`PinwheelUI`), so it has its own tests (job
  queue, settings, wheel labels, drawing at every glass level).
- At most ~10 progress updates a second per job.

## v0.4 — 2026-10-02

**Fixed**
- **Crystal (glass step 5) now shows glass.** It used to be invisible. Each
  choice is now its own round piece of clear Liquid Glass, set out in a ring;
  the one under the pointer turns blue and moves outward.
- **The permission status updates by itself.** Pinwheel checks every second
  (and the moment macOS announces a change), so Settings and the menu turn
  green as soon as you switch Pinwheel on in System Settings.

**New**
- **Permission help is now part of Settings.** The separate welcome window and
  the "Permissions Help…" menu item are gone. Settings starts with a
  Permission section (status, why it's needed, step-by-step help, Open System
  Settings). If the permission is missing at launch, Settings opens by itself.
  The menu's "⚠︎ Accessibility permission needed…" item opens it too.
- **Reset Permission…** button for "the switch is on but the wheel doesn't
  appear" (an old entry left by an earlier build). It removes the entry and
  asks again.
- **Click sound when moving over the wheel**, with a choice of sounds (Tink,
  Pop, Bottle, Morse, Purr, Frog), a volume slider and a Test button. The
  trackpad vibration is stronger and has its own switch.
- **Move the original to the Trash** after a successful conversion (Settings ›
  After converting, off by default). It only happens once the new file is
  saved; the progress window says "original in Trash".
- **Stable signing.** A "Pinwheel Local Signing" certificate was created in the
  login keychain. Builds signed with it keep the Accessibility permission. The
  first time, macOS asks you to allow codesign to use it ("Always Allow"); if
  the build can't ask, it signs the old way and says so instead of failing.
- This `CHANGES.md` file.

## v0.3 — 2026-09-29

- **Tools wheel** (hold ⌥ Option + ⇧ Shift): Compress, Resize 50%, Strip Info,
  Get Audio, for images, videos, audio and PDFs.
- **Settings window**: 5-step Glass slider (Frosted, Soft Glass, Liquid Glass,
  Clear Glass, Crystal) with a live preview and "Show on Desktop"; trackpad
  tick; progress window and Finder options; JPEG/HEIC/Compress quality; PDF
  resolution; GIF size and frame rate; ffmpeg location; Reset to Defaults.
- Liquid Glass on macOS 26+ for the wheel and the progress window.
- Menu: Settings, Recent Conversions, Launch at Login.
- README with build, permission, signing and install instructions.

## v0.2 — 2026-09-29

- **Video**: MP4, MOV, GIF, M4A (soundtrack) and MP3.
- **Audio**: MP3, M4A, WAV, AIFF and FLAC.
- **PDF**: pages to PNG/JPEG/HEIC/TIFF (a folder for multi-page PDFs) and
  Smaller PDF.
- MKV, WebM, OGG and other files macOS can't open go through ffmpeg; formats
  that need ffmpeg are grayed out when it's missing.
- **Progress window** with per-file progress, cancel, show in Finder and errors.

## v0.1 — 2026-09-29

- **The working wheel**: wedges with icons and labels, a hover pop-out, and
  the middle explaining the hovered format (or "Cancel").
- **Image conversions**: PNG, JPEG, HEIC, TIFF, GIF and PDF.
- Mixed files show only the formats valid for all of them.
- Results are saved next to the original and never overwrite anything.

## v0.0 — 2026-09-29

- Menu-bar app with its own icon.
- Accessibility permission welcome window.
- Shift-drag detection and an empty wheel at the pointer that stays on screen.
