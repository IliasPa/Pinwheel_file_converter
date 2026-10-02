# Changes

What changed in each version of Pinwheel. Newest first. Each version has a
matching git tag (for example `v0.4`).

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
