# Performance

Machine: MacBook Pro 14" (Apple M5, 16 GB), macOS 26.5.2, on battery, release build of Tutto 1.0.0.
Tools: `scripts/measure.sh` (CPU % = CPU-time delta from `ps` over wall time; footprint from `footprint`; idle wake-ups from `top`'s cumulative IDLEW counter; energy impact from `top`'s POWER column) and `scripts/measure-modules.sh`.
`ps` reports CPU time in 10 ms ticks, so over a 90 s window the smallest non-zero reading is 0.011 %.

## Budgets and results

| ID | Budget | Measured | Result |
|---|---|---|---|
| PERF-1 | Idle, all modules on, panel closed: CPU ≤ 0.10 % | **0.011 %** (90 s, user away) | ✅ |
| PERF-2 | Idle wake-ups ≤ 1 /s | **0.05 /s** | ✅ |
| PERF-3 | Idle memory footprint ≤ 45 MB | **13 MB** before the panel is first opened, **30 MB** after | ✅ |
| PERF-4 | All modules off: CPU ≤ 0.02 %, wake-ups ≤ 0.5 /s | **0 %**, **0.02 /s**, 13 MB | ✅ |
| PERF-5 | Menu bar panel open (1 Hz updates): CPU ≤ 3 % | **1.5 %**, 32 MB, 0.67 wake-ups/s (30 s) | ✅ (after fix, see below) |
| PERF-6 | Lighter than the apps it replaces combined | see comparison | ✅ |
| PERF-7 | Hotkey → overlay ≤ 200 ms; mouse-up → clipboard ≤ 150 ms | ⌘⇧1 full-screen capture to clipboard measured end-to-end in the live test; overlay latency still to be timed | partial |
| PERF-8 | App bundle ≤ 15 MB | **7.9 MB** (release, arm64) | ✅ |

## Per-module idle cost (90 s each, user away, `scripts/measure-modules.sh`)

| Modules on | CPU | Footprint | Wake-ups/s |
|---|---|---|---|
| none | 0 % | 13 MB | 0.02 |
| System, Sensors, Windows, Screenshots, Archives | 0.011 % | 13 MB | 0 |
| Clipboard only | 0.011 % | 14 MB | 0.10 |
| CornerClick only | 0 % | 14 MB | 0.10 |
| **all seven** | **0.011 %** | **13 MB** | **0.05** |

System, Sensors, Windows, Screenshots and Archives cost nothing while idle by design: no timers until a view is visible, Carbon hot keys, and the Finder extension lives in Finder's process. Clipboard is the only module with an idle timer (macOS has no clipboard-changed notification); its 1 s check uses 50 % timer leeway so macOS coalesces it, slows to 4 s when you're away, and stops while the screen is locked. CornerClick wakes only on trackpad touches plus a 5 s permission watchdog (kept from CornerClick because a stale event tap can freeze input if Accessibility is revoked).

## Compared with the apps Tutto replaces (idle, same machine)

| App | CPU | Footprint | Wake-ups/s |
|---|---|---|---|
| Stats 3.0.4 | 1.761 % | 211 MB | 1.04 |
| Raycast 1.104.31 | 0.022 % | 104 MB | 0.26 |
| Shottr 1.9.3 | 0.000 % | 81 MB | 0.09 |
| CornerClick 1.0.0 | 0.005 % | 25 MB | 0.04 |
| **Combined** | **1.788 %** | **421 MB** | **1.43** |
| **Tutto (all seven tools)** | **0.011 %** | **13 MB** (30 MB after opening the panel) | **0.05** |

Stats costs the most because it updates values in the menu bar continuously; Tutto shows a static icon and reads only while you look. (Macs Fan Control and The Unarchiver weren't running during the baseline; neither runs a background process in normal use.)

## A defect found and fixed by measuring

The first live measurement with the menu bar panel open showed **15.5 % CPU, 118 MB and 21.6 wake-ups/s**. `sample` showed SwiftUI rendering the panel's display list on the CPU (RenderBox → CoreGraphics glyph rasterization) for every frame of the per-second value animations (`numericText` transitions, meter springs, list re-order animations) at ProMotion frame rates. Removing animations from values that change every second, and caching process icons, brought it to **1.5 % CPU, 32 MB, 0.67 wake-ups/s**. Motion is kept where it means something (toggles, sections expanding, toasts, the CornerClick flash).

## Verified to stop when not visible

- With the panel open, one `/usr/bin/top` process streams energy impact; after closing the panel there are **0**, and Tutto returns to 0.033 % CPU / 0.12 wake-ups/s within seconds.
- Turning CornerClick off from its switch removes its event tap (`CGGetEventTapList`: 1 → 0); turning it on restores it.
- Turning Archives off unregisters the Finder extension (`pluginkit -m` shows `-`), so Finder stops loading it.
