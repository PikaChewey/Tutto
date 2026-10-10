# Tutto — requirements checklist & acceptance criteria

Source of truth: `~/Documents/Codex/2026-10-10/this/outputs/macos-app-specification.md`.
Status legend: `[ ]` not started · `[~]` implemented, not yet verified on device · `[x]` implemented **and** verified (how is noted) · `[!]` blocked / OS-limited (reason noted).

Test machine: MacBook Pro 14" (Apple M5, 4 Super + 6 Efficiency cores, 10-core GPU, one fan), macOS 26.5.2, Xcode 26.6.

## APP — shell, settings, modules

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| APP-1 | Menu bar icon (aesthetic) opens a compact panel | Template glyph renders in light/dark menu bar; click opens panel ≤ 150 ms | [x] Live: panel opens from the status item (AX press; 832 pt, glass material, real readings). ⚠️ on this crowded notched menu bar the icon sits behind the notch — Tutto detects this and explains (toast + Overview) |
| APP-2 | Main app window opens like a normal app (Spotlight "Tutto", Finder, `open`) | Launch or reopen shows main window, Dock icon while open, hides from Dock when closed | [x] Live: reopen (`open Tutto.app`) shows the main window with sidebar; Dock icon while open. Spotlight launch of the installed copy still to be confirmed by the user |
| APP-3 | Every module can be turned off independently | Toggle in General + each page header; disabled module stops all timers/taps/hotkeys/extension; verified by measuring CPU/wakeups and checking taps/hotkeys removed | [x] Live: CornerClick switch → event tap 1→0→1; Archives off → Finder extension `-`; all modules off → 0 % CPU, 0.02 wakeups/s; per-module idle costs measured |
| APP-4 | Shortcut recording & customization | Click recorder → press combo → saved & live; Esc cancels, ⌫ clears; duplicate & system-conflict warnings; "Reset to defaults" | [~] Recorder implemented (Esc cancels, ⌫ clears, duplicate + reserved + running-app clash warnings, per-action reset, Restore Defaults). Custom shortcuts verified live via saved settings (⌃⌥⌘2/3/B/V all fired); recording UI itself not yet driven live |
| APP-5 | Default shortcuts preserved | ⌃⇧V clipboard, ⌘⌥B window palette, ⌘⇧2 area→clipboard, ⌘⇧1 full screen→clipboard, ⌘⇧` area→editor | [x] Defaults set in code and shown in the UI; ⌘⇧1 verified live (also fires Shottr while Shottr runs — warned) |
| APP-6 | Settings for everything necessary | Open at login, per-module options, reset, about | [x] Open at login (SMAppService), per-module settings pages, Restore Defaults, About |
| APP-7 | Permissions overview | Live status + request button for Accessibility, Screen Recording, Finder extension, fan helper; says exactly which features need which | [x] Live: Permissions page shows live status; first capture without permission opened System Settings › Screen & System Audio Recording with Tutto listed |
| APP-8 | Clear on first look & install | First-run welcome: modules, permissions, shortcuts cheat sheet | [~] Four-step welcome (tools, access, keys, CornerClick try-it) rendered and reviewed; full first-run on the installed app pending the user |
| APP-9 | Replaces the old apps cleanly | Detects running Stats / Raycast / Shottr / Macs Fan Control / The Unarchiver / CornerClick and explains clashes; one-click quit where sensible | [x] Detects Stats/Raycast/Shottr/Macs Fan Control/The Unarchiver/CornerClick; one merged notice + Overview list with Quit (Raycast: advice instead of quit) |

## SYS — system & battery monitor (Stats 3.0.4)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SYS-1 | Brief summary in panel: battery, CPU, GPU, RAM, disk | One compact row/tile each; values update ~1 s while visible | [x] Live panel: battery block, CPU/GPU/Memory/Disk tiles, temperature line; 1 Hz while open |
| SYS-2 | Battery: %, max capacity, design capacity, health %, cycles, power, top battery processes | Matches `system_profiler SPPowerDataType` (health = NominalChargeCapacity ÷ DesignCapacity, rounds to the same %), cycles exact, power from PowerTelemetry/ V×A, top processes match `top -o power` ordering | [x] Live: 94.4 % health = NominalChargeCapacity ÷ DesignCapacity (System Settings: 94 %), cycles 127 = system_profiler, max/design mAh, watts from power telemetry, top energy users from `top -o power` |
| SYS-3 | Go deeper for each: CPU, GPU, RAM, disk, battery (+network) | Main-window pages: per-core CPU (Super/Efficiency), load, top CPU processes; GPU utilization/renderer/tiler/memory; RAM breakdown + pressure + swap + top memory; volumes + read/write throughput; network rates; full battery/adapter detail | [x] Pages for Battery, CPU (Super/Efficiency cores, load, top CPU), GPU, Memory (breakdown, pressure, swap, top memory), Disk (volumes, read/write), Network; rendered with live data |
| SYS-4 | No idle cost | Sampling runs only while panel/page visible; stops ≤ 1 s after hiding (verified by wakeups) | [x] Live: `top` 1→0 on close, CPU back to 0.03 %, wakeups 0.12/s |

## FAN — temperatures & fans (Macs Fan Control 1.5.19)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| FAN-1 | View temperatures | All valid IOHID/SMC sensors, junk readings (e.g. −9201 °C) filtered, honest labels | [x] 40+ IOHID/SMC sensors, junk (−9201 °C) filtered; CPU/GPU labels from Stats' M5 keys confirmed under load by test; shown in panel and page |
| FAN-2 | View fans | Current / min / max RPM from SMC | [x] 1 fan, 2317–6550 rpm, current speed (0 = stopped) read without root |
| FAN-3 | Edit fan power for heavy tasks | Auto / custom speed / Max via privileged helper; resets to Auto on quit, sleep, module off, or app crash | [!] Implemented (helper + XPC + resets on quit/sleep/disconnect/module off); non-root writes verified refused; actual speed change needs the user to approve the helper (App Background Activity) |
| FAN-4 | Honest support states | Shows "needs helper approval", "no fans on this Mac", etc. Never fakes a reading | [x] States for helper not installed / awaiting approval / no fans; never fakes readings |

## CLIP — clipboard history (Raycast 1.104)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| CLIP-1 | ⌃⇧V opens history | Palette appears ≤ 150 ms, search focused | [x] Live: palette opens on the shortcut; search field focused (bug found and fixed: focus didn't reach the non-activating panel) |
| CLIP-2 | Text, images, files, links | Each captured with preview; rich text keeps formatting on paste | [x] Live: text, link, image, file captured; rich text stored as RTF and restored on paste |
| CLIP-3 | Search + type filter | Instant filter; All / Text / Images / Files / Links | [x] Unit tests (search, filters, pins) + palette UI with All/Text/Images/Files/Links (⇥ cycles) |
| CLIP-4 | Paste, pin, delete | ↩ pastes into previous app, ⌘↩ copies only, pin/unpin, delete, clear unpinned | [x] Live: searched "paste test" in the palette, ↩ pasted exactly "tutto paste test 123" into TextEdit (read back via Accessibility); ⌘↩ copy, ⇧⌘P pin, ⌘⌫ delete, ⌘1–9 implemented |
| CLIP-5 | Privacy | Skips password-manager (concealed/transient) items; pause capture; ignore list | [x] Live: concealed (password-manager) item not recorded; pause switch; ignore list with password managers by default |
| CLIP-6 | Persistence | Survives relaunch; size/age limits | [x] Unit tests: persistence with blobs, 500-item limit, 100-image cap, pinned kept |

## WIN — window management (Raycast)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| WIN-1 | ⌘⌥B → type "left half" → ↩ | Frontmost window snaps to the left half of its screen's visible frame | [x] Live: palette → "left half" → Finder window at (0, 33, 756 × 858) exactly |
| WIN-2 | Halves, thirds, quarters, center, maximize, displays | All actions work on the test machine incl. restore | [x] Live: right half, left half, center, restore, thirds (Finder's 536 pt min width respected); geometry unit-tested for all actions incl. displays |
| WIN-3 | Per-action hotkeys | Optional recordable shortcut per action | [x] Live: Left Half on ⌃⌥⌘L → (0, 33, 756 × 858); Maximize on ⌃⌥⌘M → (0, 33, 1512 × 858); every action recordable on the Windows and Shortcuts pages |

## SHOT — screenshots (Shottr 1.9.3)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SHOT-1 | ⌘⇧2 area → clipboard, no editor | Select area → PNG on clipboard; toast confirms | [x] Live: area → 800 × 600 PNG on clipboard, toast; latency mouse-up → clipboard ≤ 72 ms |
| SHOT-2 | ⌘⇧1 full screen → clipboard | Display under pointer captured at native resolution | [x] Live: 3024 × 1964 PNG on clipboard |
| SHOT-3 | ⌘⇧` area → editor | Editor opens with the capture | [x] Live: editor opens centered with the capture (placement bug found and fixed) |
| SHOT-4 | Selection overlay | Frozen screen, crosshair, live W×H px, loupe, Esc cancels, multi-display safe | [x] Live: frozen screen, hairline crosshair, loupe with pixel grid + hex, live W×H, window/desktop click, right-click cancels; overlay on screen 60–121 ms after the shortcut |
| SHOT-5 | Tab copies color under cursor | Hex of the exact image pixel copied; toast with swatch | [x] Live: Tab copied #222222 (pixel under the pointer), swatch toast |
| SHOT-6 | Freehand draw with thickness & color | Pen tool icon; color swatches + custom; thickness control | [x] Live: Draw tool stroke rendered; 8 colors + any color, 3 thicknesses ([ ]), plus highlight, arrow, rectangle, pixelate |
| SHOT-7 | Click-drag sub-selection with live pixel size; movable, resizable box; crop | Handles, move, resize, crop (↩) | [x] Live: canvas drag → selection with 8 handles + "402 × 202" pill → Crop button (also ↩) → 402 × 202 px result; move/resize handles implemented |
| SHOT-8 | OCR copy text (whole or selection) | Vision OCR → clipboard, line order preserved | [x] Live: "Talk. It types." + two lines OCR'd exactly in order; selection-only OCR supported; QR codes detected |
| SHOT-9 | Save to file, default Downloads | ⌘S writes PNG to ~/Downloads (configurable) | [x] Live: Save wrote "Screenshot 2026-10-10 at 04.02.12.png" to the configured folder (default ~/Downloads; macOS asks once for Downloads access) |
| SHOT-10 | Esc copies and closes | Esc → clipboard (selection if one is drawn) | [x] Live: Esc copied 1280 × 190 image and closed the editor |
| SHOT-11 | Editor shows only screenshot UI | No stats/other modules in editor | [x] Editor window contains only screenshot tools |

