# Recording the 30-second video

The video for the website (`docs/index.html`, the "Pinwheel in 30 seconds"
section). Three short shots and an end card, recorded one at a time and cut
together. No voice: captions say what the keys are.

| Time | Shot | Shows |
|---|---|---|
| 0:00–0:09 | 1. Three photos into JPEG | ⇧ Shift: the format wheel |
| 0:09–0:17 | 2. A 73 MB video under 25 MB | ⌥ Option + ⇧ Shift: the tools |
| 0:17–0:26 | 3. A PDF into Excel | Tables come out as tables, numbers as numbers |
| 0:26–0:30 | 4. End card | Name, "Free and open source", the link |

The wheels, wedges and windows in these steps are the same in Pinwheel 1.7
(the download) and 2.0, so record with whichever is in /Applications. To record a fresh build of main,
`make install` first.

## 1. Make the sample files

```sh
scripts/demo/make-files.sh            # → ~/Desktop/Pinwheel Demo
scripts/demo/make-files.sh ~/Movies/Pinwheel\ Demo   # or anywhere else
```

It needs ffmpeg and takes about 10 seconds. **Run it again before every
take**: it deletes and remakes the folder, so the converted files from the
last take are gone. It only ever deletes a folder it made itself (a hidden
`.pinwheel-demo` file marks it); any other folder with that name is left
alone and the script stops.

| File | What it is | Used in |
|---|---|---|
| IMG_4021.HEIC, IMG_4022.HEIC, IMG_4023.HEIC | 12 MP photos (Oia, a lighthouse, a sunset) with the date taken and the place | Shot 1 |
| IMG_4107.MOV | 15 s of a boat at sea, 1080p HEVC like an iPhone's, about 73 MB, with the sound of waves | Shot 2 |
| Santorini guide.pdf | Two pages: headings, a picture, a ferry timetable and a budget table | Shot 3 |
| Podcast intro.wav | A 27-second spoken intro over a soft chord | Spare: Visualizer…, MP3 |
| Trip notes.docx | Headings, a bulleted list and a table | Spare: PDF, Pages |
| Budget.xlsx | A sheet with dates, euros and a SUM | Spare: PDF, CSV |
| Photos.zip | The three photos | Spare: Extract |

The photos and the video show the same drawings as the website's demo, so
the page and the video look like one thing. If you put the files in a folder
that iCloud or OneDrive syncs, Finder shows cloud badges on every icon:
the Desktop is fine unless "Desktop & Documents Folders" is on in iCloud.

## 2. Set up the Mac

**Screen**
- Turn on Do Not Disturb (Control Center › Focus).
- Pick a calm blue or purple wallpaper (the website's demo uses blue to
  purple). Hide the desktop icons if the Desktop is busy:
  `defaults write com.apple.finder CreateDesktop false; killall Finder`
  (put them back with `true`).
- Make the pointer a little bigger so it reads on a small video: System
  Settings › Accessibility › Display › Pointer size, one or two steps.
- Quit anything that might pop up (Mail, Messages, updates).

**Finder**
- Open the Pinwheel Demo folder. View › as Icons, View › Show View Options:
  icon size 96, Sort By Name, no groups.
- Finder Settings › Advanced › **Show all filename extensions** on, so
  viewers see `.HEIC` become `.jpg`.
- Put the window on the left half of the area you'll record and leave the
  right half empty: that's where the wheel opens.

**Pinwheel** (Settings › General)
- After converting: **Show the progress window** on; **Show the new files
  in Finder** off (Finder would jump); **Move the original to the Trash**
  off.
- Appearance: Liquid Glass (the default) looks best on Tahoe. Frosted
  matches the website's demo, if you'd rather they look the same.
- Check the keys in Settings › Wheels are the standard ones: ⇧ for formats,
  ⌥⇧ for tools.
- Do one practice conversion first, so nothing asks for a permission (Excel,
  Keynote) in the middle of a take.

**Showing the keys**
Viewers can't see what you press. Either run
[KeyCastr](https://github.com/keycastr/keycastr) (free:
`brew install --cask keycastr`, set it to show modifier keys only, bottom
left), or add the captions below while editing. Captions alone are enough.

**Recording**
Press ⌘⇧5, choose **Record Selected Portion**, and draw a 16:9 area around
the Finder window and the empty space beside it (for example 1600 × 900 on
a Retina screen). Options › Show Mouse Clicks: off (the drags read better
without circles). Record each shot as its own clip.

## 3. The shots

Rehearse each shot two or three times; slow, steady movements read best.
Leave half a second of stillness at the start and end of every clip for the
cuts.

