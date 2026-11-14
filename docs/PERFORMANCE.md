# Performance

Machine: MacBook Pro 14" (Apple M5, 16 GB), macOS 26.5.2, on battery, release build of Tutto 1.0.0.
Tools: `scripts/measure.sh` (CPU % = CPU-time delta from `ps` over wall time; footprint from `footprint`; idle wake-ups from `top`'s cumulative IDLEW counter; energy impact from `top`'s POWER column) and `scripts/measure-modules.sh`. `scripts/measure.sh <seconds> Tutto <OtherApp> …` takes any process names, so any apps can be compared side by side.
`ps` reports CPU time in 10 ms ticks, so over a 90 s window the smallest non-zero reading is 0.011 %.

## Budgets and results

| ID | Budget | Measured | Result |
|---|---|---|---|
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % | **0.011 %** (90 s, user away) | ✅ |
| PERF-2 | Idle wake-ups ≤ 1 /s | **0.05 /s** | ✅ |
| PERF-3 | Idle memory footprint ≤ 45 MB | **17–21 MB** fresh; **62–66 MB** once every tool has been used, flat after that; **~88 MB** after the main window has been opened and closed (2026-10-28) | ⚠️ not met after use; bounded, no growth (see REQUIREMENTS PERF-3) |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wake-ups ≤ 0.5 /s | **0 %**, **0.02 /s**, 13 MB | ✅ |
| PERF-5 | Menu bar panel open (1 Hz updates): CPU ≤ 3 % | **1.5 %**, 32 MB, 0.67 wake-ups/s (30 s) | ✅ (after fix, see below) |
| PERF-6 | Lighter than the baseline apps combined | see comparison | ✅ |
| PERF-7 | Hotkey → overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | display capture **57–97 ms**; shortcut → overlay on screen **60–121 ms**; mouse-up → clipboard/editor **0–72 ms** (3 live runs, `os_log` timings) | ✅ |
| PERF-8 | App bundle ≤ 15 MB | **8.0 MB** (release, arm64, build 137 with themes and plugins; 6.7 MB after the optimization pass, before them) | ✅ |
| Idle, build 140 (2026-11-11 00:51, Bryan away, no input through the window, Tutto up 1 h, agents' session on) | 60 s, `idle_budget.py` | **0.06 %** CPU, **0.02** wake-ups/s, energy **0.06**, footprint **67 MB** | ✅ CPU, wake-ups, energy; ⚠️ footprint over 60 MB after an hour of use (PERF-3) |
| Panel, build 140 (same run) | 10 open/close cycles (System Events) | 0–0.01 s of CPU per 3 s open; **0.07 %** in the 30 s after closing; footprint 67 → 75 MB | ✅ CPU; no leak: two more rounds of 10 cycles at 01:05 went 61 → 66 → 67 MB, levelling off (one-time caches after an hour closed) |

## Optimization pass (2026-11-10, builds 125 → 127)

Bryan: "optimize the entire application and anything without removing any core functionality". Measured on the installed app, same Mac.

| What | Before (build 125) | After (build 127) | How |
|---|---|---|---|
| App bundle | 13 MB (app binary 11.2 MB) | **6.7 MB** (4.7 MB) | release binaries ship without symbol tables; dSYMs in `build/Symbols` (crash reports, `sample`, `atos` find them by UUID; checked with `atos`) |
| Launch: CPU used in the first 4.5 s / 10.5 s | 0.58 s / 1.13 s | **0.22 s / 0.22 s** (nothing after the first seconds) | the Finder extension registered once per build instead of at every launch (two `pluginkit` runs); (the first launch also had ⌘Tab use in it) |
| Footprint 10 s after launch (peak) | 35 MB (peak 80 MB over the first minutes) | **17 MB (peak 18 MB)** | same |
| Tools' start-up | not measured | **222 ms** (strip 105, sound 74, system 16), logged once per launch (`category == "launch"`) | new launch line |
| Opening the menu bar panel | a `pluginkit` run every time (Tutto becomes active) | at most one every 10 min; pages that show the extension still read it at once | rate-limited Finder-extension check |
| Stay Awake's battery rules | the full battery reader (registry walk; hourly `system_profiler`) on every power event | one power-sources read | `PowerSourceNow` |
| While agents work: the minute check | a CPU reading for every process (about 600) plus its name | one process-table read, CPU readings only for commands under agents | `ProcessTree.snapshot`, `AgentWork.tools` |
| Window switcher | pictures still queued kept being taken after it closed (and were stale by the next ⌘Tab) | cancelled on close | `ThumbnailStore.cancelPending` |
| Compiler warnings | 14 (release), 2 more in debug | **0 and 0** | Archives' jobs, the switcher's picture size and click monitor, Trackpad Corner's hooks, the clicker's count, the switcher lab |

While Bryan worked (agents running, ⌘Tab about three times a minute) build 125 measured 1.01 % CPU, 0.17 wake-ups/s, 40 MB and an energy impact of 1.01 over 60 s; nearly all of it was the window switcher in use (opening in 14–27 ms; a card picture costs about 5 ms of CPU, most of it scaling). With him away for 30 s it used 0.03 %. Idle and panel numbers for build 127 with him away: see the next rows once measured.

## Per-module idle cost (90 s each, user away, `scripts/measure-modules.sh`)

| Modules on | CPU | Footprint | Wake-ups/s |
|---|---|---|---|
| none | 0 % | 13 MB | 0.02 |
| System, Sensors, Windows, Screenshots, Archives | 0.011 % | 13 MB | 0 |
| Clipboard only | 0.011 % | 14 MB | 0.10 |
| Trackpad Corner only | 0 % | 14 MB | 0.10 |
| **all seven** | **0.011 %** | **13 MB** | **0.05** |

System, Sensors, Windows, Screenshots and Archives cost nothing while idle by design: no timers until a view is visible, Carbon hot keys, and the Finder extension lives in Finder's process. Clipboard is the only module with an idle timer (macOS has no clipboard-changed notification); its 1 s check uses 50 % timer leeway so macOS coalesces it, slows to 4 s when you're away, and stops while the screen is locked. Trackpad Corner wakes only on trackpad touches plus a 5 s permission watchdog (kept because a stale event tap can freeze input if Accessibility is revoked).

## Compared with baseline apps (idle, same machine)

The baselines are single-purpose utilities covering features Tutto also has, measured idle on the same Mac. They are identified by category only.

| Baseline | CPU | Footprint | Wake-ups/s |
|---|---|---|---|
| Baseline A — menu bar system monitor | 1.761 % | 211 MB | 1.04 |
| Baseline B — launcher with clipboard/window extensions | 0.022 % | 104 MB | 0.26 |
| Baseline C — screenshot tool | 0.000 % | 81 MB | 0.09 |
| Baseline D — trackpad corner utility | 0.005 % | 25 MB | 0.04 |
| **Baselines combined** | **1.788 %** | **421 MB** | **1.43** |
| **Tutto (all seven tools)** | **0.011 %** | **13 MB** (30 MB after opening the panel) | **0.05** |

Baseline A costs the most because it updates values in the menu bar continuously; Tutto shows a static icon and reads only while you look. (No fan-control utility or archive extractor was running during the baseline; neither kind normally runs a background process.)

## A defect found and fixed by measuring

The first live measurement with the menu bar panel open showed **15.5 % CPU, 118 MB and 21.6 wake-ups/s**. `sample` showed SwiftUI rendering the panel's display list on the CPU (RenderBox → CoreGraphics glyph rasterization) for every frame of the per-second value animations (`numericText` transitions, meter springs, list re-order animations) at ProMotion frame rates. Removing animations from values that change every second, and caching process icons, brought it to **1.5 % CPU, 32 MB, 0.67 wake-ups/s**. Motion is kept where it means something (toggles, sections expanding, toasts, the Trackpad Corner flash).

## Verified to stop when not visible

- With the panel open, one `/usr/bin/top` process streams energy impact; after closing the panel there are **0**, and Tutto returns to 0.033 % CPU / 0.12 wake-ups/s within seconds.
- Turning Trackpad Corner off from its switch removes its event tap (`CGGetEventTapList`: 1 → 0); turning it on restores it.
- Turning Archives off unregisters the Finder extension (`pluginkit -m` shows `-`), so Finder stops loading it.

## The strip under a heavy load (2026-10-24)

Measured on the real Mac while Firefox (a playing video, ~230 % CPU), Discord and WindowServer (~45 %) kept the GPU at 40–75 %, on battery. Tutto's main thread runs the strip's animation (a 120 Hz display link), so anything else on it costs frames.

| Main-thread work found | Cost | Fix |
|---|---|---|
| Move/resize notices: asking the app which window each was about, and whether it was full screen | 143 ms of every 14 s of use; the app is busy redrawing exactly then | Matched against watched windows; the strip's own echoes return first |
| Asking the app in front which window has focus, on every app switch | 36 ms (68 ms late) | Asked on that app's background queue; a focus notice that names a watched window needs no question |
| Sound: reading every sound process and who owns it (muted apps) | 23–25 ms per audio-process change | Looked up off the main thread |
| The bar: font looked up by name and text measured on every key | 27 ms over a hold | Once each |
| Listing every window's details to see which still exist, on every key | 1.3 ms, 60 ms when WindowServer is busy | Window numbers only (0.15 ms) |
| Bar pictures and window photos taken while windows move | a capture costs WindowServer/GPU about a frame | Taken once the strip has been still 0.45 s; none while sizing (the bar shows icons) |
| Switching the bar to icons mid-move | 17 ms + 4–5 ms per frame (SwiftUI morph) | Two bar windows crossfaded (window alpha only), switched before the window moves |

Result on the real strip: no main-thread stall left during ⌃⌥R (watchdog silent), strip frames 8–10 ms at 120 Hz. What remains is the apps' own redraw: a heavy page re-lays itself out ~200 ms behind its window frame while it resizes.

Opt-in timing for this kind of work: `defaults write ca.bryanyao.Tutto debug.perf -bool true`, relaunch, then `log stream --predicate 'subsystem == "ca.bryanyao.Tutto" AND category == "perf"'` logs anything over 8 ms by name and every time the main thread answers more than 30 ms late. Turn it off again (`defaults delete ca.bryanyao.Tutto debug.perf`): its watchdog wakes the main thread 100 times a second.

### Tried and not shipped: resizing web apps behind a snapshot

Some window managers hide an app's slow redraw by changing the size of a picture of the window and revealing the real window at the end. Built and measured (branch `experiment/snapshot-resize`): the picture can sit directly above another app's window, a see-through picture keeps macOS from marking the window under it hidden (an opaque one did, and apps stop drawing hidden windows), and a full-resolution picture takes ~14 ms. The motion was perfectly smooth at 120 Hz. Filmed on the real Firefox windows, though, it looked worse: text stretched (up to 4× on Full → 25 %) and held ~300 ms while the window redrew, then a ghosted dissolve, where a typical page re-flows cleanly live. Live resizing stays; only pages as heavy as X.com trail their frame, and they do the same when resized by hand.

