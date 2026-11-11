# Plan — seven additions (2026-11-11)

Bryan's request, verbatim where it matters:

1. "make the volume of apps feature more immersive, such as set specific percentage of volume per app, boost quiet audio past 100%"
2. "add this as a setting: three-finger click acts as middle click"
3. "Scans for leftovers from uninstalled apps, caches, logs and the Trash. You review everything first and removed items go to the Trash. also add a feature in the menu bar."
4. "click on something in the menu bar and then … open up a menu where you can convert files into different files sort of like the tangerine for macapp … copy features from that … also add a compress feature to this menu … settings on the compression about like how much it compresses and then, for example, for an image you can switch from JPEG PNG HEIC PDF etc."
5. "add screen recording and saving as an mp4 as well as scrolling screenshots as features. make sure theyre well executed"
6. README: list all of this, plus "the Scrolling Strip, auto clicker, word counter, archives, and corner right-click. Tutto is also 8 MB … and MIT."
7. "plan it all out super thoroughly and make everything well executed"

Standing rules that apply: native frameworks only (Tutto is 8 MB; no ffmpeg, no bundled GPL tools), nothing runs while a tool is idle, every tool can be switched off, no third-party app names in Tutto's UI or docs, MIT code only (the GPL projects below are studied for behaviour, not copied).

## 1. Research (read 2026-11-11)

