<p align="center"><img src="docs/assets/icon.png" width="112" alt="Tutto icon: three white slider knobs on dim glass tracks, on black"></p>

<h1 align="center">Tutto</h1>

<p align="center"><b>Every Mac utility you actually use, in one quiet menu bar app.</b><br>
Battery &amp; system load · temperatures &amp; fans · clipboard history · window snapping · screenshots with OCR · archives from Finder · trackpad corner right-click · word counter.</p>

Tutto is thirteen everyday tools in one native Swift app that uses **about 20 MB of memory when it starts and no measurable CPU while idle** (around 65 MB once you've used every tool). Every tool can be switched off, and a tool that's off uses nothing at all: twelve from the Overview and General pages, and the Scrolling Strip, which rearranges every window, from its own page.

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
| `⌃⇧V` | Clipboard history: type to search, double-click or `↩` to paste into the app you were in (your clipboard stays as it was; Clipboard › "Keep pasted items on the clipboard" changes that), `⌘↩` copy, `⇥` filter by type, `⇧⌘P` pin, `⌘⌫` delete |
| `⌃⇧B` | Window palette: type "left half", "max", "next display"…, `↩` |
| `⌃⇧C` | Word counter: the cursor is ready, press `⌘V` (or type) to see words, characters (with and without spaces), sentences, paragraphs, reading and speaking time, and the same for a selection. `⌘K` clears, `Esc` closes |

Every shortcut can be re-recorded in **Tutto › Shortcuts** (click it, press the new keys; Esc cancels, Delete removes). Every window action can also get its own shortcut.

**While selecting an area:** the pointer is a crosshair with its position in pixels just below-right of it (the selection's size while you drag); drag to select, click a window to take just that window, click the desktop for the whole screen, `Shift` for a square, `Space`+drag to move the selection, `Tab` copies the color under the crosshair, `Esc` cancels.

**In the screenshot editor:** with no tool, drag to make a selection box (move it, drag its handles; `↩` crops to it). `P` draw, `H` highlight, `A` arrow, `R` rectangle, `[`/`]` thickness, eight colors plus any color. `T` copies all text (in the selection if there is one) and QR codes. `Tab` copies the hovered pixel's hex color. `⌘S` opens the save window (pick the folder, rename it, tags, PNG or JPEG; Screenshots › "When you save in the editor" › Save to folder makes it save straight to Downloads or your folder with the date as the name instead, and `⇧⌘S` always does the other one), `⌘C` copies, **`Esc` copies and closes**. `⌘Z` undoes.

**Menu bar panel:** what you open the menu bar for. (Since 2026-11-10 Stay awake, the auto clicker and the fan share one Controls card, a line each, and General › Menu bar panel hides any part you don't use.) Tutto's mark (three sliders) beside how the Mac is doing in plain words: a problem if there is one, else the battery ("On battery · 4 h 9 min left"). The battery card shows the charge, the watts the Mac is drawing, the battery's health and cycles, and the three apps using the processor most (helpers counted as their app). Six tiles follow: CPU, memory, GPU, free disk space, network and temperature, each with the last minute as a line, and any of them opens its page in the app. The fan card sets the fans to Auto, Custom (a speed you pick) or Max right there. A Sound strip shows your apps: click one to mute it at the speakers. The tools sit in one row with their keys (Area, Edit, Screen, History, Snap, Words). Click one instead of pressing the keys: they light up as if pressed and the tool opens. The footer shows what Tutto itself is using right now. Settings, battery history, the full fan page and Trackpad Corner's controls live in the app; ⋯ holds pause clipboard history, pause Trackpad Corner, open at login, the Shortcuts and Permissions pages, and quit. Readings run only while the panel is open, and no process is started for them.

**Sound:** click an app in the panel's Sound row (or flip its switch on the Sound page) to mute it at your speakers and headphones — Discord's pings go quiet while Firefox keeps playing. The app itself keeps playing, so screen recordings and tools listening to it still hear it. Its helper processes are muted with it, it stays muted when it restarts, and "Mute or unmute the front app" can get a shortcut.

**Make it yours (Settings › Customize, Appearance and Plugins):** shaped the way an editor is, and all of it in the app, never in the menu bar. *Appearance* has six themes (Tutto, Graphite, Paper, Slate, Midnight, Forest) and lets you adjust the one in use (accent, greys, contrast, glass/tinted/solid panel, filled or outlined cards, corners, spacing, number style, light or dark); the whole app follows at once, a contrast check flags anything hard to read, and **Save as Theme…** writes it as a JSON file you can share. *Customize* puts every panel card in one list: move any card anywhere (drag it in the list or in the live preview), make it small or wide, hide it. *Plugins* switches Tutto's tools on and off and adds your own, which can be **actions** (a command from a shortcut, the tools row or a link), **cards** (a live reading on the panel from a command's output: plain text or JSON with a value, a line, a meter, a list), **automations** (run on a schedule, when the battery runs low, an app opens, you copy something, the network or displays change, your agents finish, or a custom event from `open -g "tutto://do/event?name=…"`) and **settings** (a form; secrets in your keychain). Fifteen templates; each plugin is a JSON file (or a folder with its scripts) in `~/Library/Application Support/Tutto/Plugins`, and one added by hand starts off until you've seen what it runs. The full reference: [docs/PLUGINS.md](docs/PLUGINS.md).

**Auto Clicker:** clicks for you, up to 100 times a second. Flip its switch in the menu bar panel's Controls card (it starts 2 s after the panel closes, so it doesn't click the panel; the chevron sets the speed and button) or press `⌃⇧A` from any app, games included; press it again, push the pointer into a screen corner, or let it reach its limit to stop. On its page (Tools › Auto Clicker): clicks per second, a random spread so the clicks aren't perfectly even, left, right or middle, single or double (a real double click), at the pointer or a spot you pick, stop after a number of clicks or a time, a start delay, and hold-to-click (it clicks only while the shortcut is held). A pill at the top of the screen counts the clicks and says how to stop; the menu bar icon shows it's on. Scripts: `tutto://do/clicker?cps=20&at=640,400&for=30`.

**Stay Awake:** keep the Mac on for as long as you say, lid closed included, so agents keep working. Open the menu bar panel and type a time in the Stay awake card (`90` is ninety minutes; `2h30`, `1.5h`, `1d 6h` and `2:30` work too) and press Return, or click 1h, 2h, 4h or 8h. The time left sits beside Tutto's icon; the card shows the countdown, adds 15 minutes or an hour, and ends it. Close the lid whenever you like: the display goes to sleep (or, if an app is holding it awake, dims to 0 and comes back to your level when you open it), the sound is muted, chat, social and game apps are paused (pick exactly which on the Stay Awake page) and Low Power Mode comes on for the battery; opening the lid puts it all back. On battery it turns on Low Power Mode below 40 % and ends below 10 %, and it slows down or ends if the Mac gets too hot. When the time is up with the lid still closed, the Mac goes to sleep. With another display connected, closing the lid is just a desk set-up and nothing changes. Keeping it on with the lid closed needs Tutto's helper (the one fan control uses, approved once); without it, Stay Awake keeps the Mac on only while the lid is open, and says so. While agents work (on by default, Stay Awake page): when a coding agent starts working, Stay Awake turns on by itself, lid tricks and all, and turns off once agents have been quiet for 10 minutes (5 or 30 if you like), putting a closed Mac to sleep; the menu bar shows a cup meanwhile. It counts writes to the agents' session-log folders and busy commands they started (a build), not merely an agent being open; other tools can call `tutto://do/agent-busy`. Optional, off until you turn it on: if the network drops during a session, Tutto joins your phone's hotspot (name and password on the Stay Awake page; the password stays in your keychain).

**Scrolling strip** (off until you turn it on, on its page under Tools › Scrolling Strip): every window sits side by side on one strip, full height between the menu bar and the Dock, and the screen scrolls along it — nothing overlaps and opening a window never shrinks the others. Windows are arranged when you use a strip key (or ⌘Tab to one that's out of view); otherwise they stay wherever you or the window palette put them ("Arrange windows › All the time" makes the strip hold its shape constantly). Hold `⌃⌥` to see the strip bar, with a picture of each window. All your apps in full screen? "Bring Them Here" puts them on the strip, full width. `⌃⌥←` `⌃⌥→` move between windows and loop round at the ends (→ on the last window carries on to the first, which comes in from the right; a held key stops at the end, press again to loop), `⌃⌥⇧←` `⌃⌥⇧→` move a window along (round the ends too, as do `⌃⌥↑` `⌃⌥↓` in a stack), `⌃⌥1`–`9` jump (9 is the last), `⌃⌥R` cycles the width (25 → 33 → 50 → 66 → 75 %), `⌃⌥F` full width, `⌃⌥⇧F` every window into full screen, as its green button would, or back to the strip (also the Strip · Full switch at the bottom of the menu bar panel; apps you keep in full screen yourself stay there), `⌃⌥C` centre, `⌃⌥]` / `⌃⌥[` stack into the left / right column, `⌃⌥⇧]` pop out, `⌃⌥⇧T` tabbed column, `⌃⌥P` pin to the left edge, `⌃⌥T` float, `⌃⌥N` next display, `⌃⌥Q` stop (every window goes back on screen). Every key can be changed in Shortcuts. ⌃⌥ + scroll moves along the strip, a three- or four-finger swipe can too, and a frosted bar of app icons shows where you are. Dialogs, Quick Look and fixed-size windows float; native full screen is left alone.

**Finder:** right-click an archive for **Extract Here**, **Extract to "Name"**, **Extract to…**; right-click anything for **Compress to ZIP**. Archives can also be opened with Tutto by double-clicking (Archives › Make Default).

**Automation:** `tutto://do/capture-area`, `capture-screen`, `capture-edit`, `clipboard`, `windows`, `word-counter`, `mute-front-app`, `quit` run an action; `tutto://do/clicker` starts or stops the auto clicker (with optional `cps`, `button`, `double`, `at=x,y`, `for` seconds, `clicks`); `tutto://do/stay-awake?for=2h` starts Stay Awake (or adds the time to the session running) and `tutto://do/stay-awake-end` ends it, so an agent can keep the Mac on for its own run (`open -g "tutto://do/stay-awake?for=3h"`); `tutto://open/<page>` (e.g. `battery`, `shortcuts`) opens a page — handy from Shortcuts, scripts or a Stream Deck.

**Can't see the menu bar icon?** On MacBooks with a camera notch, a full menu bar hides new icons behind the notch. Tutto notices and tells you; quit a menu bar app you no longer need, or hold ⌘ and drag icons to reorder them. Everything in the panel is also in the app (Spotlight › Tutto).

**Fans:** Sensors & Fans › Fan › Auto / Custom / Max. Fans always return to Auto when you quit Tutto, the Mac sleeps, Sensors is switched off, or Tutto stops unexpectedly.

## Permissions

| Permission | Powers | Asked |
|---|---|---|
| Accessibility | Trackpad Corner, the window switcher, the scrolling strip, moving windows, pasting from clipboard history | Welcome window / first use |
| Screen Recording | Screenshots, color picking, text recognition, window titles and pictures in the switcher | Welcome window / first capture |
| System Audio Recording | Muting apps in Sound (Tutto holds their sound back; nothing is recorded) | The first time you mute an app |
| Finder extension | The Extract / Compress right-click items | Archives page (System Settings › General › Login Items & Extensions › Extensions) |
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
- **Off means off.** A module that's switched off releases its object, timers, taps, hot keys and (for Archives) the Finder extension.

Measurements and comparisons with comparable utilities are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Limitations (honest)

- **Fan control** writes the SMC through a root helper you approve once (System Settings › General › Login Items & Extensions). Verified on an M5: Max spins the fan to about 6,550 rpm and quitting returns it to Auto.
- **Temperatures:** Apple doesn't document which sensor is the CPU or GPU on Apple silicon. Tutto labels CPU/GPU only from published SMC key tables (on M5, confirmed to respond to CPU and GPU load on this Mac) and shows the rest as SoC die, battery and SSD.
- **Archives:** Tutto uses the libarchive built into macOS, so encrypted RAR and 7z archives and zstd/lz4 compression can't be opened (password-protected zip works). Compression produces zip.
- **Screen Recording:** macOS may periodically ask you to re-confirm it; that's macOS policy.
- **Window switcher:** while you type in a password field macOS hides keystrokes from every app, so ⌘Tab shows macOS's own switcher there. If Tutto quits or crashes, macOS's ⌘Tab is back immediately (nothing in the system is switched off). It relies on private window-server calls to list windows on other Spaces and switch to them; a window on another Space that nothing has touched since its app started is reached through that app's Window menu. Video that apps protect from capture shows as a dark picture.
- **Scrolling strip:** macOS doesn't let an app hide another app's window, so a window out of view waits at the left or right edge of its display with one point showing (level with the screen, so Mission Control shows every window at its usual size). Strip keys are caught before other apps' shortcuts (so they win while the strip is on), except in password fields, where macOS hides keystrokes; there the regular shortcut answers if no other app took the keys first. A three-finger swipe can clash with macOS's own swipe between full-screen apps: Mac Setup on the strip's page points out the setting.
- **Stay Awake:** the lid works through macOS's own sleep switch (`pmset disablesleep`), held by Tutto's helper only for the session; the helper keeps the end time itself, so a Tutto that quits or stops can't keep the Mac on past it, and paused apps are resumed at once if Tutto goes away. macOS ignores a display-sleep request while an app holds the display on (a sound or video playing), so after 30 s Tutto dims the display and keyboard light to 0 through private controls checked on macOS 26 (on another version they're left on and the page says so), and puts back the level sampled while the lid was open. On Apple silicon, closing the lid disconnects the built-in microphone in hardware, so a call or recording with the lid shut needs another mic. Some browsers slow down pages in windows nobody can see, which includes every window under a closed lid. Use it on a desk, not in a bag: a working Mac makes heat.
- **Shortcut clashes:** if another app registers the same keys, macOS may deliver them to both apps. Change one of the shortcuts.
- **Not included:** remote, clock and Bluetooth monitoring, alerts, scrolling capture, pinned screenshots, blur, cloud upload, an app launcher.

## Development

```bash
swift test                               # 356 XCTest + 48 Swift Testing tests (corner engine, readers, archives, clipboard, layout, themes, plugins…)
scripts/build.sh --debug                 # debug build with offscreen UI snapshots:
build/Products.noindex/Tutto.app/Contents/MacOS/Tutto --snapshot /tmp/shots panel battery editor
scripts/measure.sh 180 Tutto <OtherApp> …           # idle CPU / memory / wake-ups, side by side
scripts/measure-modules.sh 90            # idle cost per module combination
```

Layout: `Sources/TuttoKit` (testable logic: Trackpad Corner engine, system readers, sensors/fans, archives, clipboard store, window layout, shortcuts), `Sources/Tutto` (app and UI), `Sources/TuttoFinder` (Finder extension), `Sources/TuttoHelper` (root fan helper), `Sources/CBridges` (C shims for MultitouchSupport, SMC, IOHID and libarchive). Requirements and their status: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Test results: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md).

## License

MIT. libarchive (BSD) ships with macOS. Labels are set in [Geist](https://github.com/vercel/geist-font) 1.8.1 (SIL Open Font License 1.1, bundled with its license in `Resources/Fonts`).