### Shot 1: three photos into JPEG (0:00–0:09)

Caption: **Drag. Hold ⇧ Shift. Drop.**

1. Draw a selection rectangle around the three IMG_402… photos.
2. Press on one of them and start dragging toward the empty right side.
   After about a second of moving, **press and hold ⇧ Shift**: the wheel
   opens under the pointer.
3. Glide onto **JPEG** and stay there a full second: the middle reads
   "Small files, works everywhere".
4. Let go of the mouse, then of Shift. The progress window (top right)
   says "Converting 3 files…", then "All done", and three
   "IMG_402… (converted).jpg" files appear in the folder.
5. Hold still a second on the result.

### Shot 2: a 73 MB video under 25 MB (0:09–0:17)

Caption: **⌥ Option + ⇧ Shift: the tools**

1. Start dragging IMG_4107.MOV to the right, then **hold ⌥ Option and
   ⇧ Shift**: the tools wheel opens (Compress, Size Limit…, Strip Info,
   Get Audio, Mute, Edit…, Info…, Rename…).
2. Glide onto **Size Limit…** (the middle reads "Under a size you choose,
   like 10 MB for email") and let go.
3. The Size Limit window asks "How big may it be?". Click **25 MB, Gmail**,
   then **Make Smaller**.
4. The progress window shows the sizes, about 73 MB → 19 MB, and
   "IMG_4107 (under 25 MB).mp4" appears. (It takes about two seconds.)

### Shot 3: a PDF into Excel (0:17–0:26)

Caption: **PDFs into Word or Excel, tables and all**

1. Start dragging "Santorini guide.pdf", **hold ⇧ Shift**, glide onto
   **XLSX** (the middle reads "Excel, the tables on each page") and let go.
2. Double-click "Santorini guide (converted).xlsx". Excel opens with the
   ferry timetable on the first sheet (the budget is on the next one).
3. Select the Price (€) cells: Excel's status bar shows their Sum, which
   proves they're numbers. Hold still a second and a half.

Cut out Excel's launch while editing. If you'd rather show Word: the same
PDF dropped on **DOCX** gives the headings, the bullets and both tables as
text you can edit.

### Shot 4: end card (0:26–0:30)

The Pinwheel icon (`Support/AppIcon.icns`, or the top of the website) on the
same blue-purple background, with:

> **Pinwheel**
> Free and open source · for macOS
> github.com/IliasPa/Pinwheel_file_converter

### Spare shots, if one doesn't work out

- **File actions:** drag the photos with ⌃ Control + ⇧ Shift and drop on
  AirDrop or Quick Look.
- **Rename…:** the three photos, ⌥⇧, Rename…: number them "Santorini 1, 2, 3"
  with the live preview.
- **Visualizer…:** "Podcast intro.wav", ⌥⇧, Visualizer…: a video of bars
  moving to the voice.
- **Undo:** the menu-bar wheel › Undo: the new files go to the Trash.

## 4. Edit and export

- Cut the clips together (iMovie, Final Cut, or QuickTime's Edit › Add Clip
  to End). Trim waits; speed up a slow progress bar rather than cutting it.
- Captions: system font, white, bottom center, a soft shadow, about 1.5 s
  each, starting as the keys go down.
- Music is optional. With the player's controls (step 5), the video plays
  only when someone presses play; as a silent loop, nobody hears it.
- Export at 1920 × 1080. Then make the copy for the website. Use H.264, not
  HEVC, so it plays in every browser, and keep it under about 10 MB, since
  it lives in the git repository:

```sh
ffmpeg -i "Pinwheel demo.mov" -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p \
  -movflags +faststart -an docs/pinwheel-demo.mp4
ffmpeg -ss 2 -i docs/pinwheel-demo.mp4 -frames:v 1 -q:v 3 docs/pinwheel-demo.jpg
```

(Drop `-an` if you added music; raise `-crf` to 26–28 if the file is too
big.)

## 5. Put it on the page

In `docs/index.html`, find `<div class="video-ph">` in the "Pinwheel in 30
seconds" section and replace that whole `<div>…</div>` with:

```html
<video src="pinwheel-demo.mp4" poster="pinwheel-demo.jpg" controls playsinline preload="metadata"></video>
```

For a silent loop that plays by itself instead, use
`autoplay muted loop playsinline` in place of `controls`. Commit
`docs/pinwheel-demo.mp4`, `docs/pinwheel-demo.jpg` and the page, and push:
GitHub Pages updates in a minute or two.