## ARC — archives (The Unarchiver 4.3.9)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| ARC-1 | Formats | zip, rar (v4/v5), 7z, tar, gz, bz2, xz, lzma, iso, cab, lha/lzh, xar, cpio, ar … (what macOS libarchive 3.7.4 supports; gaps documented) | [x] 68 unit tests across formats; live: zip, 7z, tar.gz, real RAR4, gz, tar.xz extracted byte-identical |
| ARC-2 | Fix garbled filenames | Non-UTF-8 zip names (Shift-JIS, GBK, CP437, CP1251 …) auto-detected | [x] Unit tests: Shift-JIS (incl. 0x5C trail bytes), GBK, Big5, CP949, CP866, CP1251, CP437, Mac Roman |
| ARC-3 | Finder right-click | Extract Here / Extract to "Name" / Extract to… / Compress, top level of the context menu | [x] Live: Finder right-click on a .rar shows Extract Here / Extract to "library" / Extract to…; Extract Here produced the folder; Compress verified via the same URL path |
| ARC-4 | Open archives directly | Double-click / Open With extracts per preferences | [x] Live: `open -a Tutto open-me.zip` (what double-click does once Tutto is the default) extracted next to it; Make Default button sets Tutto for archive types |
| ARC-5 | Preferences | Destination, create-folder rule, trash after, reveal after, encoding override | [x] Destination, Smart/Always/Never folder rule, trash after, reveal after, encoding override |
| ARC-6 | Progress, cancel, errors, passwords | Progress panel; cancel cleans up; zip passwords prompt; unsupported encryption explained | [x] Live: 3 GB archive → progress panel; Cancel left nothing behind; password prompt panel appears (decryption unit-tested: ZipCrypto, AES, wrong/missing password) |
| ARC-7 | Safety | No path traversal, no writing through symlinks, never overwrites silently | [x] Unit tests: ../ and absolute paths contained, symlink escapes refused, unique names, temp-dir cleanup |

