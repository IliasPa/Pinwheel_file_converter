# Changes

What changed in each version of Pinwheel. Newest first. Each version has a
matching git tag (for example `v0.4`).

## v1.10 (beta) — 2026-10-24

**New**
- **PDFs into PowerPoint you can edit.** Each page becomes a slide with its
  words in text boxes (their font, size, color, bold and italics, line
  spacing and alignment kept), its pictures set on top, to be moved, and
  the rest of the page (colors, shapes) underneath. Scanned and turned
  pages stay a picture, and Settings › Wheels › Formats › PDF › Pages as
  pictures makes every slide a picture, as before.

**Changed**
- **PDFs into Excel, table by table:** each table is a sheet of its own
  ("Page 2, table 1"). Ruled tables (lines between the cells, as most
  invoices and reports have) are read from their lines, so rows, columns
  and cells whose words wrap come out right. Numbers become numbers
  whichever way they're written: "1.250,00", "1,250.00", "€ 1 250", and
  "(300)" for −300. A PDF without tables still gets a sheet per page, and
  tables on scanned pages are read with text recognition.
- Ruled tables come out better in PDFs into Word, Pages and EPUB too.

## v1.9 (beta) — 2026-10-24

**New**
- **Animations keep moving.** An animated GIF (or animated PNG, WebP or
  HEIC) stays animated as GIF, PNG (an animated PNG), HEIC (an image
  sequence) and WebP (with Homebrew's webp tools); before, only its first
  frame was kept. AVIF, JPEG, TIFF and the rest still get the first frame.
- **Animated pictures into videos:** MP4 (made by macOS, often 10 times
  smaller than the GIF) or WebM (with ffmpeg; see-through parts kept). The
  two wedges show only for pictures that move.
- **Videos into animated WebP:** full colors and much smaller than a GIF,
  at the GIF settings (size, frames per second, length). It needs ffmpeg
  and Homebrew's webp tools.

**Changed**
- **PDFs into Word, Pages, EPUB, Markdown and HTML keep their pictures,**
  each where it was on the page, and the text's **colors** and **small
  print**. Pages set in **two columns** stay in two columns in Word and
  Pages. A logo repeated at the top of every page is left out, as
  repeated headers and page numbers already were.

## v1.8 (beta) — 2026-10-24

What the yellow ticks in Settings › Compatibility lost, kept.

**Changed**
- **RTF keeps its pictures,** written the way Word writes them, so Word,
  LibreOffice and Google Docs show them (TextEdit still doesn't: macOS
  leaves pictures out of RTF). Pictures in an RTF made by Word are kept
  too when it becomes something else.
- **A CSV or TSV for every sheet:** a workbook with several sheets becomes
  a folder with a file for each, named after the sheet (before, only the
  first sheet was kept).
- **Subtitles keep their look:** WebVTT into SRT keeps bold, italics,
  underlines and colors (from its style too), and where each subtitle
  goes on the screen (top, middle or bottom; left or right), and SRT into
  WebVTT keeps the place. Subtitles into text can keep each one's time
  (Settings › Wheels › Formats › Subtitles).
- **Sound loses as little as it can:** sound that was already compressed
  keeps at least its bit rate in MP3, OGG, Opus, WMA and M4A (a 320 kbps
  MP3 into Opus was 128 kbps before), and Opus goes between .opus and
  .ogg as it is, not compressed again.
- **JPEG's background, your choice:** see-through parts get the color in
  Settings › Wheels › Formats › JPEG (white, as before, unless you change
  it). Compress, Size Limit, the image editor and Collage use it too.
- **GIFs without bands:** a picture becomes a GIF in the 256 colors that
  suit it best, mixed finely (dithered), so skies and shadows stay smooth;
  see-through parts stay see-through.
- **Markdown's pictures in a folder:** a document with pictures becomes a
  Markdown file and a folder beside it ("Notes pictures"), linked from the
  text; most Markdown apps didn't show pictures kept inside the text.
- **Tables line up in plain text,** in columns, with a line under the
  header.
- **Fewer yellow ticks:** what a format holds by its nature isn't a loss
  (icons up to 256 × 256, plain text, compressed sound into lossless).

## v1.7.8 (beta) — 2026-10-24

**New**
- **One Wheels page in Settings,** in place of Wheel, Conversions and
  Tools. The three wheels (Formats ⇧, Tools ⌥⇧, File actions ⌃⇧) and
  their keys stay at the top while the page scrolls; click one to see
  its settings below, one kind of file at a time. As for formats, a
  tool's settings are right under its switch: picture quality under
  Compress and the size under Resize for pictures, video quality and size
  for videos, the bit rate for audio; and under Terminal, the app it opens
  in. Searching for a tool or a file action opens its wheel.
- **A fresher icon:** frosted blades, and the one picked slid out in
  color, as the wheel shows the one you're on. Settings' Wheels page has
  the menu-bar icon.

**Changed**
- **Quick buttons look like buttons:** outlined, they light up in your
  accent color when you point at them (with a pointing hand), and more
  when pressed.
- **The clipboard's filters show only what has copies:** no Images or
  Files chip until you copy one, and Favorites and your collections only
  with something in them. While you drag a copy, the empty ones show, so
  you can drop it on them; a collection you just made shows too.
- **Favorites sits with the collections,** just before New.
- **Appearance and Wheel feedback are in General** (the glass, the
  click sound and the trackpad vibration).

## v1.7.7 (beta) — 2026-10-23

**New**
- **Straighten snaps to level.** In the image editor, the angle is pulled
  to 0° when you drag it near (with a light tap on the trackpad), and a
  notch marks the middle.
- **Yellow ticks** in Settings › Compatibility: the conversion works, but
  something is lost, and pointing at it says what ("PNG → JPEG:
  see-through parts become white", "XLSX → CSV: only the first sheet",
  "MP3 → M4A: it was already compressed", "MP4 → GIF: no sound"…).
- **Bare Link**, a quick button for links: the link with nothing after
  "?" or "#", for extras no list knows about.

**Changed**
- **Text reading has a helper of its own.** Reading text in a picture,
  QR codes and barcodes (the clipboard's Text in Image and Read Code, the
  Read Codes tool, Blur Faces/Text) needs Apple's text engine, which takes
  tens of megabytes. It now runs in a small helper that quits a minute
  after it was last used, and its memory goes back to macOS; Pinwheel
  itself stays around 30 MB.
- The first time a new version reads text, macOS takes about 40 seconds
  to get the engine ready. Pinwheel now does that once, in the background,
  half a minute after starting, so your first screenshot is read at once
  (this was why Text in Image could seem not to appear).
- **Text in Image reads photos.** With text recognition on Automatic and
  Greek installed, pictures were read only by Tesseract, which finds little
  or nothing in photos. Now a picture is read by Apple's text recognition
  too, and the better reading is kept: Tesseract's for Greek, Apple's for
  photos. Pictures already in the history are read again, and one that
  couldn't be read is tried again later instead of counting as having no
  text. (Get Text on a picture works the same way.)
- **Clean Links knows many more trackers,** with lists for LinkedIn,
  Facebook, TikTok, Instagram, X, Reddit, Amazon, Google, Bing, eBay and
  AliExpress, besides utm_ and the like.
- A picture copied from a browser (the picture and its address) counts as
  a picture, so Text in Image and Read Code work on it.
- **Quicker Settings.** Conversions and Compatibility show one kind of file
  at a time (the icons at the top; searching for a format opens its kind),
  and what's installed (ffmpeg, Tesseract, Pages…) is looked up once
  instead of for every row: opening Settings is about 40% quicker, and
  those two pages 2–4 times. A closed Settings window is kept for a
  minute, so opening it again is instant.
- The clipboard history appears at once, without fading in.

## v1.7.6 (beta) — 2026-10-23

**Changed**
- **Quick buttons show only when they'd do something:**
  - **Text in Image** and **Read Code**: a copied picture (or picture file)
    is read once, in the background, right after it's copied. The buttons
    then show only when there are words, or a QR code or barcode, in it,
    and they paste at once instead of reading the picture then.
  - **Tidy Spaces** keeps indents and tabs (code, cells copied from a
    spreadsheet) and no longer shows for a copy that just ends with a line
    break. **One Line** shows only for two lines or more.
  - **Clean Links** also cleans links written without https://
    (www.example.com/…?utm_source=…).
- The quick buttons take the first click even when the anchored history
  isn't in front, look pressed when clicked, and VoiceOver can find and
  press them. **Aa** opens a regular menu.
- Settings › Clipboard: the switch is just **Quick buttons**.
- **Faster.** With 1,000 copies, moving the pointer over the list is about
  10 times quicker, a search about 5 times, and the history opens in
  5–10 ms (the first time after Pinwheel starts, in about 65 ms: it's
  prepared a moment after launch). Pictures, file icons and texts in the
  list are read from disk once, not on every redraw.

**Fixed**
- Anchored, a quick button pressed just after a paste only copied.

## v1.7.5 (beta) — 2026-10-22

**New**
- **Your own collections** in the clipboard history: copies put together
  under a name ("Work", "Addresses", "Replies"), kept for good like
  favorites. Click **New Collection** under the filters and type a name.
  Put a copy in one by **dragging it onto the collection**, or
  right-click it › Add to Collection (a tick shows which it's in; New
  Collection… makes one for it). Click a collection to see just its
  copies. Right-click a collection to rename or delete it (its copies stay
  in the history). A copy's row says which collections it's in.
- Drag a copy onto **Favorites** to make it a favorite.
- Clear History keeps the copies in collections, as it keeps favorites.

## v1.7.4 (beta) — 2026-10-22

**New**
- **Quick buttons under each copy** in the clipboard history. Click one
  and the copy is pasted changed that way (and kept in the history too):
  - **Plain Text**: without its formatting.
  - **Clean Links**: links without their tracking (utm_source, fbclid,
    gclid, YouTube's si…); what the link needs stays.
  - **One Line**, **Tidy Spaces** (no doubled spaces or extra blank
    lines), and **Aa**: UPPERCASE, lowercase, Title Case, Sentence case
    (Greek too: ";" ends a question there).
  - **Text in Image**: the words in a picture or screenshot, read on this
    Mac. **Read Code**: what a QR code or barcode in it says.
  - **Path** and **Name** of copied files.
  A button shows only when it would change something. Settings ›
  Clipboard › Quick buttons under each copy switches them off.
- An anchored history that's behind another app takes your first click.
- A picture's text that's still being read when you close the history is
  only copied, not pasted into whatever app is in front by then.

**Fixed**
- Anchored, a history closed right after choosing a copy could come back.

## v1.7.3 (beta) — 2026-10-22

**New**
- **See all of a copy:** press and hold one in the clipboard history, or
  press **Space**, and it opens big: the whole text (to read or select),
  the whole picture, or files as Quick Look shows them (documents,
  pictures, films). ↑↓ go through the copies, Return pastes, Space or Esc
  goes back. Settings › Clipboard › Preview a copy with: press and hold,
  Space, or both. (While you type a search, Space is a space.)
- **Drag a copy into any app.** It leaves its row as a dashed outline and
  rides along on a card that leans into the drag; over other apps the
  history fades so you see where it goes. Drop it, and the window goes as
  after a paste (anchored, it stays and the row says "Dropped"); let go
  elsewhere, and the card flies back. It arrives just as it was copied:
  formatted text, pictures, files.
- The right-click menu has Preview.

## v1.7.2 (beta) — 2026-10-22

**New**
- **An anchor** at the bottom of the clipboard history, next to its
  settings: anchored, the window stays open while you use other apps, and
  after you choose a copy (it steps aside for the paste, then comes back).
  Esc or the shortcut still closes it.
- Settings › Clipboard says what's coming: password and encryption
  features, in a future update.

**Changed**
- Each choice of how many copies to keep reads like "200 copies · ~24 MB":
  whole numbers, since it's an estimate.

**Fixed**
- A dark line ran around the clipboard history window. macOS drew it
  around the window's shadow, and the window was taller than its glass;
  now the window is just the glass, with a soft shadow of its own.

## v1.7.1 (beta) — 2026-10-22

**New**
- **Choosing a copy pastes it where you're typing.** Click one (or press
  Return) and the history closes and pastes it into the app you were in,
  as ⌘V would. Prefer to paste yourself? Settings › Clipboard › When you
  choose a copy › Just copy it. Pasting uses the Accessibility permission
  Pinwheel already has; without it, choosing a copy only copies it.
- **How much room the history takes:** each choice of how many copies to
  keep says about how much space that is (worked out from your own copies:
  screenshots take far more room than text), and the page shows what the
  history uses now.

**Fixed**
- Blur Faces/Text and Read Codes could stall when the Mac was very busy
  (and the tests on GitHub did): Vision now works on a thread of its own,
  and reading text that fails because the Mac is busy is tried again.

## v1.7 (beta) — 2026-10-21

A clipboard history.

**New**
- **Clipboard history** (beta): press **⌥⌘V** in any app. What you copied
  is there, newest first, with the app it came from and when; filter by
  kind (text, links, images, files), by app, or type to search. **Click
  one, or press Return, and it's copied at once**: the window closes and
  you paste where you were (Pinwheel doesn't take over the keyboard of the
  app you're in). ↑↓ choose, ⌘⌫ removes one, Esc closes.
- **Favorites:** a heart keeps a copy for good; the Favorites filter shows
  just those. The rest go after the last 200 copies (or 50 to 1000).
- Copies come back exactly as they were copied: formatted text stays
  formatted, pictures stay pictures, files stay files.
- **Settings › Clipboard:** on or off, **your own keys** (click, then press
  them; ⌥⌘V again in one click), how many copies to keep, Clear History
  (favorites stay). If another app already uses the keys, it says so.
- Kept only on this Mac. What password managers and other apps mark as
  private is never kept.
- Menu-bar icon › **Clipboard History**.

## v1.6 — 2026-10-21

Cut, crop and bleep; a visualizer; faces and text blurred out; a shelf.

**New**
- **The video and audio editor** cuts the part into pieces (Split Here, or
  S, at the playhead: each piece is saved on its own, in a folder), crops
  videos (1:1, 4:5, 9:16, 16:9 or 4:3; drag the box over the video), bleeps
  words (Bleep Here, or B: a beep, or silence, for half a second to three
  seconds) and mixes the channels (mono, stereo from mono, or just the left
  or right side, for a voice recorded on one side). Saved frames and GIFs
  are cropped too.
- **Visualizer…** (audio's tools wheel): the sound becomes an MP4 with
  bars (its pitches) or a wave moving to it, over a picture or a gradient,
  square, wide or tall, with the file's name or your own title. Made by
  macOS itself: no ffmpeg needed (except to read OGG, Opus and WMA).
- **Blur faces and text:** the image editor's Markup finds every face, or
  all the text, and blurs it out (each blur can then be moved or deleted).
  **Blur Faces & Text** does it in one go, on the wheel (switch it on in
  Settings › Tools) and as a custom action step.
- **The shelf:** a small floating window to park files on mid-drag. Drop
  files on the new **Shelf** file action (⌃ Control + ⇧ Shift) or on the
  shelf itself; drag them off later, all at once as a pile or one by one.
  It stays above other windows without taking the keyboard from Finder,
  and remembers its files. Menu-bar icon › **Shelf**.
- Custom actions: **Mono** and **Blur Faces & Text** steps.
- The `pinwheel` command: `blur`, `shelf`, and `open visualizer`.

## v1.5.1 — 2026-10-21

**Fixed**
- **The wheel no longer misses wedges or flickers while you drag over it.**
  macOS hands the pointer to the window underneath wherever a window draws
  nothing, and the glass wheel drew nothing between its blades, around the
  middle, in the margin around it, and (with Liquid Glass, the standard
  look) on most of each blade, because macOS draws that glass itself. Over
  those spots the drag went to Finder: the wedge lost its highlight, ticked
  again a moment later, and a drop there could land in the folder behind
  the wheel. An invisible disc now keeps the whole wheel and its margin
  under Pinwheel's control.
- **Wedges light up exactly under the pointer.** The wheel was drawn
  14 points lower than the spot its wedges were measured from (the room of
  the hidden title bar), so near the middle and between wedges the pointer
  could count for a neighbour, or for Cancel.
- Switching wheels with the keys lights up the wedge under the pointer
  right away, without waiting for the pointer to move.

## v1.5 — 2026-10-21

Documents, spreadsheets, slides and subtitles.

**New**
- **PDFs into documents you can edit:** Word, Pages, EPUB, Markdown and
  text, with the headings, paragraphs, lists and tables put back together
  (lines joined, words broken at line ends mended, page numbers and
  repeated headers left out; scanned pages read with text recognition). Or,
  in Settings › Conversions, each page as a picture, so it looks exactly
  the same. **PDF → Excel** puts the tables on each page in a sheet;
  **PDF → PowerPoint** makes a slide of each page.
- **Documents:** Word (.docx, and old .doc), Pages, RTF, ODT, Markdown,
  text, web pages and EPUB books become any of PDF, Word, Pages, RTF, ODT,
  Markdown, text, HTML and EPUB. Headings, bold and italic, links, lists,
  quotes, code, tables and pictures come along.
- **Spreadsheets:** Excel, Numbers, ODS, CSV, TSV and old .xls become
  Excel, ODS, CSV, TSV or PDF (each sheet a table, the first row repeated
  on every page). Dates, numbers and leading zeros stay as they were; CSVs
  with semicolons and decimal commas are read right.
- **Slides:** PowerPoint and Keynote files become PDF, PowerPoint, or a
  folder with a picture of each slide.
- **Subtitles:** SRT and WebVTT become each other, or just their words.
- Pages, Keynote and Numbers (free on the App Store) are used for what only
  they can open or make; the wedges say so when one isn't installed, and
  macOS asks once whether Pinwheel may use each. Word, Excel, PowerPoint,
  EPUB and OpenDocument files are written by Pinwheel itself.
- The `pinwheel` command: `convert word`, `excel`, `powerpoint`, `epub`,
  `md`, `srt`, `vtt`… for every new format.

## v1.4 — 2026-10-21

Your own keys, a file actions wheel, archives, and many more formats.

**New**
- **Choose each wheel's keys** (Settings › Wheel › Keys): any of ⌃ ⌥ ⇧ ⌘
  for the formats, tools and file actions wheels. A wheel opens with
  exactly its keys; two wheels with the same keys get a warning. The wheel
  can **stay open** after you let go of the keys, until you drop or press
  Esc.
- **The keyboard on the wheel:** ← → (or ↑ ↓) choose, Return applies, Tab
  switches wheels, Esc closes. Returning during a drag does the job at once,
  and the drop when you let go is taken in quietly, so Finder doesn't move
  the files too.
- **File actions wheel** (⌃ Control + ⇧ Shift), for any files and folders:
  AirDrop, Copy (to paste in Finder), Move To… (undoable from the menu bar,
  never replacing anything), Copy Path, Terminal (in their folder, in the
  Terminal app you choose), Quick Look, and ZIP. Also in Finder's
  right-click › Services › **Pinwheel File Actions**.
- **Archives:** ZIP, RAR, 7Z, TAR, TAR.GZ and single .gz, .bz2 and .xz
  files are **extracted** into a folder, or repacked as ZIP, TAR, TAR.GZ or
  7Z. Archives are made without the Mac's hidden extras (the "._" files and
  .DS_Store), so they open cleanly anywhere. Locked archives say so.
- **Pictures:** WebP (with cwebp: `brew install webp`), AVIF, BMP, and
  icons: ICO (6 sizes, for Windows) and ICNS (16 to 1024 pixels, made with
  Apple's iconutil). WebP and AVIF have their own quality.
- **SVG drawings** convert like pictures (2048 pixels across), and stay
  drawings in a PDF.
- **Video:** MKV (copies the picture and sound when it can: quick and
  lossless), WebM (VP9 and Opus), AVI and WMV. **Audio:** OGG, Opus, WMA.
  All with ffmpeg.
- **Read Codes…** for pictures: QR codes and barcodes, with Copy and Open.
  Switch it on in Settings › Tools (the pictures' tools wheel is full).
- The format wheel holds up to **12** wedges; pictures get all eleven
  formats and Collage.
- The `pinwheel` command: `zip`, `extract`, `show actions`, `open codes`,
  and every new format (`convert webp`, `convert tar.gz`…).

**Changed**
- Settings › Compatibility shows a table for each kind of file (pictures,
  PDFs, videos, audio, archives), each with what that kind can become; the
  ticks say when ffmpeg or cwebp is needed and missing.

## v1.3 — 2026-10-21

**Fixed**
- **Liquid Glass now looks like Liquid Glass on the desktop.** macOS draws
  the glass of a window that isn't the active one frosted, and the wheel's
  window never is (Finder is busy dragging), so every glass level looked
  frosted, even Crystal. The wheel and the progress window now tell macOS
  they look active, without taking the keyboard from Finder: the glass is
  clear and bends what's behind it at the edges. Found by capturing the
  glass side by side in active and inactive windows on macOS 27.

**Changed**
- **The glass wheel has nothing behind it** (glass levels 2 to 5): each
  wedge is a blade of Liquid Glass with its icon and label, and the middle
  is a glass circle. The chosen blade slides out, glass and all. The thin
  lines between wedges are gone; the gaps between blades do that now.
- **Crystal** (level 5) leaves out the circle in the middle too: just its
  words. Frosted (level 1) keeps its classic disc.
- **Settings › Compatibility:** MP3 comes before M4A, as in the rows, so
  the dashes run straight down.

**New**
- **Trackpad vibration: Off, Low or High** (Settings › Wheel). Low is a
  light tap, High the firm one from before; choosing one plays it. If
  vibration was on, it's now High; if it was off, Off.

## v1.2 — 2026-10-20

Settings, rearranged: a page for each part, a table of what converts to
what, and a choice of formats for each kind of file.

**New**
- **Settings has a sidebar** with a page for each part (General, Wheel,
  Conversions, Compatibility, Tools, Text Recognition, Finder & Shortcuts,
  Advanced) and a search field that finds the page for a word ("jpeg",
  "greek", "ffmpeg"). General shows a warning while the Accessibility
  permission is missing.
- **Settings › Conversions:** for pictures, videos, audio and PDFs, switch
  each format on or off the ⇧ Shift wheel (Collage too), with that
  format's settings right under it: JPEG and HEIC quality, one combined
  PDF, GIF width, frame rate and length, PDF page resolution.
- **Settings › Compatibility:** every kind of file Pinwheel reads (22,
  from PNG to OGG) against every format it writes (13): ✓ when it
  converts, – when it's the same format. Ticks for formats switched off
  are gray, and orange when they need ffmpeg and it isn't installed.
  Pointing at a box says what it means. The table is worked out from the
  wheels themselves, so it can't fall behind them.

**Fixed**
- Switching Compress off the PDF tools wheel also took **Smaller PDF** off
  the PDF format wheel: both wheels shared one list of hidden wedges.
  Each wheel now has its own.
- An **M4A** file was offered M4A on its own wheel (and made a copy of
  itself): macOS calls .m4a files a kind of MPEG-4 audio that Pinwheel
  didn't match.
- **AVI** wedges looked usable without ffmpeg and then failed: macOS lists
  AVI as a movie type but can't open one. AVI files now go straight to
  ffmpeg, and without it their wedges are gray and say "Needs ffmpeg".

**Moved**
- Compress and Resize settings are in **Tools**, with the tools wheel.
- The format qualities (JPEG, HEIC, GIF, PDF pages) are in
  **Conversions**, under their format.
- Opening at login is in **General**; files at the same time, ffmpeg and
  **Reset to Defaults** are in **Advanced**.

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
