# Tutto — requirements checklist & acceptance criteria

Source of truth: `~/Documents/Codex/2026-10-10/this/outputs/macos-app-specification.md`.
Status legend: `[ ]` not started · `[~]` implemented, not yet verified on device · `[x]` implemented **and** verified (how is noted) · `[!]` blocked / OS-limited (reason noted) · `[-]` removed by design (reason noted).

Test machine: MacBook Pro 14" (Apple M5, 4 Super + 6 Efficiency cores, 10-core GPU, one fan), macOS 26.5.2, Xcode 26.6.

## APP — shell, settings, modules

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| APP-1 | Menu bar icon (aesthetic) opens a compact panel | Template glyph renders in light/dark menu bar; click opens panel ≤ 150 ms | [x] Live 2026-10-26 (build 86): a click on the status item shows the panel in 66–159 ms (475 pt, glass material, real readings) and a second click closes it in 22 ms; the "tt" template glyph sits between the system's play and Bluetooth items at their weight. ⚠️ On a crowded notched menu bar the icon can sit behind the notch — Tutto detects this and explains (toast + Overview) |
| APP-2 | Main app window opens like a normal app (Spotlight "Tutto", Finder, `open`) | Launch or reopen shows main window, Dock icon while open, hides from Dock when closed | [x] Live: reopen (`open Tutto.app`) shows the main window with sidebar; Dock icon while open. Spotlight launch of the installed copy still to be confirmed by the user |
| APP-3 | Every module can be turned off independently | Toggle in General + each page header; disabled module stops all timers/taps/hotkeys/extension; verified by measuring CPU/wakeups and checking taps/hotkeys removed | [x] Live: Trackpad Corner switch → event tap 1→0→1; Archives off → Finder extension `-`; all modules off → 0 % CPU, 0.02 wakeups/s; per-module idle costs measured |
| APP-4 | Shortcut recording & customization | Click recorder → press combo → saved & live; Esc cancels, ⌫ clears; duplicate & system-conflict warnings; "Reset to defaults" | [x] Live in the running app: ⌃⌥⌘J recorded and stored, conflict refused ("Already used by “Open Tutto”"), bare key refused ("Add ⌘, ⌃ or ⌥"), Esc cancels, Delete removes, Restore Defaults restores; custom shortcuts fire globally (⌃⌥⌘2/3/B/V/L/M verified); reserved-shortcut warnings; the Shortcuts page carries a general tip that macOS may deliver keys shared with another app to both; 5 unit tests |
| APP-5 | Default shortcuts preserved | ⌃⇧V clipboard, ⌃⇧B window palette, ⌘⇧2 area→clipboard, ⌘⇧1 full screen→clipboard, ⌘⇧6 area→editor (was ⌘⇧`, which is macOS's "back through an app's windows"; moved 2026-10-24, and a unit test keeps every default off macOS's own shortcuts) | [x] Defaults set in code and shown in the UI; ⌘⇧1 verified live (if another app registers the same keys, macOS delivers them to both — see the tip on the Shortcuts page) |
| APP-6 | Settings for everything necessary | Open at login, per-module options, reset, about | [x] Open at login (SMAppService), per-module settings pages, Restore Defaults, About |
| APP-7 | Permissions overview | Live status + request button for Accessibility, Screen Recording, Finder extension, fan helper; says exactly which features need which | [x] Live: Permissions page shows live status; first capture without permission opened System Settings › Screen & System Audio Recording with Tutto listed |
| APP-8 | Clear on first look & install | First-run welcome: modules, permissions, shortcuts cheat sheet | [x] Installed app from clean settings via LaunchServices, over a full-screen app: welcome window on screen and centered where you land (two Space bugs found and fixed); four steps walked with live permission states; close button completes first run without adding a login item; Done (which also turns on Open at login when its box is ticked) was not pressed, to avoid adding a login item on this Mac; Spotlight lists only the installed copy (duplicate found, fixed) |
| APP-9 | ~~Notices about other running apps~~ | — | [-] Removed by design: Tutto no longer detects or lists other apps (menu bar notice, Overview list and per-shortcut clash warnings all removed). The menu bar panel shows only missing-permission notices; the Shortcuts page has a general tip: "If another app uses the same keys, macOS may deliver them to both. Change the shortcut here or in that app." |
| APP-10 | The menu bar panel holds only what you click the menu bar for (2026-10-26) | ≤ 480 pt, no uppercase captions: how the Mac is doing, per-app sound, the tools' shortcuts as clickable rows, Open Tutto; settings, Trackpad Corner and clipboard controls in the app (rare toggles in ⋯); a row does what its keys do; the next click on the icon still opens the panel; whatever opens the app closes the panel | [x] Live (build 86): 475 pt (was 716), 0 uppercase captions (was 16). Rows clicked: Capture Area and Capture and Edit → capture overlay (Esc, nothing captured), Clipboard History → palette, Snap Window → window palette, Count Words → word counter; after each, the next click on the icon opened the panel. Open Tutto, CPU and Memory → the app's window on that page, panel closed. Found and fixed: after a row, the next click on the icon did nothing (the row closed the panel's window behind SwiftUI's back; it now closes through the icon's button); Open Tutto left the panel open over the window |
| APP-11 | An identity for an all-in-one utility (2026-10-26) | App icon from Icon Composer that holds up in every appearance, and a matching menu bar template glyph; no Trackpad Corner tile | [x] The double t (`DESIGN.md` §4): ictool renders of the default, dark, tinted and clear looks and at 16/32 px; the installed app's icon as Finder draws it; the glyph in the real menu bar at the system items' weight |

## SYS — system & battery monitor

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SYS-1 | Brief summary in panel: battery, CPU, GPU, RAM, disk | One compact row/tile each; values update ~1 s while visible | [x] Live (build 86): a plain verdict as the stats card's title ("On battery · 15 h 27 min left"), then battery, CPU, memory and temperature as large numbers with meters, and GPU, free disk and network on the same columns beneath; each opens its page (CPU and Memory clicked live); 1 Hz while open |
| SYS-2 | Battery: %, health %, cycles, condition, power, top battery processes | Health is macOS's own Maximum Capacity (System Settings › Battery Health, read from `system_profiler SPPowerDataType`), whole percent, steady through the day; cycles exact; power from PowerTelemetry / V×A; top processes match `top -o power` ordering | [x] Live: health 94 % = System Settings and system_profiler, while the gauge's NominalChargeCapacity ÷ DesignCapacity drifted 93.9 → 93.3 → 92.8 % the same day (the old formula, which caused the reported flicker); cycles 135 = system_profiler; condition Normal; watts from power telemetry; top energy users from `top -o power` |
| SYS-3 | Go deeper for each: CPU, GPU, RAM, disk, battery (+network) | Main-window pages: per-core CPU (Super/Efficiency), load, top CPU processes; GPU utilization/renderer/tiler/memory; RAM breakdown + pressure + swap + top memory; volumes + read/write throughput; network rates; full battery/adapter detail | [x] Pages for Battery, CPU (Super/Efficiency cores, load, top CPU), GPU, Memory (breakdown, pressure, swap, top memory), Disk (volumes, read/write), Network; rendered with live data |
| SYS-4 | No idle cost | Sampling runs only while panel/page visible; stops ≤ 1 s after hiding (verified by wakeups) | [x] Live: `top` 1→0 on close, CPU back to 0.03 %, wakeups 0.12/s. Since 2026-10-26 the panel runs no process list at all: no child process at any 0.1 s sample while open (build 86, 6 openings), 0.0–0.1 % CPU open, 0.00 % after closing |

## FAN — temperatures & fans

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| FAN-1 | View temperatures | All valid IOHID/SMC sensors, junk readings (e.g. −9201 °C) filtered, honest labels | [x] 40+ IOHID/SMC sensors, junk (−9201 °C) filtered; CPU/GPU labels from published SMC key tables (M5) confirmed under load by test; shown in panel and page |
| FAN-2 | View fans | Current / min / max RPM from SMC | [x] 1 fan, 2317–6550 rpm, current speed (0 = stopped) read without root |
| FAN-3 | Edit fan power for heavy tasks | Auto / custom speed / Max via privileged helper; resets to Auto on quit, sleep, module off, or app crash | [x] Live on the M5 after approving the helper: Max set mode 1 / target 6550 rpm and the fan spun from 0 to 6,553 rpm within 10 s (read independently from the SMC); quitting Tutto restored Auto (mode 0, target 0) and the fan stopped. Custom speed and the sleep / module-off / crash resets are implemented but were not exercised live |
| FAN-4 | Honest support states | Shows "needs helper approval", "no fans on this Mac", etc. Never fakes a reading | [x] States for helper not installed / awaiting approval / no fans; never fakes readings |

## CLIP — clipboard history

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| CLIP-1 | ⌃⇧V opens history | Palette appears ≤ 150 ms, search focused | [x] Live: palette opens on the shortcut; search field focused (bug found and fixed: focus didn't reach the non-activating panel) |
| CLIP-2 | Text, images, files, links | Each captured with preview; rich text keeps formatting on paste | [x] Live: text, link, image, file captured; rich text stored as RTF and restored on paste |
| CLIP-3 | Search + type filter | Instant filter; All / Text / Images / Files / Links | [x] Unit tests (search, filters, pins) + palette UI with All/Text/Images/Files/Links (⇥ cycles) |
| CLIP-4 | Paste, pin, delete | Double-click or ↩ pastes into the previous app without changing the clipboard (setting to keep it), ⌘↩ copies only, pin/unpin, delete, clear unpinned | [x] Live: searched "paste test" in the palette, ↩ pasted exactly "tutto paste test 123" into TextEdit (read back via Accessibility); ⌘↩ copy, ⇧⌘P pin, ⌘⌫ delete, ⌘1–9 implemented. Live (after the paste-without-keeping change): double-clicking "tutto paste target 42" in the palette over TextEdit pasted it and closed the palette; the clipboard still held the earlier "ORIGINAL-CLIP", and restoring it added no history entry. With "Keep pasted items on the clipboard" on, the pasted item stayed on the clipboard |
| CLIP-5 | Privacy | Skips password-manager (concealed/transient) items; pause capture; ignore list | [x] Live: concealed (password-manager) item not recorded; pause switch; ignore list with password managers by default |
| CLIP-6 | Persistence | Survives relaunch; size/age limits | [x] Unit tests: persistence with blobs, 500-item limit, 100-image cap, pinned kept |

## WIN — window management

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| WIN-1 | ⌃⇧B → type "left half" → ↩ | Frontmost window snaps to the left half of its screen's visible frame | [x] Live: palette → "left half" → Finder window at (0, 33, 756 × 858) exactly. Windows in native full screen leave full screen first, then snap (verified on Firefox and Claude) |
| WIN-2 | Halves, thirds, quarters, center, maximize, displays | All actions work on the test machine incl. restore | [x] Live: right half, left half, center, restore, thirds (Finder's 536 pt min width respected); geometry unit-tested for all actions incl. displays |
| WIN-3 | Per-action hotkeys | Optional recordable shortcut per action | [x] Live: Left Half on ⌃⌥⌘L → (0, 33, 756 × 858); Maximize on ⌃⌥⌘M → (0, 33, 1512 × 858); every action recordable on the Windows and Shortcuts pages |

## SHOT — screenshots

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SHOT-1 | ⌘⇧2 area → clipboard, no editor | Select area → PNG on clipboard; toast confirms | [x] Live: area → 800 × 600 PNG on clipboard, toast; latency mouse-up → clipboard ≤ 72 ms |
| SHOT-2 | ⌘⇧1 full screen → clipboard | Display under pointer captured at native resolution | [x] Live: 3024 × 1964 PNG on clipboard |
| SHOT-3 | ⌘⇧6 area → editor | Editor opens with the capture | [x] Live: editor opens centered with the capture (placement bug found and fixed) |
| SHOT-4 | Selection overlay | Frozen screen shown exactly as it was (never dimmed, wherever the pointer is); a drag shows a very light box with a fine white-on-dark edge over what it covers, the rest unchanged; before a drag, a thin outline marks the window a click would take; crosshair pointer with its pixel position beside it, live W×H px while dragging, Esc cancels, multi-display safe | [x] Live 2026-10-26, ⌘⇧2 with the pointer on the menu bar, screenshots before and with the overlay compared per pixel: build 82 dimmed the whole screen (mean 38.5 → 31.6, every pixel darker); build 86 shows it as it was (34.2 → 34.5; 0.5 % of pixels differ, a window's 1-px rim). Dragging: inside the box 41.6 → 80.2 (white at 18 %), outside 29.7 → 30.0. Earlier, live: frozen screen; plain crosshair pointer with x over y in pixels just below-right of it (1400 / 840 at (700, 420) pt on this 2× display), flipping to the other side near the edges (2980 / 1920 in the corner); W × H in the same spot while dragging; magnifier and full-screen crosshair lines removed at the user's request; Esc/right-click cancel |
| SHOT-5 | Tab copies color under cursor | Hex of the exact image pixel copied; toast with swatch | [x] Live: Tab copied #222222 (pixel under the pointer), swatch toast |
| SHOT-6 | Freehand draw with thickness & color | Pen tool icon; color swatches + custom; thickness control | [x] Live: Draw tool stroke rendered; 8 colors + any color, 3 thicknesses ([ ]), plus highlight, arrow, rectangle, pixelate |
| SHOT-7 | Click-drag sub-selection with live pixel size; movable, resizable box; crop | Handles, move, resize, crop (↩) | [x] Live: canvas drag → selection with 8 handles + "402 × 202" pill → Crop button (also ↩) → 402 × 202 px result; move/resize handles implemented |
| SHOT-8 | OCR copy text (whole or selection) | Vision OCR → clipboard, line order preserved | [x] Live: "Talk. It types." + two lines OCR'd exactly in order; selection-only OCR supported; QR codes detected |
| SHOT-9 | Save to file, default Downloads | ⌘S writes PNG to ~/Downloads (configurable) | [x] Live: Save wrote "Screenshot 2026-10-10 at 04.02.12.png" to the configured folder (default ~/Downloads; macOS asks once for Downloads access) |
| SHOT-10 | Esc copies and closes | Esc → clipboard (selection if one is drawn) | [x] Live: Esc copied 1280 × 190 image and closed the editor |
| SHOT-11 | Editor shows only screenshot UI | No system readings or other modules in editor | [x] Editor window contains only screenshot tools |

## ARC — archives (full archive extraction)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| ARC-1 | Formats | zip, rar (v4/v5), 7z, tar, gz, bz2, xz, lzma, iso, cab, lha/lzh, xar, cpio, ar … (what macOS libarchive 3.7.4 supports; gaps documented) | [x] 68 unit tests across formats; live: zip, 7z, tar.gz, real RAR4, gz, tar.xz extracted byte-identical |
| ARC-2 | Fix garbled filenames | Non-UTF-8 zip names (Shift-JIS, GBK, CP437, CP1251 …) auto-detected | [x] Unit tests: Shift-JIS (incl. 0x5C trail bytes), GBK, Big5, CP949, CP866, CP1251, CP437, Mac Roman |
| ARC-3 | Finder right-click | Extract Here / Extract to "Name" / Extract to… / Compress, top level of the context menu | [x] Live: Finder right-click on a .rar shows Extract Here / Extract to "library" / Extract to…; Extract Here produced the folder; Compress verified via the same URL path |
| ARC-4 | Open archives directly | Double-click / Open With extracts per preferences | [x] Live: `open -a Tutto open-me.zip` (what double-click does once Tutto is the default) extracted next to it; Make Default button sets Tutto for archive types |
| ARC-5 | Preferences | Destination, create-folder rule, trash after, reveal after, encoding override | [x] Destination, Smart/Always/Never folder rule, trash after, reveal after, encoding override |
| ARC-6 | Progress, cancel, errors, passwords | Progress panel; cancel cleans up; zip passwords prompt; unsupported encryption explained | [x] Live: 3 GB archive → progress panel; Cancel left nothing behind; password prompt panel appears (decryption unit-tested: ZipCrypto, AES, wrong/missing password) |
| ARC-7 | Safety | No path traversal, no writing through symlinks, never overwrites silently | [x] Unit tests: ../ and absolute paths contained, symlink escapes refused, unique names, temp-dir cleanup |

## TC — Trackpad Corner (click or tap in a corner → right-click)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| TC-1 | Click or tap in a corner → right-click, bottom-left or bottom-right | Engine unchanged; its unit tests pass | [x] Engine unchanged; 48 engine tests pass. Live: a physical press in the saved bottom-right zone (touch at 0.740, 0.183) was logged by Tutto as `decided=click result=right`, while presses elsewhere stayed left clicks |
| TC-2 | Two-finger right-click untouched | — | [x] Engine passes native right-click through untouched (unit test with real CGEvents) |
| TC-3 | S / M / L / Custom (mm), drag to size, click other corner to switch | — | [x] S/M/L/Custom mm steppers, drag-to-size, click other corner |
| TC-4 | Tap to click on/off, tap-to-drag timing | — | [x] Tap-to-click on/off and tap-to-drag windows (unit tests + live preference reading) |
| TC-5 | Pause from menu bar, open at login | — | [x] Pause on its page; in the menu bar panel it moved to ⋯ › Pause Trackpad Corner (the same switch; not clicked live); open at login (app-wide, also in ⋯) |
| TC-6 | Diagnostics log `~/Library/Logs/Tutto/corner.log` | Opt-in toggle, reveal log | [x] Diagnostics toggle + Reveal; one line per trackpad click (verified live before the log moved to its new path) |
| TC-7 | Accessibility flow + Set Up & Test | — | [~] The installed copy without a grant shows the Accessibility card in the welcome window (verified); with a grant (test copy run under an approved process) the corner works. Granting the installed copy is the user's switch in System Settings |
| TC-8 | Robustness: sleep/wake, hot-plug, stale stream, trust watchdog, menus, typing | — | [x] Engine's sleep/wake, hot-plug, stale-stream, watchdog, menu and typing rules kept; engine now also releases IOKit notifications when switched off |
| TC-9 | Panel section more minimal (no right-click counter) | — | [-] Superseded 2026-10-26: Trackpad Corner left the menu bar panel (its controls are on its page; Pause is in ⋯) |
| TC-10 | ~~One-time settings import; warning when another app is running~~ | — | [-] Removed by design: no settings import and no running-app warning; Trackpad Corner keeps its own settings (`corner.*`) |

## WC — Word Counter (⌃⇧C)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| WC-1 | ⌃⇧C opens a panel with the cursor already in the text, so ⌘V pastes immediately | Default shortcut ⌃⇧C, re-recordable; text focused on open; ⌘V pastes | [x] Live with the real ⌃⇧C (another launcher app, which also binds it here, quit for the test): ⌃⇧C → panel with the cursor in the text → ⌘V → 7 words, 37 characters. Earlier, with a stand-in shortcut: shortcut → panel → ⌘V pasted the clipboard and counted it. Default ⌃⇧C shown on the Shortcuts page. Bugs found and fixed: focus was requested before the text view was in the window; ⌘V relied on Tutto's Edit menu, which a non-activating panel never reaches (editing keys now go straight to the text) |
| WC-2 | Called "Word Counter" in the UI; shows words and characters plus more | Words, characters, characters without spaces, sentences, paragraphs, reading time, speaking time, selection counts | [x] All shown; selection counts appear when part of the text is selected |
| WC-3 | Counts match word-processor rules | Hyphenated words, contractions, numbers = 1 word; lone dashes = 0; emoji = 1 character; CJK/Thai split by the system word breaker; paragraphs = non-empty lines | [x] 9 unit tests (`TextStatsTests`) |
| WC-4 | Fast, light | Counting inline under 20,000 UTF-16 units, off the main thread above (edits coalesced); nothing runs until opened; panel released on close | [x] Live on the installed app: never opened, Tutto settles at 14 MB / 0.0 % CPU (unchanged); a 1 MB paste (180,000 words) counted within 0.32 s of ⌘V; 77 MB while showing that 1 MB of text, 28 MB 15 s after closing, CPU back to 0.0 %; six open/paste/close rounds stayed at 32–38 MB (no growth) |
| WC-5 | Fits the rest of Tutto | Same palette shell, tokens and components; own page in Tools with shortcut, reading speed and on/off; welcome window, Overview, Shortcuts, menu bar quick action, `tutto://do/word-counter` | [x] All wired; renders reviewed; newly added tools start on even when an earlier on/off choice was saved (`modules.known`) |

## SND — Sound (mute apps at the speakers)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SND-1 | Mute a chosen app at the speakers while other apps keep playing | Core Audio process tap (`CATapMuted`) in a private auto-start aggregate device; other apps unaffected | [x] Raw microphone (HAL, no voice processing): 28/28 muted pings silent (median −121 dB = room floor, loudest −99.5 dB) vs 8/8 unmuted at −60 dB; a second app kept playing unchanged (−77 dB) while the first was muted |
| SND-2 | A muted app's audio stays available to other tools ("Claude can still hear it") | An independent tap on the muted app still receives its audio | [x] Independent tap on the muted test app: −11 dBFS throughout (−27 dBFS in the A/B probe), unchanged by the mute |
| SND-3 | Pick from the ⌘Tab apps, not Finder; helpers count as their app | Running apps with activation policy `.regular` minus Finder and Tutto; sound processes matched by responsible PID, bundle path, parent chain | [x] Live: Discord's 4 sound processes, Opera GX's 3 (bundle ID `com.operasoftware.Opera.helper`) and Claude's 3 all attributed to their app; 8 unit tests (`AudioOwnershipTests`) |
| SND-4 | Costs nothing while a muted app is quiet | The device starts only when a muted app plays and is re-armed 0.5 s after it goes quiet | [x] No `PreventUserIdleSystemSleep` assertion and 0.0 % CPU while the muted app is silent; device stops/re-arms each ping (log) |
| SND-5 | Compact, fits Tutto | Panel Sound card of app icons (muted = grey + slash badge, playing = speaker badge in the accent, `+N` menu past 8; "Unmute All" only while an app shown is muted, leaving apps muted while closed alone); Sound page with switches, muted-while-closed list, shortcut | [x] Live (build 86): a silent app's icon clicked → muted, clicked again → unmuted (the stored list read each time); "Unmute All" shown only while it was muted; the two apps muted while closed stayed muted. Found and fixed: "Unmute All" showed for apps muted while closed, with nothing greyed, and would have unmuted them |
| SND-6 | Persistent | Muted apps stay muted after they relaunch and after Tutto restarts (bundle IDs in defaults) | [~] Stored and re-applied on process-list changes; live relaunch check was cut short |

## SW — Window Switcher (⌘Tab)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SW-1 | ⌘Tab shows every window, not every app (each Firefox window separately) | Windows on every Space, full screen, minimized and hidden apps; helper surfaces, sheets, invisible and toolbar windows left out (window-server flags) | [x] Live on a Mac where every app is full screen on its own Space: 3 Firefox windows + ChatGPT, Discord, Claude, Notion (Desktop 1) and Finder (no windows) = 8 cards; 11 admission/title/order tests against flags read from this Mac |
| SW-2 | Takes over ⌘Tab safely | Session event tap swallows ⌘Tab only; macOS's switcher never appears while Tutto runs and works again the instant Tutto dies | [x] Real HID ⌘Tab: Tutto overlay up, macOS switcher absent; after `kill -9` the macOS switcher appeared on the next ⌘Tab; heartbeat releases the keyboard if the switcher stops checking in (unit test) |
| SW-3 | Switches to the exact window, across Spaces | Element (remembered, window list or remote token) + make-key + raise; the app's Window menu for a window with no element yet | [x] Quick tap Firefox → other Firefox window (other full-screen Space) and back; Tab Tab → ChatGPT; never-visited lecture window reached via Firefox's Window menu (log) |
| SW-4 | Feels native | Hold ⌘ + Tab, release switches; quick tap = previous window without UI; reveal after 0.1 s; ⇧Tab/arrows/1–9/Return/Esc/click | [x] Quick tap switched with no overlay; list built in 9–18 ms (41 ms first); overlay at +121–150 ms |
| SW-5 | Acts on windows from the switcher | W close (card stays until really closed), M minimize, Q quit, H hide, F/C/N place via Windows | [~] Wired; not exercised live on the user's own windows |
| SW-6 | Rename windows | R names the selected window; the name follows the window and finds it again after the app restarts (title, else unique place) | [x] Live: "school" stored for the lecture window and shown on its card; 2 matching tests (restart by title, no jump when ambiguous, 14-day expiry) |
| SW-7 | Search and same-app view | `/` filters by name, title, app (names rank first); ⌘\` or \` shows only one app's windows | [x] Live: "lecture" → 1 of 8; ⌘\` → "Firefox windows 3"; ranking tests |
| SW-8 | Light | No polling; pictures only while open, 2 at a time, cache dropped 30 s after closing | [x] Idle 0.0 % CPU, 28 MB; after one use with 8 pictures 30 MB, unchanged 40 s later |
| SW-12 | Pictures always show the whole window | Window server capture first; when that's clipped (a window partly or wholly off screen), ScreenCaptureKit's single-window capture; if neither gives the whole window, the app icon. Pictures are taken only while they're on show (STRIP-18); the switcher uses the strip's for parked windows when it has them | [x] Root cause measured (the window server returns only the on-screen part: 1×122 for a parked 640×452 window); after the fix every picture in ⌘Tab and the strip bar matched its window's shape within 0.3% (17 checked, 3 windows parked); screenshots |
| SW-10 | The pointer only picks a card when it moves | A pointer resting where the switcher opens, or a card sliding under a still pointer, changes nothing; moving it selects the card under it; clicking switches | [x] `PointerIntentTests`. Reported broken hover/click after the first version (SwiftUI's continuous hover goes quiet while another app is active); now the panel follows the pointer itself (30 Hz while open) and takes clicks through a local mouse-down monitor. The first pick needs 10 pt from where the pointer was at opening (a hand resting on the mouse; in a game the pointer sits mid-screen, where the switcher opens), 2 pt after that. [x] On screen (Roblox Studio and Roblox in full screen): the pointer resting on a card and nudged 4–6 pt picked nothing, a 30 pt move picked the card under it |
| SW-11 | Switching to Tutto's own window is safe | Tutto's own windows are raised, closed and minimized on the main thread, never through Accessibility from a background queue | [x] Diagnosed from 3 crash reports (07:02–07:03): `WindowFocus.focus` → `AXUIElementPerformAction(raise)` on Tutto's own window from a background queue ran AppKit's `makeKeyAndOrderFront` off the main thread → "Must only be used from the main thread" abort, each time ⌘Tab picked the Tutto window. Fixed in the switcher (own windows handled directly) and in `WindowFocus` and the strip's mover (own process refused off the main thread); lab `--switcher-lab … ownfocus` survives |
| SW-13 | ⌘Tab from an app in full screen | "This Space" from a full-screen app's Space shows every window (the app has its Space to itself); the window you're in is the front app's frontmost card on screen, not a helper surface it keeps above it (Roblox Studio, games), so the first press goes to the previous window; from a desktop, apps in full screen show as windows with their pictures, in most-recently-used order (each has its Space to itself: the game you just left is one press away); an app whose windows are all on other desktops says "Windows on other Spaces" and sits where the one of its windows you used last would, with or without "Apps with no windows open", and a window of it minimized here doesn't hide it; W on that card does nothing (quitting would close every window it has elsewhere); other apps with no window come most recently used first | [x] Reported: from Roblox Studio and Roblox, every other app was an icon card saying "No windows open" in launch order and Finder was selected (screenshot, "8 cards, selected 1"); from Desktop 1 the game you'd just left was an icon card after every window. Causes: "This Space" from a full-screen Space; untitled helper surfaces above Studio's and the game's window taken for the window you're in; recency and Accessibility handles dropped for windows on other Spaces; parked strip windows can't be photographed from another Space (now photographed whenever their Space shows). After, on the installed app: from Roblox Studio and from Roblox all 9 windows as cards with their pictures plus Finder, the window used before selected ("10 cards, selected 1"); from Discord on Desktop 1, Roblox second and selected, one quick ⌘Tab landed on Roblox and the next one back on Discord; from Finder at the desktop the last window used was selected ("selected 0"). A second reader's review found 7 more edge cases (minimized windows, W on that card, Finder at an empty desktop, recency with options off, main-thread cost, a weak test), all fixed. 6 new unit tests. Reported next: from Discord, ⌘Tab showed Roblox in full screen as that icon card, no picture. Not Roblox, not a saving: the window server gives its whole picture from Desktop 1 (1512×949 in 39 ms, lab), so full-screen apps now show from a desktop too. Before/after on the installed app: icon → Roblox's picture, second and selected; a quick ⌘Tab went into Roblox (in front at +249 ms) and the next back to Discord |
| SW-9 | Fits Tutto, not in the panel | Own page (trigger ⌘Tab/⌥Tab, scope, what to show, keys, renamed windows, leave-out list), Shortcuts group, Permissions; nothing added to the menu bar panel | [x] Rendered light and dark |

## STRIP — Scrolling Strip (optional, off by default)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| STRIP-1 | A setting turns Tutto into a scrolling window manager: every window side by side on one strip, full height, the screen scrolling along it | Own module, off on new installs and upgrades; a switch on its page and on the Window Switcher page; nothing in the menu bar panel | [x] Live with 4 test windows on Desktop 1: started tiled at once, 744 pt (50 %) columns, y 41 / height 843 = menu bar to Dock with 8 pt gaps; module default checked in `AppModel` (new tools start on, except this one) |
| STRIP-2 | Every action on a rebindable ⌃⌥ shortcut | 55 commands (focus ←→↑↓, first/last, 1–9, move, move to 1–9, cycle width, full width, centre, wider/narrower, taller/shorter, equal heights, pin left/right, stack left/right, pop out, tabbed, float, next display, show, stop) on the Shortcuts page; defaults unique and all ⌃⌥ (unit test) | [x] Live: ⌃⌥R, F, C, 1–9, ⇧1, ], [, ⇧], ⇧T, P, T, -, =, Q, S all acted. Another app on this Mac had registered ⌃⌥←/→ first, so they first went to it; now a key filter in front of the session takes the strip's keys (the registrations stay underneath for password fields) and ⌃⌥→ reached the strip with that app still running |
| STRIP-3 | Widths like the original: cycle 25 → 33 → 50 → 66 → 75 → 25 %, full width toggles back, wider/narrower in 10 % steps, presets editable | Model + geometry; 50 % + 50 % fill the screen gaps included | [x] Unit tests (cycle order, toggle back to 50 %, widths 485/485/980 on a 1000 pt area); live: 744 → 995 (67 %) → 1496 (full) → 995, 844 (57 %) |
| STRIP-4 | Viewport scrolls just far enough; centre modes never / when it overflows / always; ⌃⌥C centres | Never rests past the strip's ends except after an explicit centre | [x] Unit tests; live: focusing the 3rd window scrolled exactly until its right edge met the screen's (x −243 / 760), ⌃⌥C put window 1 in the middle (x 259) |
| STRIP-5 | Out-of-view windows are kept on their own display | Parked in a bottom corner with one point showing (left corner for windows off the left), never spilling onto another display | [x] Live: x 1511 (right) and maxX 1 (left); macOS keeps the title bar above the Dock so 1 × 31 pt shows; unit test for the other-display case (this Mac has one display) |
| STRIP-6 | Stacks and tabs | Stack into the left/right column, pop out right/left, focus and move up/down, taller/shorter/equal heights, tabbed ↔ stacked with a clickable tab bar | [x] Live: stack → 418/417 pt halves with an 8 pt gap; tabbed → one window 815 pt under a 22 pt tab bar showing both titles, the other parked; back to a 3-window stack 276/275/276; pop out → full height again. Found and fixed: a window growing taller from low on the screen was clamped by macOS (424 pt) until it now moves to its new top first |
| STRIP-7 | Pinned columns | ⌃⌥P / ⌃⌥⇧P keep a column at the left/right edge, full height, while the rest scrolls in what's left; same key unpins | [x] Unit tests; live: window 1 stayed at x 8 while the tabbed column scrolled in at x 1011 |
| STRIP-8 | Windows come and go cleanly | New windows open beside the focused one (background apps' at the end, without focus); closing collapses the gap; minimized, hidden and full-screen windows come back to their slot; dialogs, Quick Look, picture in picture and fixed-size windows float; native full screen left alone; native tabs share one column | [x] Live: closing a stacked window re-flowed the stack; minimize → gone, restore → same slot with focus; float (⌃⌥T) → centred 995 × 687 off the strip, tile again → back beside the focused window. Rules unit-tested. [~] Native tabs, hidden apps and full-screen round trips are wired but not exercised live (the test app has no tabs) |
| STRIP-9 | Mouse and trackpad | Drag a window onto another column to reorder; resize by hand keeps the new width; ⌃⌥ + scroll (one window per notch, trackpad follows the fingers and settles); 3/4-finger swipe (snap or free) | [x] Live: dragging window 1 by its title bar onto the left column reordered the strip; wheel notches with ⌃⌥ moved focus and refused at the end; a trackpad-style ⌃⌥ scroll followed and settled on a column (focus moved to the window in view), stretched and sprang back when the strip fits. [~] Hand resizing and the 3/4-finger swipe (needs real trackpad touches) not exercised live |
| STRIP-10 | Strip indicator, focus border, dimming | Frosted bar of app-icon tiles (focused outlined, out-of-view faded, stacks/tabs shown, caption of what happened) that fades, stays while ⌃⌥ is held, click a tile to jump, drag to reorder; optional border and dimming | [x] Screenshots: tiles with faded parked column and outlined tabbed column; border around the focused window with the others dimmed (menu bar and Dock untouched). Found and fixed: the caption was cut off (the bar now fits its text) |
| STRIP-11 | Stopping is safe | ⌃⌥Q, switching it off, quitting and `kill` put every window back on screen; a crash leaves no window out of view after the next launch; layout (order, widths, stacks, tabs, pins) comes back after a restart | [x] Live: SIGTERM with two windows parked → both back on screen at x 0; relaunch restored the same order, the 67 % width, the tabbed column and the focus. Crash rescue runs at launch from the parked list (not exercised with a real crash) |
| STRIP-12 | Responsive and light | Key → first window move ≤ 30 ms; spring animation; nothing runs while windows sit still | [x] First move 5–32 ms after the key (log); a slide settles in 43–49 frames at 120 Hz (Smooth); idle 0.0 % CPU, no new wakeups, 16 MB for a test build running only the strip |
| STRIP-15 | Not rigid: windows move only when you ask | "Arrange windows: On a strip key" (default) — windows you move yourself or with the window palette stay put, new/closed/minimized windows only change the strip's order, a click never scrolls; the strip lays out on a strip key, ⌃⌥ + scroll, a swipe, or ⌘Tab to a window that's out of view. "All the time" keeps the always-arranged behaviour | [~] Built; reported problem (⌃⇧B "center" on Notion snapped back) traced to the strip re-applying its layout after outside moves |
| STRIP-16 | Hold ⌃⌥ to see the strip bar, let go and it's gone; bigger; window pictures; icons while sizing | Appears as ⌃⌥ go down, stays while held (keys update it in place, the focus outline slides between tiles on a spring, pictures never animate), fades out on release; out-of-view tiles dimmed with an opaque shade. A size key (⌃⌥R, F, −, =, heights) turns the bar from pictures to icons for the rest of the hold, by crossfading two bar windows (one redraw, before the window starts moving) | [x] Shown 13–20 ms after hold, up for the whole hold, gone ≤ 124 ms after release, 5/5; 54-frame film while stepping; screenshots |
| STRIP-17 | Smooth resizing; ⌃⌥R goes up to full width | Width, height and position follow one spring each frame, sent in an order that never overlaps neighbours; ⌃⌥R cycles 25 → 33 → 50 → 66 → 75 → Full → 25 and Full by ⌃⌥R is the same as ⌃⌥F | [x] 17–28 intermediate widths, settled 217–298 ms, gap never below its size; width sequence and ⌃⌥F return verified live and by unit tests |
| STRIP-18 | Window pictures only while they're on show | macOS marks any app that takes a picture of another app's window as "capturing your screen" (even the window server's own capture: measured). The strip bar takes its pictures only while it's up with pictures; the switcher only once it's on screen (until then the pictures kept from the last 30 s show); nothing is photographed as windows slide away, on a Space change or at start; a window gone out of view keeps its last picture until a fresh one is taken while one is on show (the switcher's fresh ones go to the bar too). Pictures stay in memory | [x] Reported: "Tutto is capturing your screen" while just switching. Before, on the installed app: 6 quick ⌘Tabs between strip windows → 31 capture marks (Control Center's log), ⌘Tab held with the switcher up → 2. After: 0 and 3. A window coming into view under ⌃⌥→ showed its picture 0.3 s later (no icon), fresh by 1.5 s |
| STRIP-19 | Hide the Dock (optional, off by default) | While the strip runs with it on, the Dock's "Automatically hide and show" is turned on (the Dock's own calls: at once, no restart), the strip's windows take the room down to the bottom of the screen and the Dock slides up at the bottom edge, as for an app in full screen. Turning it or the strip off, quitting, or the next launch after a crash puts it back, and windows are let go above it; only a Dock Tutto hid is touched (one you hide yourself, or bring back while the strip runs, is left as you set it) | [x] `StripDockTests` (the rules). Live, once turned on: the Dock's auto-hide on, usable area to the bottom (949 of 982 pt high), the focused window's bottom 884 → 974 pt (the 8 pt gap), the strip bar at the bottom edge; quitting Tutto brought the Dock back and the relaunch hid it again |
| STRIP-14 | Works for someone whose apps all live in native full screen | The page counts windows in full screen and "Bring Them Here" takes each out of full screen onto the strip at full width, in Mission Control's order; turning the strip on says what to do; a strip key pressed in a full-screen app explains why nothing moved | [~] Built and unit-tested where pure; not pressed on this Mac's real apps (the user decides) |
| STRIP-13 | Mac Setup | Checks separate Spaces, rearranging Spaces, Stage Manager, edge tiling, and swipe conflicts, each with a button to the right settings pane | [x] Unit tests; page rendered from the live reading |

## UX — design

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| UX-1 | One coherent minimal design system, light & dark | Shared tokens/components; screenshots in both appearances | [x] One design system (ink tokens, hairlines, mono captions, shared controls) across panel, window, palettes, editor; light + dark renders reviewed; the menu bar panel follows `DESIGN.md` (cards on one grid, one accent) |
| UX-2 | Smooth, accessible motion | Springs ≤ 0.45 s; Reduce Motion → fades; nothing animates while idle | [x] Motion tokens ≤ 0.40 s, Reduce Motion fades, keyboard surfaces appear instantly, no continuous animation (removed per-second value animations after profiling) |
| UX-3 | Accessibility | VoiceOver labels, keyboard navigation in palettes/editor, contrast AA | [x] `scripts/ax-audit.swift` live: 0 unlabeled controls across all 16 pages and the menu bar panel (fixed: encoding picker, archive Cancel); editor controls labeled; palettes and editor fully keyboard-operable; AA-tuned ink opacities. Not done: a formal contrast audit under Increase Contrast. The new panel (2026-10-26): 19 controls, 0 without a name (found and fixed: the four large numbers had lost their button role) |
| UX-4 | Research-informed | `docs/research/ui-ux-research.md` applied | [x] `docs/research/ui-ux-research.md` (verified X posts) applied: monochrome instrument style, system glass only, instant palettes, numeric typography, no idle animation |

## PERF — budgets (measured with `scripts/measure.sh`)

Baseline: separate single-purpose utilities covering the same jobs, idle for 3 minutes on the test machine (2026-10-10):

| Utility | CPU % | Footprint | Idle wakeups/s |
|---|---|---|---|
| System monitor (menu bar values on) | 1.761 | 211 MB | 1.04 |
| Launcher with clipboard history + window management | 0.022 | 104 MB | 0.26 |
| Screenshot tool | 0.000 | 81 MB | 0.09 |
| Trackpad corner right-click utility | 0.005 | 25 MB | 0.04 |
| **Combined** | **1.788** | **421 MB** | **1.43** |

(No separate fan-control or archive utility was running.)


| ID | Budget | Status |
|---|---|---|
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % (avg over 3 min) | [x] 0.011 % (90 s, user away) |
| PERF-2 | Idle wakeups ≤ 1 /s | [x] 0.05 /s |
| PERF-3 | Idle memory footprint ≤ 45 MB | [x] 13 MB (30 MB after the panel has been opened) |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wakeups ≤ 0.5 /s | [x] 0 %, 0.02 /s |
| PERF-5 | Panel open (1 Hz updates): CPU ≤ 3 % | [x] 0.0–0.1 % for Tutto and no child process (build 86, 6 openings, 2026-10-26); earlier 1.5 % (was 15.5 % before that fix) |
| PERF-6 | Lighter than the four separate utilities in the baseline combined | [x] 0.011 % / 13–30 MB vs 1.788 % / 421 MB combined |
| PERF-7 | Hotkey → selection overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | [x] overlay 60–121 ms; mouse-up → clipboard 0–72 ms |
| PERF-8 | App bundle ≤ 15 MB | [x] 8.0 MB |

## Spec traceability

Every request in the specification (re-read in full 2026-10-10, 2,673 words) mapped to requirements above.

| Spec says | Covered by |
|---|---|
| Battery and system monitor: click the menu bar icon to see readings; battery, health % (as macOS reports it), cycles, condition, power, top processes using battery | APP-1, SYS-1, SYS-2 |
| Temperatures and fans: view temperatures, edit fan power for heavy tasks | FAN-1 … FAN-4 |
| Clipboard history on ⌃⇧V (Control, not Command); images, text and more in a clean UI; search, paste, pin, content-type filter | CLIP-1 … CLIP-6, APP-5 |
| Window management: ⌃⇧B, type "left half"/"right half"; halves, thirds, quarters, center, maximize, between displays | WIN-1 … WIN-3 (moving between displays is unit-tested only: this Mac has one display) |
| ⌘⇧2 select area → clipboard (no editor to dismiss) | SHOT-1 |
| ⌘⇧1 whole screen | SHOT-2 |
| ⌘⇧6 select area → editor | SHOT-3, SHOT-4 |
| Tab copies the color under the cursor | SHOT-5 |
| Freehand draw from an icon, with brush thickness and color | SHOT-6 |
| No tool: drag a box with live pixel size, move and resize it, crop | SHOT-7 |
| Copy all text in the screenshot (or the selected part) easily | SHOT-8 |
| Save to a file, defaulting to Downloads | SHOT-9 |
| Esc copies the screenshot | SHOT-10 |
| Editor is screenshot-only (no battery etc.) | SHOT-11 |
| Full archive extraction: RAR, 7z, zip, tar/gz/xz, ISO, CAB…; garbled filenames fixed; extract/compress options in the Finder right-click menu | ARC-1 … ARC-7 |
| Trackpad Corner: click or tap in a corner → right-click, either bottom corner, two-finger kept, S/M/L/custom drag, tap-to-click, pause, open at login, log file, Accessibility | TC-1 … TC-9, APP-6 |
| Trackpad Corner controls in the menu bar panel, without the right-click counter | TC-9 |
| Menu bar icon looks good; panel shows very brief battery/CPU/GPU/RAM/disk with a way to go deeper; Trackpad Corner; optional clipboard settings | APP-1, SYS-1, SYS-3, TC-9, CLIP (pause + count in panel) |
| Open the app from Spotlight as a full app with in-depth CPU, GPU, RAM, disk, fans | APP-2, SYS-3, FAN-1/2 |
| Change shortcuts there, with recording | APP-4 |
| Settings for anything necessary | APP-6 |
| Turn off every feature, and an off feature must not waste battery | APP-3, PERF-4 |
| Clean, minimal, smooth, professional; smooth animation; clear on first look and install | UX-1 … UX-3, APP-8 |
| Research X / social posts on UI/UX trends | UX-4 (`docs/research/ui-ux-research.md`) |
| Very light on CPU/memory/battery; as good as or better than separate single-purpose utilities | PERF-1 … PERF-8 (`docs/PERFORMANCE.md`) |
| 2026-10-26: declutter the menu bar panel (keep per-app sound, the stats polished, Open Tutto; shortcut rows to click instead of pressing keys; Trackpad Corner and clipboard out); rework the app icon and the menu bar icon | APP-10, APP-11, SYS-1, SND-5, TC-5, TC-9 (`DESIGN.md`) |
| 2026-10-26: a screenshot never darkens before a click; a drag shows a very light box, the rest unchanged | SHOT-4 |
| Investigate the trackpad-corner engine source and macOS APIs; modular architecture; measurable acceptance criteria; identify permissions and OS limits | This file; `docs/research/macos-api-research.md`; README › Permissions / Limitations |
| Test everything before finishing | `docs/TEST_RESULTS.md` |
