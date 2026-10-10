# Tutto — requirements checklist & acceptance criteria

Source of truth: `~/Documents/Codex/2026-10-10/this/outputs/macos-app-specification.md`.
Status legend: `[ ]` not started · `[~]` implemented, not yet verified on device · `[x]` implemented **and** verified (how is noted) · `[!]` blocked / OS-limited (reason noted).

Test machine: MacBook Pro 14" (Apple M5, 4 Super + 6 Efficiency cores, 10-core GPU, one fan), macOS 26.5.2, Xcode 26.6.

## APP — shell, settings, modules

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| APP-1 | Menu bar icon (aesthetic) opens a compact panel | Template glyph renders in light/dark menu bar; click opens panel ≤ 150 ms | [ ] |
| APP-2 | Main app window opens like a normal app (Spotlight "Tutto", Finder, `open`) | Launch or reopen shows main window, Dock icon while open, hides from Dock when closed | [ ] |
| APP-3 | Every module can be turned off independently | Toggle in General + each page header; disabled module stops all timers/taps/hotkeys/extension; verified by measuring CPU/wakeups and checking taps/hotkeys removed | [ ] |
| APP-4 | Shortcut recording & customization | Click recorder → press combo → saved & live; Esc cancels, ⌫ clears; duplicate & system-conflict warnings; "Reset to defaults" | [ ] |
| APP-5 | Default shortcuts preserved | ⌃⇧V clipboard, ⌘⌥B window palette, ⌘⇧2 area→clipboard, ⌘⇧1 full screen→clipboard, ⌘⇧` area→editor | [ ] |
| APP-6 | Settings for everything necessary | Open at login, per-module options, reset, about | [ ] |
| APP-7 | Permissions overview | Live status + request button for Accessibility, Screen Recording, Finder extension, fan helper; says exactly which features need which | [ ] |
| APP-8 | Clear on first look & install | First-run welcome: modules, permissions, shortcuts cheat sheet | [ ] |
| APP-9 | Replaces the old apps cleanly | Detects running Stats / Raycast / Shottr / Macs Fan Control / The Unarchiver / CornerClick and explains clashes; one-click quit where sensible | [ ] |

## SYS — system & battery monitor (Stats 3.0.4)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SYS-1 | Brief summary in panel: battery, CPU, GPU, RAM, disk | One compact row/tile each; values update ~1 s while visible | [ ] |
| SYS-2 | Battery: %, max capacity, design capacity, health %, cycles, power, top battery processes | Matches `system_profiler SPPowerDataType` (health = NominalChargeCapacity ÷ DesignCapacity, rounds to the same %), cycles exact, power from PowerTelemetry/ V×A, top processes match `top -o power` ordering | [ ] |
| SYS-3 | Go deeper for each: CPU, GPU, RAM, disk, battery (+network) | Main-window pages: per-core CPU (Super/Efficiency), load, top CPU processes; GPU utilization/renderer/tiler/memory; RAM breakdown + pressure + swap + top memory; volumes + read/write throughput; network rates; full battery/adapter detail | [ ] |
| SYS-4 | No idle cost | Sampling runs only while panel/page visible; stops ≤ 1 s after hiding (verified by wakeups) | [ ] |

## FAN — temperatures & fans (Macs Fan Control 1.5.19)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| FAN-1 | View temperatures | All valid IOHID/SMC sensors, junk readings (e.g. −9201 °C) filtered, honest labels | [ ] |
| FAN-2 | View fans | Current / min / max RPM from SMC | [ ] |
| FAN-3 | Edit fan power for heavy tasks | Auto / custom speed / Max via privileged helper; resets to Auto on quit, sleep, module off, or app crash | [ ] |
| FAN-4 | Honest support states | Shows "needs helper approval", "no fans on this Mac", etc. Never fakes a reading | [ ] |

## CLIP — clipboard history (Raycast 1.104)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| CLIP-1 | ⌃⇧V opens history | Palette appears ≤ 150 ms, search focused | [ ] |
| CLIP-2 | Text, images, files, links | Each captured with preview; rich text keeps formatting on paste | [ ] |
| CLIP-3 | Search + type filter | Instant filter; All / Text / Images / Files / Links | [ ] |
| CLIP-4 | Paste, pin, delete | ↩ pastes into previous app, ⌘↩ copies only, pin/unpin, delete, clear unpinned | [ ] |
| CLIP-5 | Privacy | Skips password-manager (concealed/transient) items; pause capture; ignore list | [ ] |
| CLIP-6 | Persistence | Survives relaunch; size/age limits | [ ] |

## WIN — window management (Raycast)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| WIN-1 | ⌘⌥B → type "left half" → ↩ | Frontmost window snaps to the left half of its screen's visible frame | [ ] |
| WIN-2 | Halves, thirds, quarters, center, maximize, displays | All actions work on the test machine incl. restore | [ ] |
| WIN-3 | Per-action hotkeys | Optional recordable shortcut per action | [ ] |

## SHOT — screenshots (Shottr 1.9.3)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| SHOT-1 | ⌘⇧2 area → clipboard, no editor | Select area → PNG on clipboard; toast confirms | [ ] |
| SHOT-2 | ⌘⇧1 full screen → clipboard | Display under pointer captured at native resolution | [ ] |
| SHOT-3 | ⌘⇧` area → editor | Editor opens with the capture | [ ] |
| SHOT-4 | Selection overlay | Frozen screen, crosshair, live W×H px, loupe, Esc cancels, multi-display safe | [ ] |
| SHOT-5 | Tab copies color under cursor | Hex of the exact image pixel copied; toast with swatch | [ ] |
| SHOT-6 | Freehand draw with thickness & color | Pen tool icon; color swatches + custom; thickness control | [ ] |
| SHOT-7 | Click-drag sub-selection with live pixel size; movable, resizable box; crop | Handles, move, resize, crop (↩) | [ ] |
| SHOT-8 | OCR copy text (whole or selection) | Vision OCR → clipboard, line order preserved | [ ] |
| SHOT-9 | Save to file, default Downloads | ⌘S writes PNG to ~/Downloads (configurable) | [ ] |
| SHOT-10 | Esc copies and closes | Esc → clipboard (selection if one is drawn) | [ ] |
| SHOT-11 | Editor shows only screenshot UI | No stats/other modules in editor | [ ] |

