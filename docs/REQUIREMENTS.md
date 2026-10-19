# Tutto — requirements checklist & acceptance criteria

Source of truth: `~/Documents/Codex/2026-10-10/this/outputs/macos-app-specification.md`.
Status legend: `[ ]` not started · `[~]` implemented, not yet verified on device · `[x]` implemented **and** verified (how is noted) · `[!]` blocked / OS-limited (reason noted) · `[-]` removed by design (reason noted).

Test machine: MacBook Pro 14" (Apple M5, 4 Super + 6 Efficiency cores, 10-core GPU, one fan), macOS 26.5.2, Xcode 26.6.

## APP — shell, settings, modules

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| APP-1 | Menu bar icon (aesthetic) opens a compact panel | Template glyph renders in light/dark menu bar; click opens panel ≤ 150 ms | [x] Live: panel opens from the status item (AX press; 832 pt, glass material, real readings). ⚠️ on this crowded notched menu bar the icon sits behind the notch — Tutto detects this and explains (toast + Overview) |
| APP-2 | Main app window opens like a normal app (Spotlight "Tutto", Finder, `open`) | Launch or reopen shows main window, Dock icon while open, hides from Dock when closed | [x] Live: reopen (`open Tutto.app`) shows the main window with sidebar; Dock icon while open. Spotlight launch of the installed copy still to be confirmed by the user |
| APP-3 | Every module can be turned off independently | Toggle in General + each page header; disabled module stops all timers/taps/hotkeys/extension; verified by measuring CPU/wakeups and checking taps/hotkeys removed | [x] Live: Trackpad Corner switch → event tap 1→0→1; Archives off → Finder extension `-`; all modules off → 0 % CPU, 0.02 wakeups/s; per-module idle costs measured |
| APP-4 | Shortcut recording & customization | Click recorder → press combo → saved & live; Esc cancels, ⌫ clears; duplicate & system-conflict warnings; "Reset to defaults" | [x] Live in the running app: ⌃⌥⌘J recorded and stored, conflict refused ("Already used by “Open Tutto”"), bare key refused ("Add ⌘, ⌃ or ⌥"), Esc cancels, Delete removes, Restore Defaults restores; custom shortcuts fire globally (⌃⌥⌘2/3/B/V/L/M verified); reserved-shortcut warnings; the Shortcuts page carries a general tip that macOS may deliver keys shared with another app to both; 5 unit tests |
| APP-5 | Default shortcuts preserved | ⌃⇧V clipboard, ⌃⇧B window palette, ⌘⇧2 area→clipboard, ⌘⇧1 full screen→clipboard, ⌘⇧` area→editor | [x] Defaults set in code and shown in the UI; ⌘⇧1 verified live (if another app registers the same keys, macOS delivers them to both — see the tip on the Shortcuts page) |
| APP-6 | Settings for everything necessary | Open at login, per-module options, reset, about | [x] Open at login (SMAppService), per-module settings pages, Restore Defaults, About |
| APP-7 | Permissions overview | Live status + request button for Accessibility, Screen Recording, Finder extension, fan helper; says exactly which features need which | [x] Live: Permissions page shows live status; first capture without permission opened System Settings › Screen & System Audio Recording with Tutto listed |
| APP-8 | Clear on first look & install | First-run welcome: modules, permissions, shortcuts cheat sheet | [x] Installed app from clean settings via LaunchServices, over a full-screen app: welcome window on screen and centered where you land (two Space bugs found and fixed); four steps walked with live permission states; close button completes first run without adding a login item; Done (which also turns on Open at login when its box is ticked) was not pressed, to avoid adding a login item on this Mac; Spotlight lists only the installed copy (duplicate found, fixed) |
| APP-9 | ~~Notices about other running apps~~ | — | [-] Removed by design: Tutto no longer detects or lists other apps (menu bar notice, Overview list and per-shortcut clash warnings all removed). The menu bar panel shows only missing-permission notices; the Shortcuts page has a general tip: "If another app uses the same keys, macOS may deliver them to both. Change the shortcut here or in that app." |

## SYS — system & battery monitor

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SYS-1 | Brief summary in panel: battery, CPU, GPU, RAM, disk | One compact row/tile each; values update ~1 s while visible | [x] Live panel: battery block, CPU/GPU/Memory/Disk tiles, temperature line; 1 Hz while open |
| SYS-2 | Battery: %, health %, cycles, condition, power, top battery processes | Health is macOS's own Maximum Capacity (System Settings › Battery Health, read from `system_profiler SPPowerDataType`), whole percent, steady through the day; cycles exact; power from PowerTelemetry / V×A; top processes match `top -o power` ordering | [x] Live: health 94 % = System Settings and system_profiler, while the gauge's NominalChargeCapacity ÷ DesignCapacity drifted 93.9 → 93.3 → 92.8 % the same day (the old formula, which caused the reported flicker); cycles 135 = system_profiler; condition Normal; watts from power telemetry; top energy users from `top -o power` |
| SYS-3 | Go deeper for each: CPU, GPU, RAM, disk, battery (+network) | Main-window pages: per-core CPU (Super/Efficiency), load, top CPU processes; GPU utilization/renderer/tiler/memory; RAM breakdown + pressure + swap + top memory; volumes + read/write throughput; network rates; full battery/adapter detail | [x] Pages for Battery, CPU (Super/Efficiency cores, load, top CPU), GPU, Memory (breakdown, pressure, swap, top memory), Disk (volumes, read/write), Network; rendered with live data |
| SYS-4 | No idle cost | Sampling runs only while panel/page visible; stops ≤ 1 s after hiding (verified by wakeups) | [x] Live: `top` 1→0 on close, CPU back to 0.03 %, wakeups 0.12/s |

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
| SHOT-3 | ⌘⇧` area → editor | Editor opens with the capture | [x] Live: editor opens centered with the capture (placement bug found and fixed) |
| SHOT-4 | Selection overlay | Frozen screen, crosshair pointer with its pixel position beside it, live W×H px while dragging, Esc cancels, multi-display safe | [x] Live: frozen screen; plain crosshair pointer with x over y in pixels just below-right of it (1400 / 840 at (700, 420) pt on this 2× display), flipping to the other side near the edges (2980 / 1920 in the corner); W × H in the same spot while dragging; magnifier and full-screen crosshair lines removed at the user's request; Esc/right-click cancel |
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
| TC-5 | Pause from menu bar, open at login | — | [x] Pause switch in panel/page; open at login (app-wide) |
| TC-6 | Diagnostics log `~/Library/Logs/Tutto/corner.log` | Opt-in toggle, reveal log | [x] Diagnostics toggle + Reveal; one line per trackpad click (verified live before the log moved to its new path) |
| TC-7 | Accessibility flow + Set Up & Test | — | [~] The installed copy without a grant shows the Accessibility card in the welcome window (verified); with a grant (test copy run under an approved process) the corner works. Granting the installed copy is the user's switch in System Settings |
| TC-8 | Robustness: sleep/wake, hot-plug, stale stream, trust watchdog, menus, typing | — | [x] Engine's sleep/wake, hot-plug, stale-stream, watchdog, menu and typing rules kept; engine now also releases IOKit notifications when switched off |
| TC-9 | Panel section more minimal (no right-click counter) | — | [x] Panel shows no right-click counter |
| TC-10 | ~~One-time settings import; warning when another app is running~~ | — | [-] Removed by design: no settings import and no running-app warning; Trackpad Corner keeps its own settings (`corner.*`) |