| Source | What it is | Its genius, in one line | Taken |
|---|---|---|---|
| [Tangerine site](https://tangerineformac.com/), [tools](https://tangerineformac.com/tools), [App Store](https://apps.apple.com/us/app/tangerine-file-converter/id6813034065) (v2.0.4, Leap Studio, 68 MB, free for 20 files) | Offline converter that lives in the menu bar | Start dragging a file, tap ⇧, and a wheel of formats opens at the pointer; drop on one and the copy lands beside the original | The drag-and-tap wheel, output beside the original, a small progress window, reveal in Finder, compress to a target size or percentage with resize, merge PDFs, images → one PDF. Users: "had it done before I would've even found a site", files never leave the Mac; asked for more formats (DNG, HEIF) |
| [FineTune](https://github.com/ronitsingh10/FineTune) (GPL-3.0, 10.1k★, 2026-07) | Per-app volume in the menu bar | A slider per app plus boost presets (2×–4×), scroll-wheel on any slider, ignore-app tears the tap down | Per-app percentage, boost past 100 %, scroll to adjust, no tap for apps left alone |
| [HN 47843665](https://news.ycombinator.com/item?id=47843665) (2026-04) | User comment on per-app volume tools | Complaint: a permanent purple dot while a tool intercepts audio | Tap an app only while its level isn't 100 % **and** it is playing (tap auto-start); say so in the UI |
| [MiddleClick](https://github.com/artginzburg/MiddleClick) (GPL-3.0, 2.9k★) + [its retirement issue](https://github.com/artginzburg/MiddleClick/issues/174) (2026-08) | Three-finger click/tap → middle click | Exactly three fingers by default; most-requested feature was a real middle *drag* (CAD pan/orbit); reliability after wake | Exactly three fingers, a true middle drag, the existing stale-touch-stream recovery |
| [HN 46241021](https://news.ycombinator.com/item?id=46241021) (2025-12) | Show HN: three-finger middle drag | CAD users (FreeCAD, Onshape, Fusion) need middle-drag; other fixes cost money or disable Mission Control | Physical click only, so swipes and Mission Control keep working |
| [Mole](https://github.com/tw93/Mole) (GPL-3.0, 74.6k★) + [SECURITY_AUDIT.md](https://github.com/tw93/Mole/blob/main/SECURITY_AUDIT.md) (2026-11-10) | Mac cleaner | Skips whatever it can't prove safe | Path validation (absolute, no `..`, no control characters, symlinks resolved and kept inside the scanned root), never a cache whose owner is running, a sibling-install guard, app data = personal |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner) (fair-code, 15.1k★, on hold) | App cleaner with orphaned-file search | Needs Full Disk Access; adjustable match strictness | Ask for Full Disk Access with a clear partial result without it; strict vs probable matches |
| [HN 46989335](https://news.ycombinator.com/item?id=46989335) (2026-02) | "System Data was 220 GB" | CleanMyMac barely moved it; AI and developer tools (Claude Desktop, Cursor, uv, Playwright) hide gigabytes in `~/Library` | A Developer caches group (unchecked by default) |
| [Clop](https://github.com/FuzzyIdeas/Clop) (GPL-3.0) | Image/video/PDF optimiser | Optimise as you copy; downscale presets; aggressive mode; media-engine video | Quality presets plus exact control, downscale sizes, hardware HEVC/H.264 through AVFoundation |
| Native probe on this Mac (macOS 26.5) | What macOS encodes without bundling anything | — | Images out: JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, PDF, JPEG 2000, ICNS; in: also WebP, JPEG XL, RAW. Audio out: AAC/ALAC (M4A), FLAC, Opus (Ogg/CAF), WAV, AIFF; no MP3 encoder. Video: H.264/HEVC up to 8K. PDF: optimise-for-screen, JPEG images, "Reduce File Size" filter |

Rejected: bundling ffmpeg/ghostscript/pngquant (size, GPL), MP3/WebP/MKV/WebM output (no native encoder), DOCX↔PPTX/XLSX/EPUB (no native engine), a second menu bar icon (Tutto stays one icon; I12 in DESIGN.md), EQ and device routing (a mixer is "stressful" for something rarely used, DESIGN.md 9).

## 2. Designs

### A. Sound: a level for every app, with boost

- **Model.** A level per app (bundle ID), 0–300 %, saved. 100 % costs nothing (no tap). Muted keeps using the existing mute rig.
- **Engine (`VolumeRig`, TuttoKit/Audio).** Core Audio process tap (stereo mixdown, `mutedWhenTapped`, private) in a private aggregate device clocked by the current output device; tap auto-start, so it only runs while the app plays. The IO callback copies the app's audio to the output with a gain that ramps per buffer (no zipper noise) and, above 100 %, a peak limiter with a soft knee so boosted audio never clips. No allocation or locks on the audio thread; the level is a single float read atomically.
- **Fallbacks.** Rebuilt when the output device changes or the app gains audio processes (as mutes are). If a rig can't start, the app plays normally and the row says why.
- **UI.**
  - Panel: the Sound card opens like the clicker. Its line gets a chevron; open, each app shows a slider with its percentage, the part past 100 % tinted. Clicking an icon still mutes it. Scrolling over an icon changes its level in 5 % steps. An app that isn't at 100 % shows a thin ring around its icon.
  - Sound page: the same sliders for every app, with Reset.
- **Done when:**
  - Tests: unity passes audio through bit-exact; 50 % halves; ramps have no step larger than one buffer's change; a 300 % full-scale sine stays under the limiter ceiling.
  - Live: a quiet test tone from another process measured through Tutto's own output at 50 % and 200 %.

### B. Three-finger click is a middle click

- A switch on the Trackpad Corner page, off by default.
- With it on, a physical trackpad click made with exactly three fingers becomes a middle click: down, drags and up, so CAD apps can pan and orbit. Corner right-clicks and two-finger clicks are unchanged.
- Off automatically while macOS's three-finger drag is on (they'd fight), and the page says so.
- **Done when:** Engine tests for 3 fingers → button 2 down/drag/up, 2 or 4 fingers unchanged, off unchanged, three-finger-drag on unchanged.

### C. Clean Up

- **Scan, then review.** Nothing is selected for removal without the review list, and removal is always "Move to Trash" (recoverable). Emptying the Trash is a separate button with its own confirmation, because that is permanent.
- **Groups:**
  - **Left behind by apps you removed.** Items in `~/Library` named for a bundle ID that no installed or running app owns: Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, HTTPStorages, WebKit, Logs, Cookies, Application Scripts, and LaunchAgents whose program no longer exists. Grouped per app and checked by default. Folders named after an app (not a bundle ID) that look like an app's data store and haven't been touched for 30 days are listed as "probably left behind", unchecked.
  - **Caches.** `~/Library/Caches`, one row per app, skipping any whose app is running ("quit it to clean") and anything changed in the last 2 minutes. Checked.
  - **Logs.** `~/Library/Logs`, skipping files written in the last 10 minutes. Checked.
  - **Developer caches** (rebuild themselves but take time): Xcode DerivedData, simulator caches, package-manager caches. Unchecked.
  - **Trash.** Size, and Empty Trash… with confirmation.
- **Safety:**
  - Only the user's home.
  - `com.apple.*` is never touched.
  - Every path is checked: absolute, no `..`, inside its scanned root after resolving symlinks.
  - Nothing outside the reviewed list is moved.
  - A summary says what moved and that the space comes back when the Trash is emptied.
- **Access.** Full Disk Access is needed for containers and the Trash. Without it, the scan covers what it can and lists what it couldn't read, with a button to the setting.
- **Menu bar.** A Clean tile in the tools row opens it. Scans run only when asked.
- **Done when:** tests on a fixture home for bundle-ID matching (helpers owned by their parent app, group containers, sibling installs), path validation and the running-owner rule; a live dry scan of the real home with no changes made.

### D. Convert and compress

- **Entry points:**
  1. **Convert tile** in the panel (and a shortcut) opens a small floating window. Drop files, pick a format, or Compress with its settings.
  2. **Drag-and-tap wheel.** While dragging files anywhere, tap ⇧ and a wheel of targets opens at the pointer; drop on one. On by default, with a switch.
  3. **Finder right-click** › Convert › formats for the selection, Compress, More….
  4. **Links**: `tutto://convert?to=png&path=…`.
- **Output.** A copy beside the original ("photo.png"; "photo 2.png" if taken; "photo (compressed).jpg"), never overwriting; a progress pill; a toast with the saving and Show in Finder.
- **Formats** (native only):
  - **Images** (in: anything ImageIO reads, incl. HEIC, WebP, AVIF, RAW, PDF pages) → JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, PDF; several images → one PDF.
  - **Video** (MOV, MP4, M4V…) → MP4 (H.264 or HEVC), MOV, GIF, M4A (sound only).
  - **Audio** → M4A (AAC), M4A lossless, WAV, AIFF, FLAC, Opus.
  - **PDF** → PNG/JPEG pages, text; several PDFs → one.
  - **Documents** (DOCX, DOC, RTF, ODT, HTML, TXT, Markdown) → DOCX, RTF, ODT, HTML, TXT, PDF.
  - **Subtitles**: SRT ↔ VTT.
- **Compress settings.** The wheel and Finder use the saved defaults; the window edits them.
  - **Images:** quality (10–100, with the result's size shown), longest side (Original, 3840, 2560, 1920, 1280, 960), an optional target size ("500 KB", found by search over quality and size), and "Remove location and camera details".
  - **Video:** Small / Balanced / High, resolution cap, H.264 (plays everywhere) or HEVC (smaller).
  - **PDF:** Light (screen-optimised images) or Strong (JPEG images at 150 dpi).
  - **Audio:** bitrate.
- **Done when:**
  - Tests: format planning per kind, output naming, SRT↔VTT, the target-size search.
  - Live: offscreen runs of every image, video, audio, PDF and document path on generated fixtures, with output sizes recorded.

### E. Screen recording → MP4 (macOS 15+)

- **Start.** ⌃⇧R or the Record tile opens the area picker: drag an area, click a window, or press Space for the whole screen. A 3-2-1 countdown follows; Esc cancels.
- **While recording:**
  - Tutto's menu bar icon shows a red dot and the time.
  - A dashed outline marks the area; it is left out of the video.
  - ⌃⇧R again, or Stop in the panel, ends it.
- **Engine.** ScreenCaptureKit stream of that display, cropped to the area at native resolution, 60 fps, cursor shown. `SCRecordingOutput` writes MP4 (H.264 by default, HEVC as an option), with system audio and/or the microphone as chosen on the page. Tutto's own windows are excluded.
- **After.** Saved where screenshots go, as "Recording 2026-11-11 at 05.12.04.mp4". A floating thumbnail you can drag into any app, with Show in Finder, Copy and Make GIF (through the converter).
- **Done when:**
  - Live: a 3 s recording of a test window is a valid MP4 with the expected size, frame rate and duration (checked with AVFoundation).
  - The cancel and stop paths leave nothing behind.

### F. Scrolling screenshots

- **Start.** ⌃⇧S or the Scroll tile opens the area picker; choose the scrolling content.
- **Capture.** Tutto scrolls it by itself with small steps and captures each step. If the content doesn't move, it switches to "scroll yourself" and captures as you scroll. Esc stops, Return finishes, and the end of the page finishes by itself.
- **Stitching** (`ScrollStitcher`, TuttoKit):
  - Rows are matched on downsampled luminance to find each step's offset.
  - Headers and footers that stay put are found and kept once.
  - Animated regions don't throw it off (row matching is median-based).
  - Capped at 30,000 px.
- **Result.** Opens in the screenshot editor (crop, mark up, copy, save), or straight to the clipboard per the page's setting.
- **Done when:**
  - Tests on synthetic pages: plain, sticky header and footer, a blinking region, the end of the page.
  - Live: a long test page stitched with no repeated or missing lines.

### G. README

New tools in the tagline and intro (fifteen tools), a "What's inside" list (including the Scrolling Strip, auto clicker, word counter, archives and corner right-click), "8 MB, MIT", and usage, permissions and limits for every addition (Full Disk Access optional for Clean Up; Microphone for recording with it; macOS 15 for recording).

## 3. Panel and keys

- **Tools.** Two rows by kind: Area · Edit · Screen · Record · Scroll · History / Snap · Words · Convert · Clean (Customize can hide any).
- **New keys:** ⌃⇧R record, ⌃⇧S scrolling capture, ⌃⇧K convert window. Clean has no key.
- **Sound.** The card gains the opener described in A.

## 4. Cost budget (DESIGN.md "near-zero at rest")

| Feature | At rest |
|---|---|
| Volume | Nothing for apps at 100 %. For an app set otherwise, a tap that runs only while that app plays. |
| Middle click | Rides on Trackpad Corner's existing touch stream and event tap. |
| Clean Up | Nothing until a scan. |
| Converter | One click monitor (mouse-down) and one modifier monitor for the wheel, both doing an integer compare. |
| Recording, scrolling | Nothing until started. |

Idle CPU stays ≤ 0.1 %, measured after each feature.

## 5. Order

README facts → B (middle click) → E (recording) → F (scrolling) → D (converter) → C (Clean Up) → A (volume) → README. Each lands as its own commit with tests, a release build, an install and an idle check. Live screen tests only while Bryan is away.