## ARC — archives (The Unarchiver 4.3.9)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| ARC-1 | Formats | zip, rar (v4/v5), 7z, tar, gz, bz2, xz, lzma, iso, cab, lha/lzh, xar, cpio, ar … (what macOS libarchive 3.7.4 supports; gaps documented) | [ ] |
| ARC-2 | Fix garbled filenames | Non-UTF-8 zip names (Shift-JIS, GBK, CP437, CP1251 …) auto-detected | [ ] |
| ARC-3 | Finder right-click | Extract Here / Extract to "Name" / Extract to… / Compress, top level of the context menu | [ ] |
| ARC-4 | Open archives directly | Double-click / Open With extracts per preferences | [ ] |
| ARC-5 | Preferences | Destination, create-folder rule, trash after, reveal after, encoding override | [ ] |
| ARC-6 | Progress, cancel, errors, passwords | Progress panel; cancel cleans up; zip passwords prompt; unsupported encryption explained | [ ] |
| ARC-7 | Safety | No path traversal, no writing through symlinks, never overwrites silently | [ ] |

## CC — CornerClick 1.0.0 (all functionality)

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| CC-1 | Corner click/tap → right-click, bottom-left or bottom-right | Same engine & tests as CornerClick (ported unit tests pass) | [ ] |
| CC-2 | Two-finger right-click untouched | — | [ ] |
| CC-3 | S / M / L / Custom (mm), drag to size, click other corner to switch | — | [ ] |
| CC-4 | Tap to click on/off, tap-to-drag timing | — | [ ] |
| CC-5 | Pause from menu bar, open at login | — | [ ] |
| CC-6 | Diagnostics log `~/Library/Logs/CornerClick/clicks.log` | Opt-in toggle, reveal log | [ ] |
| CC-7 | Accessibility flow + Set Up & Test | — | [ ] |
| CC-8 | Robustness: sleep/wake, hot-plug, stale stream, trust watchdog, menus, typing | — | [ ] |
| CC-9 | Panel section more minimal (no right-click counter) | — | [ ] |
| CC-10 | Migrates CornerClick settings; warns if CornerClick.app also runs | — | [ ] |

## UX — design

| ID | Requirement | Acceptance criteria | Status |
|---|---|---|---|
| UX-1 | One coherent minimal design system, light & dark | Shared tokens/components; screenshots in both appearances | [ ] |
| UX-2 | Smooth, accessible motion | Springs ≤ 0.45 s; Reduce Motion → fades; nothing animates while idle | [ ] |
| UX-3 | Accessibility | VoiceOver labels, keyboard navigation in palettes/editor, contrast AA | [ ] |
| UX-4 | Research-informed | `docs/research/ui-ux-research.md` applied | [ ] |

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
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % (avg over 3 min) | [ ] |
| PERF-2 | Idle wakeups ≤ 1 /s | [ ] |
| PERF-3 | Idle memory footprint ≤ 45 MB | [ ] |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wakeups ≤ 0.5 /s | [ ] |
| PERF-5 | Panel open (1 Hz updates): CPU ≤ 3 % | [ ] |
| PERF-6 | Lighter than the apps it replaces combined (Stats + Raycast + Shottr + CornerClick) | [ ] |
| PERF-7 | Hotkey → selection overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | [ ] |
| PERF-8 | App bundle ≤ 15 MB | [ ] |
