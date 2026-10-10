# Performance

Machine: MacBook Pro 14" (Apple M5, 16 GB), macOS 26.5.2, on battery, release build of Tutto 1.0.0.
Tools: `scripts/measure.sh` (CPU % = CPU-time delta from `ps` over wall time; footprint from `footprint`; idle wake-ups from `top`'s cumulative IDLEW counter; energy impact from `top`'s POWER column) and `scripts/measure-modules.sh`. `scripts/measure.sh <seconds> Tutto <OtherApp> …` takes any process names, so any apps can be compared side by side.
`ps` reports CPU time in 10 ms ticks, so over a 90 s window the smallest non-zero reading is 0.011 %.

## Budgets and results

| ID | Budget | Measured | Result |
|---|---|---|---|
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % | **0.011 %** (90 s, user away) | ✅ |
| PERF-2 | Idle wake-ups ≤ 1 /s | **0.05 /s** | ✅ |
| PERF-3 | Idle memory footprint ≤ 45 MB | **13 MB** before the panel is first opened, **30 MB** after | ✅ |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wake-ups ≤ 0.5 /s | **0 %**, **0.02 /s**, 13 MB | ✅ |
| PERF-5 | Menu bar panel open (1 Hz updates): CPU ≤ 3 % | **1.5 %**, 32 MB, 0.67 wake-ups/s (30 s) | ✅ (after fix, see below) |
| PERF-6 | Lighter than the baseline apps combined | see comparison | ✅ |
| PERF-7 | Hotkey → overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | display capture **57–97 ms**; shortcut → overlay on screen **60–121 ms**; mouse-up → clipboard/editor **0–72 ms** (3 live runs, `os_log` timings) | ✅ |
| PERF-8 | App bundle ≤ 15 MB | **7.9 MB** (release, arm64) | ✅ |

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
