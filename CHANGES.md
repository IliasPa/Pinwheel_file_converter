# Changes

What changed in each version of Pinwheel. Newest first. Each version has a
matching git tag (for example `v0.4`).

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