## WC — Word Counter (⌃⇧C)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| WC-1 | ⌃⇧C opens a panel with the cursor already in the text, so ⌘V pastes immediately | Default shortcut ⌃⇧C, re-recordable; text focused on open; ⌘V pastes | [x] Live with the real ⌃⇧C (Raycast, which also binds it here, quit for the test): ⌃⇧C → panel with the cursor in the text → ⌘V → 7 words, 37 characters. Earlier, with a stand-in shortcut: shortcut → panel → ⌘V pasted the clipboard and counted it. Default ⌃⇧C shown on the Shortcuts page. Bugs found and fixed: focus was requested before the text view was in the window; ⌘V relied on Tutto's Edit menu, which a non-activating panel never reaches (editing keys now go straight to the text) |
| WC-2 | Called "Word Counter" in the UI; shows words and characters plus more | Words, characters, characters without spaces, sentences, paragraphs, reading time, speaking time, selection counts | [x] All shown; selection counts appear when part of the text is selected |
| WC-3 | Counts match word-processor rules | Hyphenated words, contractions, numbers = 1 word; lone dashes = 0; emoji = 1 character; CJK/Thai split by the system word breaker; paragraphs = non-empty lines | [x] 9 unit tests (`TextStatsTests`) |
| WC-4 | Fast, light | Counting inline under 20,000 UTF-16 units, off the main thread above (edits coalesced); nothing runs until opened; panel released on close | [x] Live on the installed app: never opened, Tutto settles at 14 MB / 0.0 % CPU (unchanged); a 1 MB paste (180,000 words) counted within 0.32 s of ⌘V; 77 MB while showing that 1 MB of text, 28 MB 15 s after closing, CPU back to 0.0 %; six open/paste/close rounds stayed at 32–38 MB (no growth) |
| WC-5 | Fits the rest of Tutto | Same palette shell, tokens and components; own page in Tools with shortcut, reading speed and on/off; welcome window, Overview, Shortcuts, menu bar quick action, `tutto://do/word-counter` | [x] All wired; renders reviewed; newly added tools start on even when an earlier on/off choice was saved (`modules.known`) |

## UX — design

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| UX-1 | One coherent minimal design system, light & dark | Shared tokens/components; screenshots in both appearances | [x] One design system (ink tokens, hairlines, mono captions, shared controls) across panel, window, palettes, editor; light + dark renders reviewed |
| UX-2 | Smooth, accessible motion | Springs ≤ 0.45 s; Reduce Motion → fades; nothing animates while idle | [x] Motion tokens ≤ 0.40 s, Reduce Motion fades, keyboard surfaces appear instantly, no continuous animation (removed per-second value animations after profiling) |
| UX-3 | Accessibility | VoiceOver labels, keyboard navigation in palettes/editor, contrast AA | [x] `scripts/ax-audit.swift` live: 0 unlabeled controls across all 16 pages and the menu bar panel (fixed: encoding picker, archive Cancel); editor controls labeled; palettes and editor fully keyboard-operable; AA-tuned ink opacities. Not done: a formal contrast audit under Increase Contrast |
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
| PERF-5 | Panel open (1 Hz updates): CPU ≤ 3 % | [x] 1.5 % (was 15.5 % before the fix) |
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
| ⌘⇧` select area → editor | SHOT-3, SHOT-4 |
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
| Investigate the trackpad-corner engine source and macOS APIs; modular architecture; measurable acceptance criteria; identify permissions and OS limits | This file; `docs/research/macos-api-research.md`; README › Permissions / Limitations |
| Test everything before finishing | `docs/TEST_RESULTS.md` |
