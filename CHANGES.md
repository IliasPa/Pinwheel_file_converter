# Changes

What changed in each version of Pinwheel. Newest first. Each version has a
matching git tag (for example `v0.4`).

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
