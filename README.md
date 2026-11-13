<p align="center"><img src="docs/assets/icon.png" width="112" alt="Tutto icon: three white slider knobs on dim glass tracks, on black"></p>

<h1 align="center">Tutto</h1>

<p align="center"><b>Every Mac utility you actually use, in one quiet menu bar app.</b><br>
Battery &amp; system load · fans · clipboard history · a ⌘Tab for every window · the scrolling strip · screenshots, scrolling captures and screen recording · convert &amp; compress · clean-up · per-app volume · stay awake · auto clicker · archives · trackpad clicks · word counter.</p>

Tutto is sixteen everyday tools in one native Swift app. **The app is 12 MB, it uses about 20 MB of memory when it starts and no measurable CPU while idle** (around 65 MB once you've used every tool), and it's MIT-licensed. Every tool can be switched off, and a tool that's off uses nothing at all: fifteen from the Overview and General pages, and the Scrolling Strip, which rearranges every window, from its own page.

## What's inside

- **System:** battery (watts, health, cycles), CPU, GPU, memory, disk, network, temperatures and fan control, in the menu bar and in the app.
- **Window switcher:** ⌘Tab with a card for every window, not just every app.
- **Windows:** drag a window to an edge or corner to snap it, or snap it to halves, thirds and quarters from a palette or a key.
- **Scrolling Strip:** every window side by side on one strip that scrolls.
- **Screenshots:** capture to the clipboard or an editor (draw, crop, copy text, pick colors); **scrolling captures** of whole pages; **screen recording** saved as an MP4.
- **Convert:** pictures, video, sound, PDFs, documents and subtitles into other formats, or smaller, on this Mac; tap ⇧ while dragging files for a wheel of formats.
- **Clean Up:** leftovers from apps you removed, caches, logs and the Trash, reviewed first; what you remove goes to the Trash. A disk map shows what fills the disk.
- **Clipboard history:** searchable, with pins; ⌥⇧⌘V pastes anything as plain text.
- **Sound:** any app's own level, up to 300 % for quiet ones, or muted at the speakers.
- **Battery:** a charge limit (stop at 80 %, or a level you pick) and the charge of AirPods and other Bluetooth devices.
- **Menu Bar Icons:** tuck away the icons you rarely use behind one small divider.
- **Keep on top:** pin a window above all the others.
- **Keyboard cleaning:** keys and trackpad locked for 30 s while you wipe them.
- **Stay Awake:** the Mac stays on for a time you type, lid closed included.
- **Auto clicker:** up to 100 clicks a second, from a switch or ⌃⇧A.
- **Archives:** look inside RAR, 7z, zip and more without unpacking, take out just what you need, add and remove files; space in Finder shows what's inside.
- **Trackpad Corner:** click or tap a corner to right-click; a three-finger click can be a middle click.
- **Word counter:** words, characters and reading time of any text.

<p align="center">
  <img src="docs/assets/panel.png" width="300" alt="Tutto's menu bar panel: its sliders mark with a one-line verdict on the Mac, the battery with watts, health and the three busiest apps, six tiles for CPU, memory, GPU, disk, network and temperature with small line charts, a strip of apps to mute, the tools in a row with their keys, and Tutto's own memory use in the footer">
  &nbsp;&nbsp;
  <img src="docs/assets/clipboard.png" width="520" alt="Clipboard history palette with search, type filters, preview and keyboard hints">
</p>

## Install

Requirements: macOS 14 or later (built and tested on macOS 26.5 on an M5 MacBook Pro), Xcode 26 to build.

```bash
cd ~/Documents/XCode/Tutto
scripts/build.sh --install
```

That builds a release `Tutto.app`, signs it with your Apple Development identity, and installs it in `/Applications`. Then open it from Spotlight (`⌘Space`, type "Tutto"). The welcome window walks through:

1. **Tools** — all are on except the scrolling strip, which rearranges every window and waits until you want it; switch off anything you don't want.
2. **Access** — two macOS switches (see [Permissions](#permissions)).
3. **Keys** — the six shortcuts below.
4. **Try it** — press your trackpad's corner and watch the right-click land.

If another app already uses one of the shortcuts below, macOS may deliver the keys to both apps. Change the shortcut in Tutto › Shortcuts or in the other app.

## Use

| Shortcut | What it does |
|---|---|
| `⌘Tab` | Window switcher: every window gets its own card, not just every app (three Firefox windows are three cards, on any Space or in full screen, with a picture of each). Hold `⌘`, press `Tab` to move, let go to switch; a quick tap goes back to the previous window. While it's open: `1`–`9` switch to that card, `W` close, `M` minimize, `Q` quit, `H` hide, `F` fill the screen, `C` centre, `N` next display, `R` rename the window, `/` search, `` ` `` only that app's windows, `Esc` cancel |
| ``⌘` `` | The front app's windows only (all your Firefox windows) |
| `⌘⇧2` | Select an area → copied to the clipboard (no editor to dismiss) |
| `` ⌘⇧` `` | The whole screen under the pointer → clipboard (it takes these keys from macOS's "back through an app's windows"; ⌘` still goes through them) |
| `⌘⇧1` | Select an area → screenshot editor |
| `⌃⇧V` | Clipboard history: type to search, double-click or `↩` to paste into the app you were in (your clipboard stays as it was; Clipboard › "Keep pasted items on the clipboard" changes that), `⇧↩` paste as plain text, `⌘↩` copy, `⇥` filter by type, `⇧⌘P` pin, `⌘⌫` delete |
| `⌥⇧⌘V` | Paste as plain text, in any app: what you copied, without its fonts, colors or links (your clipboard keeps them) |
| `⌃⇧B` | Window palette: type "left half", "max", "next display"…, `↩` |
| `⌃⇧R` | Record the screen: pick an area, a window or the whole screen; press again (or Stop in the menu bar) to save an MP4 |
| `⌃⇧S` | Scrolling capture: pick the part that scrolls; Tutto scrolls it and stitches one tall picture |
| `⌃⇧K` | The Convert window: drop files, pick a format or Compress |
| `⌃⇧A` | Start or stop the auto clicker |
| `⌃⇧C` | Word counter: the cursor is ready, press `⌘V` (or type) to see words, characters (with and without spaces), sentences, paragraphs, reading and speaking time, and the same for a selection. `⌘K` clears, `Esc` closes |

Every shortcut can be re-recorded in **Tutto › Shortcuts** (click it, press the new keys; Esc cancels, Delete removes). Every window action can also get its own shortcut.

**While selecting an area:** the pointer is a crosshair with its position in pixels just below-right of it (the selection's size while you drag); drag to select, click a window to take just that window, click the desktop for the whole screen, `Shift` for a square, `Space`+drag to move the selection, `Tab` copies the color under the crosshair, `Esc` cancels.

**In the screenshot editor:** with no tool, drag to make a selection box (move it, drag its handles; `↩` crops to it). `P` draw, `H` highlight, `A` arrow, `R` rectangle, `[`/`]` thickness, eight colors plus any color. `T` copies all text (in the selection if there is one) and QR codes. `Tab` copies the hovered pixel's hex color. `⌘S` opens the save window (pick the folder, rename it, tags, PNG or JPEG; Screenshots › "When you save in the editor" › Save to folder makes it save straight to Downloads or your folder with the date as the name instead, and `⇧⌘S` always does the other one), `⌘C` copies, **`Esc` copies and closes**. `⌘Z` undoes.

**Menu bar panel:** what you open the menu bar for. It never grows taller than the screen: past that, the cards scroll between the header and the footer. (General › Menu bar panel hides any part you don't use.) Tutto's mark (three sliders) beside how the Mac is doing in plain words: a problem if there is one, else the battery ("On battery · 4 h 9 min left"). The battery card shows the charge, the watts the Mac is drawing, the battery's health and cycles, and the three apps using the processor most as small chips (helpers counted as their app; point at one for its name). AirPods and other Bluetooth devices show their battery levels (the first time, Show asks macOS for Bluetooth access). Six readings follow, three across: CPU, memory, GPU, free disk space, network and temperature, each a number with the last minute as a faint line (point at one for its detail); any of them opens its page in the app. Then one card with a line each for Stay awake (type a time or pick 1h, 2h, 4h), the auto clicker (its switch; open it for speed, click and when it stops) and the fan (Auto, Custom or Max). A Sound strip shows your apps: click one to mute it at the speakers; **Levels** swaps the strip for a slider for every open app, quiet ones included (it stays open until you close it). The tools sit in one bar of icons; point at one for its name and keys, click it and the keys light up as if pressed, then the tool runs. The footer shows what Tutto itself is using right now. Settings, battery history, the full fan page and Trackpad Corner's controls live in the app; ⋯ holds pause clipboard history, pause Trackpad Corner, clean the keyboard, open at login, the Shortcuts and Permissions pages, and quit. Readings run only while the panel is open, and no process is started for them. With the Liquid Glass look (the default on macOS 26; Appearance › Look switches to Classic, the theme you had), every card floats over your desktop as its own piece of glass.

**Sound:** every app gets its own level. Open **Levels** on the panel's Sound card (or the Sound page) and drag an app's slider: below the mark it's quieter, past it is boost, up to 300 % for a quiet video or call, with a limiter so boosted sound doesn't distort. Let go near 100 % and it lands there; double-click a slider for 100 %. An app that isn't at 100 % gets a thin ring around its icon. Click an app's icon to mute it at your speakers and headphones — Discord's pings go quiet while Firefox keeps playing. The app itself keeps playing, so screen recordings and tools listening to it still hear it. Helpers are included, levels and mutes are remembered when apps restart, and "Mute or unmute the front app" can get a shortcut. An app at 100 % goes straight to the speakers untouched; one turned up or down plays through Tutto only while it's playing.

**Screen recording (`⌃⇧R`, macOS 15):** the screenshot picker opens: drag an area, click a window, or click the desktop for the whole screen. A 3-2-1 (or 5, or none), then it records at the display's own resolution, 60 or 30 frames a second, H.264 (plays everywhere) or HEVC (about half the size), with the Mac's sound and your microphone if you switch them on, the pointer and a ring where you click. A thin outline marks the area and stays out of the video. A dot and the time sit beside Tutto's icon, and the panel shows Stop; the keys again also stop it. The MP4 lands in the screenshots folder, and a thumbnail in the corner lets you drag it into any app, play it, show it, copy it or delete it. Settings: Screenshots › Screen recording.

**Scrolling capture (`⌃⇧S`):** pick the part of a window that scrolls (a web page, a chat, a document). Tutto scrolls it by itself, captures each step and stitches one tall picture, keeping a header or footer that stays put only once and leaving out the scroll bar that flashes while it scrolls; if the content won't scroll for Tutto, it asks you to scroll and follows. It stops at the end of the content, or press Return (Done) or Esc (Cancel). The picture is saved as a PNG, copied to the clipboard, and shown in the corner to drag anywhere or **Edit**.

**Convert and compress (`⌃⇧K`, the Convert tile, or tap `⇧` while dragging files):** drop files on the Convert window and pick a format, or Compress with its settings. While dragging files anywhere — from Finder, the desktop or a mail — tap ⇧ and a wheel of formats opens at the pointer, Compress in the middle; drop on one. Finder's right-click menu has **Convert** too. Copies land beside the originals, never over them, and a note says how much smaller they got.
- **Pictures** (anything macOS reads, RAW, HEIC and WebP included) → JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP or PDF; several pictures → one PDF. Compress: quality, the longest side, a size to aim for ("500 KB"), and location and camera details removed (the picture is turned upright first). PNGs become palette PNGs when that looks the same, often a third of the size.
- **Video** → MP4 (H.264 or HEVC), MOV, an animated GIF, or just the sound (M4A). Compress: Small, Balanced or High, a size (4K, 1080p, 720p, 480p) and the codec.
- **Sound** → M4A, Apple Lossless, WAV, AIFF or FLAC. Compress: AAC at the bit rate you pick.
- **PDFs** → every page as a PNG or JPEG at 300 dpi, or the text. Compress: Light (pictures inside become JPEG at full resolution, prints as before) or Strong (also brought to screen resolution, for email).
- **Documents** (Word, RTF, ODT, HTML, text, Markdown) → PDF, Word, RTF, ODT, HTML or text. **Subtitles**: SRT ↔ VTT, or text.

**Clean Up (Tools › Clean Up, or the Clean tile):** Scan reads only; nothing changes until you choose. You get a list to review, with sizes and ticks: what apps you removed left in `~/Library` (preferences, caches, app data, saved state), caches, logs, and developer caches that rebuild themselves (Xcode DerivedData, npm, pnpm, uv, Playwright, Homebrew…; unticked). **Move to Trash** moves what's ticked, so it can be put back; **Empty Trash…** is separate, with a warning. It leans safe: only your home folder, nothing of Apple's, nothing an installed app's maker might still use, no cache of a running app, and an old app's data starts unticked if it changed lately or looks like a sign-in. Full Disk Access is optional and adds apps' containers and the Trash.

**Charge limit (Battery page, off until you turn it on):** stop charging at 80 % (or anywhere from 50 to 100 % in steps of 5) and the Mac runs on the adapter while the battery sits; charging starts again 5 % below. "Charge to 100 %" lifts it once for a day away. It goes through Tutto's helper with a lease the app renews every minute, so if Tutto quits or crashes charging comes back on by itself within about 90 s. The panel's battery card says "Held at 80 %" while it holds.

**Bluetooth batteries:** AirPods (left, right and case), Magic Keyboard, Mouse and Trackpad show their charge on a panel card and the Battery page; 20 % or less turns red. The card is there only while a device reports a level, and it's read only while you look.

**Menu Bar Icons (off until you turn it on):** one thin divider with a small chevron sits left of Tutto's icon. Hold ⌘ and drag the icons you rarely use to its left; a click on the divider hides them, another brings them back, and they tuck away again after 10 s (or 5, 30, never). Tutto's own icon never hides.

**Keep on top:** record a shortcut on the Windows page (or use **Keep on Top** in the window palette) and the front window stays above every other window while you work elsewhere; the keys again put it back. macOS doesn't let one app raise another's window, so Tutto floats a live copy of it over the real one while another app is in front; click it and you're in the real window. Up to three.

**Show keys while recording:** Screenshots › Screen recording › "Show keys you press": Off, Shortcuts (keys with ⌘, ⌃ or ⌥, plus Esc, Return, arrows…) or Every key. They appear as keycaps near the bottom of the video and fade a second later; never while a password field has the keyboard.

**Disk map (Clean Up › Disk map):** scan your home folder (the whole disk with Full Disk Access) and see it as rings sized by what each folder takes; hover for the name and size, click to go in, move what you don't need to the Trash from the list beside it.

**Keyboard cleaning (⋯ menu, or General):** a calm countdown fills the screens and the keys and trackpad clicks do nothing for 15, 30 or 60 s, then everything comes back by itself.

**Make it yours (Settings › Customize, Appearance and Plugins):** shaped the way an editor is, and all of it in the app, never in the menu bar. *Appearance* has six themes (Tutto, Graphite, Paper, Slate, Midnight, Forest) and lets you adjust the one in use (accent, greys, contrast, glass/tinted/solid panel, filled or outlined cards, corners, spacing, number style, light or dark); the whole app follows at once, a contrast check flags anything hard to read, and **Save as Theme…** writes it as a JSON file you can share. *Customize* puts every panel card in one list: move any card anywhere (drag it in the list or in the live preview), make it small or wide, hide it. *Plugins* switches Tutto's tools on and off and adds your own, which can be **actions** (a command from a shortcut, the tools row or a link), **cards** (a live reading on the panel from a command's output: plain text or JSON with a value, a line, a meter, a list), **automations** (run on a schedule, when the battery runs low, an app opens, you copy something, the network or displays change, your agents finish, or a custom event from `open -g "tutto://do/event?name=…"`) and **settings** (a form; secrets in your keychain). Fifteen templates; each plugin is a JSON file (or a folder with its scripts) in `~/Library/Application Support/Tutto/Plugins`, and one added by hand starts off until you've seen what it runs. The full reference: [docs/PLUGINS.md](docs/PLUGINS.md).

**Auto Clicker:** clicks for you, up to 100 times a second. Flip its switch in the menu bar panel's Controls card (it starts 2 s after the panel closes, so it doesn't click the panel; click its name to set the speed, the click and when it stops, changes applying at once even mid-run) or press `⌃⇧A` from any app, games included; press it again, push the pointer into a screen corner, or let it reach its limit to stop. On its page (Tools › Auto Clicker): clicks per second, a random spread so the clicks aren't perfectly even, left, right or middle, single or double (a real double click), at the pointer or a spot you pick, stop after a number of clicks or a time, a start delay, and hold-to-click (it clicks only while the shortcut is held). While it clicks, a small still pill at the top of the screen shows only how to stop it (its keys, and a corner when that's on); the menu bar icon shows it's on. Scripts: `tutto://do/clicker?cps=20&at=640,400&for=30`.

**Stay Awake:** keep the Mac on for as long as you say, lid closed included, so agents keep working. Open the menu bar panel and type a time in the Stay awake card (`90` is ninety minutes; `2h30`, `1.5h`, `1d 6h` and `2:30` work too) and press Return, or click 1h, 2h, 4h or 8h. The time left sits beside Tutto's icon; the card shows the countdown, adds 15 minutes or an hour, and ends it. Close the lid whenever you like: the display goes to sleep (or, if an app is holding it awake, dims to 0 and comes back to your level when you open it), the sound is muted, chat, social and game apps are paused (pick exactly which on the Stay Awake page) and Low Power Mode comes on for the battery; opening the lid puts it all back. On battery it turns on Low Power Mode below 40 % and ends below 10 %, and it slows down or ends if the Mac gets too hot. When the time is up with the lid still closed, the Mac goes to sleep. With another display connected, closing the lid is just a desk set-up and nothing changes. Keeping it on with the lid closed needs Tutto's helper (the one fan control uses, approved once); without it, Stay Awake keeps the Mac on only while the lid is open, and says so. While agents work (on by default, Stay Awake page): when a coding agent starts working, Stay Awake turns on by itself, lid tricks and all, and turns off once agents have been quiet for 10 minutes (5 or 30 if you like), putting a closed Mac to sleep; the menu bar shows a cup meanwhile. It counts writes to the agents' session-log folders and busy commands they started (a build), not merely an agent being open; other tools can call `tutto://do/agent-busy`. Optional, off until you turn it on: if the network drops during a session, Tutto joins your phone's hotspot (name and password on the Stay Awake page; the password stays in your keychain).

**Scrolling strip** (off until you turn it on, on its page under Tools › Scrolling Strip): every window sits side by side on one strip, full height between the menu bar and the Dock, and the screen scrolls along it — nothing overlaps and opening a window never shrinks the others. Windows are arranged when you use a strip key (or ⌘Tab to one that's out of view); otherwise they stay wherever you or the window palette put them ("Arrange windows › All the time" makes the strip hold its shape constantly). Hold `⌃⌥` to see the strip bar, with a picture of each window. All your apps in full screen? "Bring Them Here" puts them on the strip, full width. `⌃⌥←` `⌃⌥→` move between windows and loop round at the ends (→ on the last window carries on to the first, which comes in from the right; a held key stops at the end, press again to loop), `⌃⌥⇧←` `⌃⌥⇧→` move a window along (round the ends too, as do `⌃⌥↑` `⌃⌥↓` in a stack), `⌃⌥1`–`9` jump (9 is the last), `⌃⌥R` cycles the width (25 → 33 → 50 → 66 → 75 %), `⌃⌥F` full width, `⌃⌥⇧F` every window into full screen, as its green button would, or back to the strip (also the Strip · Full switch at the bottom of the menu bar panel; apps you keep in full screen yourself stay there), `⌃⌥C` centre, `⌃⌥]` / `⌃⌥[` stack into the left / right column, `⌃⌥⇧]` pop out, `⌃⌥⇧T` tabbed column, `⌃⌥P` pin to the left edge, `⌃⌥T` float, `⌃⌥N` next display, `⌃⌥Q` stop (every window goes back on screen). Every key can be changed in Shortcuts. ⌃⌥ + scroll moves along the strip, a three- or four-finger swipe can too, and a frosted bar of app icons shows where you are. Dialogs, Quick Look and fixed-size windows float; native full screen is left alone.

**Trackpad Corner:** click or tap a bottom corner of the trackpad to right-click (pick the corner and its size on the page). Switch on **Three-finger click is a middle click** and a press with three fingers anywhere becomes a middle click — links open in a new tab, tabs close, Terminal pastes — and holding it drags with the middle button, for panning and orbiting in 3D and CAD apps. It waits while macOS's three-finger drag is on.

**Snap by dragging (Windows page):** drag a window to the left or right edge for a half, a corner for a quarter, the top to fill the screen, or the bottom for thirds (slide from an outer third into the middle for two thirds). An outline shows where it will go before you let go, and Esc cancels. Drag a window Tutto snapped and it gets its old size back. macOS 15 and later have their own edge tiling; while it's on, Tutto stays out of its way (switch it off in System Settings › Desktop & Dock to use Tutto's, with thirds, the gap you set and sizes given back).

**Archives:** open one (double-click with Tutto as the archive app, **Open in Tutto** in Finder's right-click menu, or Archives › Open…) and a window shows what's inside without unpacking anything: folders with their sizes and file counts, dates, kinds, a path along the top to click back through, and search across the whole archive. Double-click a folder to go in, an archive inside the archive to open it in place, anything else to open it in its app; space shows it in Quick Look. **Extract** takes out only what's selected (into a folder you pick), or drag rows straight to Finder. In zip, 7z and tar archives (plain, .gz, .bz2, .xz), **Add** (or drop files in) and **Remove** (or ⌫) change the archive in place, in its own format; the old copy goes to the Trash, so a change can be undone. RAR, ISO, CAB, split and encrypted archives, and archives inside archives, are read only, and the window says why. In Finder, select an archive and press space: Quick Look shows its folders and files. Archives › When you open an archive switches double-click back to extracting straight away.

**Finder:** right-click an archive for **Open in Tutto**, **Extract Here**, **Extract to "Name"**, **Extract to…**; right-click anything for **Compress to ZIP**, and files for **Convert ›** (their formats, Compress, More…). Archives can also be opened with Tutto by double-clicking (Archives › Make Default).

**Automation:** `tutto://do/capture-area`, `capture-screen`, `capture-edit`, `record-screen`, `scrolling-capture`, `clean-up`, `clipboard`, `windows`, `word-counter`, `mute-front-app`, `quit` run an action; `tutto://convert?to=png&path=…` (or `compress=1`, or `open=1` for the window) converts files; `tutto://do/clicker` starts or stops the auto clicker (with optional `cps`, `button`, `double`, `at=x,y`, `for` seconds, `clicks`); `tutto://do/stay-awake?for=2h` starts Stay Awake (or adds the time to the session running) and `tutto://do/stay-awake-end` ends it, so an agent can keep the Mac on for its own run (`open -g "tutto://do/stay-awake?for=3h"`); `tutto://open/<page>` (e.g. `battery`, `shortcuts`) opens a page — handy from Shortcuts, scripts or a Stream Deck.

**Can't see the menu bar icon?** On MacBooks with a camera notch, a full menu bar hides new icons behind the notch. Tutto notices and tells you; quit a menu bar app you no longer need, or hold ⌘ and drag icons to reorder them. Everything in the panel is also in the app (Spotlight › Tutto).

**Fans:** Sensors & Fans › Fan › Auto / Custom / Max. Fans always return to Auto when you quit Tutto, the Mac sleeps, Sensors is switched off, or Tutto stops unexpectedly.

## Permissions

| Permission | Powers | Asked |
|---|---|---|
| Accessibility | Trackpad Corner, the window switcher, the scrolling strip, moving windows, pasting from clipboard history | Welcome window / first use |
| Screen Recording | Screenshots, color picking, text recognition, window titles and pictures in the switcher | Welcome window / first capture |
| System Audio Recording | Muting apps and setting their levels in Sound (Tutto holds their sound back or plays it louder or quieter; nothing is recorded) | The first time you mute an app or change its level |
| Microphone | Your voice in a screen recording, only when "The microphone" is on | The first recording with it on |
| Full Disk Access (optional) | Clean Up's look into apps' containers and the Trash | Clean Up page, when you choose to |
| Finder extension | The Open / Extract / Compress right-click items | Archives page (System Settings › General › Login Items & Extensions › Extensions) |
| Tutto's helper (App Background Activity) | Setting fan speeds (reading never needs it), and Stay Awake keeping the Mac on with the lid closed | When you first choose Custom or Max, or set up Stay Awake |
| Location Services | Only Stay Awake's hotspot option, which needs to see Wi-Fi names; Tutto never reads your location | When you turn the hotspot option on |
| Files & folders | Saving to Downloads, extracting in Desktop/Documents/Downloads | macOS asks once per folder |

Tutto sends nothing over the network and has no analytics; the only network feature, Stay Awake's optional hotspot fallback, joins a Wi-Fi network you named. Clipboard history stays in `~/Library/Application Support/Tutto/Clipboard`. Copies that password managers mark as concealed are never recorded.

## How it stays light

- **Nothing runs while you're not looking.** System readings, temperatures and the `top` process feed run only while the panel or a page shows them, and stop the moment it closes.
- **Event-driven where macOS allows.** Shortcuts are Carbon hot keys (the system calls Tutto), Trackpad Corner wakes only when a finger touches the trackpad, battery changes come from IOKit notifications.
- **The one unavoidable timer** — macOS has no clipboard-changed notification — checks a local counter about once a second with wide timer leeway so macOS folds it into wake-ups that happen anyway, slows to every 4 s when you're away, and stops while the screen is locked.
- **The window switcher waits, it doesn't watch.** A key filter on its own thread lets every key through except the trigger; the window list is built when you press ⌘Tab (about 10 ms) and window pictures are taken only while it's open, then dropped 30 s later.
- **The scrolling strip moves only when something changes.** Each app reports its window changes through an Accessibility observer, a display link runs only while windows slide, and windows move on one queue per app so a slow app never holds up the rest.
- **Stay Awake runs nothing until you start it.** During a session: one timer for the end, a tick a minute for the time beside the icon (stopped while the lid is closed), and macOS's own lid, power and heat notifications. The helper checks once a minute that the session hasn't outlived its end.
- **Tools that wait.** Screen recording, scrolling capture, Clean Up and the converter's work start nothing until you use them; the converter's ⇧ wheel is two event monitors doing an integer compare per mouse press and modifier key.
- **Sound costs nothing at 100 %.** An app you haven't turned up, down or muted goes straight to the speakers; a changed one plays through a Core Audio tap that runs only while that app plays.
- **Off means off.** A module that's switched off releases its object, timers, taps, hot keys and (for Archives) the Finder extension.

Measurements and comparisons with comparable utilities are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Limitations (honest)

- **Fan control** writes the SMC through a root helper you approve once (System Settings › General › Login Items & Extensions). Verified on an M5: Max spins the fan to about 6,550 rpm and quitting returns it to Auto.
- **Temperatures:** Apple doesn't document which sensor is the CPU or GPU on Apple silicon. Tutto labels CPU/GPU only from published SMC key tables (on M5, confirmed to respond to CPU and GPU load on this Mac) and shows the rest as SoC die, battery and SSD.
- **Archives:** Tutto uses the libarchive built into macOS, so encrypted RAR and 7z archives and zstd/lz4 compression can't be opened (password-protected zip works), and RAR can be read but not written. Compression produces zip, 7z, tar.gz or tar.xz.
- **Screen Recording:** macOS may periodically ask you to re-confirm it; that's macOS policy.
- **Window switcher:** while you type in a password field macOS hides keystrokes from every app, so ⌘Tab shows macOS's own switcher there. If Tutto quits or crashes, macOS's ⌘Tab is back immediately (nothing in the system is switched off). It relies on private window-server calls to list windows on other Spaces and switch to them; a window on another Space that nothing has touched since its app started is reached through that app's Window menu. Video that apps protect from capture shows as a dark picture.
- **Scrolling strip:** macOS doesn't let an app hide another app's window, so a window out of view waits at the left or right edge of its display with one point showing (level with the screen, so Mission Control shows every window at its usual size). Strip keys are caught before other apps' shortcuts (so they win while the strip is on), except in password fields, where macOS hides keystrokes; there the regular shortcut answers if no other app took the keys first. A three-finger swipe can clash with macOS's own swipe between full-screen apps: Mac Setup on the strip's page points out the setting.
- **Stay Awake:** the lid works through macOS's own sleep switch (`pmset disablesleep`), held by Tutto's helper only for the session; the helper keeps the end time itself, so a Tutto that quits or stops can't keep the Mac on past it, and paused apps are resumed at once if Tutto goes away. macOS ignores a display-sleep request while an app holds the display on (a sound or video playing), so after 30 s Tutto dims the display and keyboard light to 0 through private controls checked on macOS 26 (on another version they're left on and the page says so), and puts back the level sampled while the lid was open. On Apple silicon, closing the lid disconnects the built-in microphone in hardware, so a call or recording with the lid shut needs another mic. Some browsers slow down pages in windows nobody can see, which includes every window under a closed lid. Use it on a desk, not in a bag: a working Mac makes heat.
- **Screen recording** needs macOS 15. Video that apps protect from capture records as a dark picture.
- **Scrolling capture** scrolls with ordinary scroll events, which most apps follow; when one doesn't, it asks you to scroll. Pictures stop at 16,384 pixels tall.
- **Convert** uses only what macOS has built in, so it can't write MP3, WebP, MKV, WebM or Opus, and reads no spreadsheets or slides. Documents go through macOS's text system: text, styles and lists come through, complex page layouts don't.
- **Clean Up** looks only in your home folder. It judges leftovers by maker, so an app you removed whose maker still has another app installed isn't flagged (its caches still are, in Caches).
- **Per-app volume** needs macOS 14.2. An app you've turned up or down reaches the speakers a few milliseconds later, and macOS shows its audio-in-use dot while it plays.
- **Shortcut clashes:** if another app registers the same keys, macOS may deliver them to both apps. Change one of the shortcuts.
- **Not included:** remote, clock and Bluetooth monitoring, alerts, pinned screenshots, cloud upload, an app launcher.

## Development

```bash
swift test                               # 411 XCTest + 58 Swift Testing tests (corner engine, readers, archives, clipboard, layout, themes, plugins, converter, stitcher, clean-up rules, gain…)
scripts/build.sh --debug                 # debug build with offscreen UI snapshots:
build/Products.noindex/Tutto.app/Contents/MacOS/Tutto --snapshot /tmp/shots panel battery editor
scripts/measure.sh 180 Tutto <OtherApp> …           # idle CPU / memory / wake-ups, side by side
scripts/measure-modules.sh 90            # idle cost per module combination
```

Layout: `Sources/TuttoKit` (testable logic: Trackpad Corner engine, system readers, sensors/fans, archives, clipboard store, window layout, shortcuts, the converter's rules, the scrolling stitcher, clean-up rules, the volume gain stage), `Sources/Tutto` (app and UI), `Sources/TuttoFinder` (Finder extension), `Sources/TuttoHelper` (root fan helper), `Sources/CBridges` (C shims for MultitouchSupport, SMC, IOHID and libarchive). Requirements and their status: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Test results: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md).

## License

MIT. libarchive (BSD) ships with macOS. Labels are set in [Geist](https://github.com/vercel/geist-font) 1.8.1 (SIL Open Font License 1.1, bundled with its license in `Resources/Fonts`).