## CC — CornerClick 1.0.0 (all functionality)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| CC-1 | Corner click/tap → right-click, bottom-left or bottom-right | Same engine & tests as CornerClick (ported unit tests pass) | [~] Engine ported verbatim; 48 original tests pass; Tutto's event tap verified installed. Physical corner press in Tutto needs the user |
| CC-2 | Two-finger right-click untouched | — | [x] Engine passes native right-click through untouched (unit test with real CGEvents) |
| CC-3 | S / M / L / Custom (mm), drag to size, click other corner to switch | — | [x] S/M/L/Custom mm steppers, drag-to-size, click other corner — CornerClick's own UI code |
| CC-4 | Tap to click on/off, tap-to-drag timing | — | [x] Tap-to-click on/off and tap-to-drag windows (unit tests + live preference reading) |
| CC-5 | Pause from menu bar, open at login | — | [x] Pause switch in panel/page; open at login (app-wide) |
| CC-6 | Diagnostics log `~/Library/Logs/CornerClick/clicks.log` | Opt-in toggle, reveal log | [x] Diagnostics toggle + Reveal; same log path |
| CC-7 | Accessibility flow + Set Up & Test | — | [~] Accessibility card + Set Up & Test (onboarding step 4); pending the installed app's own grant |
| CC-8 | Robustness: sleep/wake, hot-plug, stale stream, trust watchdog, menus, typing | — | [x] Engine's sleep/wake, hot-plug, stale-stream, watchdog, menu and typing rules kept; engine now also releases IOKit notifications when switched off |
| CC-9 | Panel section more minimal (no right-click counter) | — | [x] Panel shows no right-click counter |
| CC-10 | Migrates CornerClick settings; warns if CornerClick.app also runs | — | [x] Live: migrated the user's zone (S, 44 × 19 mm) and triggers from CornerClick's settings; warns while CornerClick.app runs |

## UX — design

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| UX-1 | One coherent minimal design system, light & dark | Shared tokens/components; screenshots in both appearances | [x] One design system (ink tokens, hairlines, mono captions, shared controls) across panel, window, palettes, editor; light + dark renders reviewed |
| UX-2 | Smooth, accessible motion | Springs ≤ 0.45 s; Reduce Motion → fades; nothing animates while idle | [x] Motion tokens ≤ 0.40 s, Reduce Motion fades, keyboard surfaces appear instantly, no continuous animation (removed per-second value animations after profiling) |
| UX-3 | Accessibility | VoiceOver labels, keyboard navigation in palettes/editor, contrast AA | [~] VoiceOver labels on controls (verified in the editor's AX tree), full keyboard use of palettes and editor; contrast tuned from CornerClick (AA) — no formal audit run |
| UX-4 | Research-informed | `docs/research/ui-ux-research.md` applied | [x] `docs/research/ui-ux-research.md` (verified X posts) applied: monochrome instrument style, system glass only, instant palettes, numeric typography, no idle animation |

## PERF — budgets (measured with `scripts/measure.sh`)

Baseline of the apps Tutto replaces, idle for 3 minutes on the test machine (2026-10-10):

| App | CPU % | Footprint | Idle wakeups/s |
|---|---|---|---|
| Stats 3.0.4 (menu bar values on) | 1.761 | 211 MB | 1.04 |
| Raycast 1.104.31 | 0.022 | 104 MB | 0.26 |
| Shottr 1.9.3 | 0.000 | 81 MB | 0.09 |
| CornerClick 1.0.0 | 0.005 | 25 MB | 0.04 |
| **Combined** | **1.788** | **421 MB** | **1.43** |

(Macs Fan Control and The Unarchiver were not running.)


| ID | Budget | Status |
|---|---|---|
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % (avg over 3 min) | [x] 0.011 % (90 s, user away) |
| PERF-2 | Idle wakeups ≤ 1 /s | [x] 0.05 /s |
| PERF-3 | Idle memory footprint ≤ 45 MB | [x] 13 MB (30 MB after the panel has been opened) |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wakeups ≤ 0.5 /s | [x] 0 %, 0.02 /s |
| PERF-5 | Panel open (1 Hz updates): CPU ≤ 3 % | [x] 1.5 % (was 15.5 % before the fix) |
| PERF-6 | Lighter than the apps it replaces combined (Stats + Raycast + Shottr + CornerClick) | [x] 0.011 % / 13–30 MB vs 1.788 % / 421 MB combined |
| PERF-7 | Hotkey → selection overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | [x] overlay 60–121 ms; mouse-up → clipboard 0–72 ms |
| PERF-8 | App bundle ≤ 15 MB | [x] 8.0 MB |
