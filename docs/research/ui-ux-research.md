# Tutto: UI/UX research

Researched 2026-10-10. X numbers were read from a logged-in X session that day (likes · views). "Verified" means I opened the post or page myself. The test machine runs macOS 26.5. macOS 27 "Golden Gate" was scheduled for 14 Sep 2026; I did not confirm that it shipped on that date. Design for 26 and keep the 27 changes in mind.

## A. Verified viral or praised examples

| Who / what | Date | Likes · views | Why it landed |
|---|---|---|---|
| Alejandro Buján, **Tendedero**: "I made my Mac hang every screenshot on a clothesline" | 2026‑10‑07 | 14.2K · 940K (6.3K bookmarks) | One physical metaphor. The top reply asks for the line to "sag", so people want physics. README: "No floating thumbnail. No five-second wait", 1.7 MB, no network. 1.26K stars in 3 days. |
| Farza, **freewrite** | 2025‑04‑11 | 10.6K · 2.2M | "Made for myself": one purpose, native Swift, local, free, 20 s video. |
| Edward Luo, agent monitor in the notch | 2026‑07‑17 | 6.6K · 929K | Attention only as an event ("Agent finishes → notch pops"). |
| Jaskirat, **MacTap** (knock beside the trackpad); Bryl Lim, screen blur from AirPods head tracking | 2026‑09 | 1.9K · 626K; 5.8K · 761K | Novel-sensor tricks. The closest analogues to CornerClick. |
| Tw93, **Mole**: menu bar HUD with CPU/RAM/network, plus battery health | 2026‑05‑18 | 1.3K · 124K | 69.8K-star repo. "Show what it is doing, then stay out of your way." |
| CleanShot 5.0 | 2026‑09‑01 | 4.9K · 1.03M | Polish plus "No subscription required." |
| Raycast 2.0 beta | 2026‑05‑14 | 1.6K · 357K | Rebuilt for Tahoe. Glass "used in tasteful ways to enhance the functional nature of a launcher". |
| Droppy, "Apps you can delete once Droppy is on your Mac" | 2026‑10‑06 | 580 · 742K | The all-in-one pitch got reach but very low likes. Possibly promoted (unverified). |
| Emil Kowalski: one font size and monochrome to "limit the amount of design mistakes"; "small apps that do one thing well" | 2026‑07 | 2.4K · 285K; 1.5K | Restraint as a method. Also a warning for all-in-one apps. |
| Emil Kowalski, motion tips | 2025‑08 to 2026‑03 | 1.3K–3.9K each | Press scale 0.97–0.98 at about 150 ms. Enter from 0.93, not 0. Ease-out. `blur(2px)` masks flaws. 4px blur + Y + subtle stagger. |
| Rauno Freiberg: "make all interfaces look as cool as debug interfaces" | 2026‑04‑29 | 1.5K · 68K | Validates the annotated, instrument look. |
| MKBHD: Liquid Glass "felt sloppy"; "same corner radius in every Mac app" had to be announced as a feature | 2026‑06‑08 | 18.6K · 966K | Glass fatigue. Precision now reads as premium. |
| Diego (@1000kilobytes): Dock edge reflecting in window glass | 2026‑07‑08 | 4.4K · 675K | Physical micro-details delight, but replies attack the GPU cost. |
| Valerian Saliou: the roughly 1 s Spaces animation can't be disabled, even with Reduce Motion | 2026‑08‑05 | 1.9K (2.3K bookmarks) | Unskippable motion on frequent actions is hated. |
| Kyle Macomber (SwiftUI team): SwiftUI animations run in the app process, not the render server | 2026‑09‑16 | 1.6K · 347K | Performance implication covered in D. |
| Linear, "Behind the latest design refresh" (blog) | 2026‑03‑12 | n/a | "Don't compete for attention you haven't earned." "Structure should be felt not seen." |

**Not verified:** I found no specific viral posts for the boring.notch, NotchNook, Alcove, Klack or Screen Studio launches. boring.notch has 11.0K GitHub stars and Stats has 42.4K (both checked through the GitHub API).

## B. Trends and why they work

1. **One metaphor, one clip of 20 s or less, legible with the sound off.** Feature lists get reach without likes (Droppy).
2. **Color and motion as events.** Silent at rest; it speaks when something happens. This is the owner's "color is an event".
3. **Restraint is the premium signal in the glass era.** It is backed by the glass backlash, Emil, Linear and Rauno, and by the HIG: Liquid Glass "has no inherent color", toolbar symbols go monochromatic, and you should "apply color sparingly".
4. **"Native, tiny, local, no subscription" is part of the pitch.**
5. **Speed is the feel.** Emil calls Raycast's lack of an open animation optimal. HIG: "avoid adding motion to UI interactions that occur frequently."
6. **All-in-one is a risky pitch.** Frame Tutto as six sharp tools in one 45 MB process, each with its own hotkey and surface. Lead with the measured baseline: it replaces apps using 421 MB and 1.79% CPU.

## C. Pattern recommendations per surface

**Menu bar panel**
- The HIG allows a popover when content is "too complex for a menu". Use `MenuBarExtra(.window)` or an NSPanel about 300 pt wide (Stats: 264 pt, 8 pt margins, 22 pt rows).
- Rows for BAT, CPU, GPU, MEM and DISK. Each row has:
  - a 10 pt uppercase monospaced caption
  - a 20 pt monospaced-digit value
  - a 1–2 pt hairline meter or a 1 px sparkline
- Battery shows health %, cycles and watts.
- Then a quick-action row with keycaps, a mini to-scale trackpad (no counter), and a Settings/Quit footer.
- No color at rest. One accent appears only for threshold events.
- Let the system material be the only glass (no glass on glass). Separate rows with hairlines and 12–16 pt gaps.
- On materials, use the hierarchical `.primary/.secondary/.tertiary` styles, which get vibrancy, not fixed ink opacities. Re-check AA contrast under Tinted glass, Reduce Transparency and Increase Contrast.

**Main window (pages and settings)**
- Use a standard `NavigationSplitView` with no custom sidebar or toolbar backgrounds. On 26 the sidebar floats; on 27 it runs edge-to-edge.
- Sidebar groups:
  - Overview and the stat pages
  - Clipboard, Windows, Screenshots, Archives, CornerClick
  - Shortcuts, Permissions, General
- Monochrome SF Symbols.
- Page header: title, module toggle, and a one-line caption.
- Charts: 1 px ink line with a 6% wash fill, and right-aligned monospaced numbers. Use hairline rules, not shadows or nested cards.

**Clipboard palette (⌃⇧V)**
- Use a non-activating borderless panel, about 760×480, in the upper third of the screen with the pointer. Being non-activating lets ↩ paste into the previous app.
- Search field on top, with a type filter at its right (⌘P).
- List on the left (about 40%): thumbnail, a one-line preview, and a monospaced relative time. Pinned items go first.
- Preview on the right (about 60%): images fit to the pane, colors as swatch plus hex, links with favicon. Below it, caption/value metadata: SOURCE, TYPE, CHARS, LAST COPIED. Raycast documents only "additional metadata"; these labels are my proposal.
- 32 pt footer: "Paste to ‹App› ↩ · Copy ⌘↩ · Actions ⌘K".
- Nothing animates: open, highlight and preview are all instant.

**Window palette (⌘⌥B)**
- Same shell, with the list only.
- Each row gets a 16×10 pt to-scale screen glyph with the target region inked, the same language as the trackpad drawing.
- Fuzzy aliases ("lh"), hotkey keycaps, and the display name when several displays are connected.
- Repeating a half cycles ½ → ⅔ → ⅓.
- Optional: after 120 ms on a row, draw a 1 px outline of the target frame. Raycast 2.0 added a visual grid overlay.
- The window snaps instantly.

**Screenshot overlay and editor**
- **Overlay:**
  - Frozen screen with about a 40% black wash outside the selection, and 1 px full-screen crosshairs.
  - A monospaced "1280 × 720 px" pill near the cursor.
  - An 8–10× loupe with a pixel grid and the center hex. Tab copies that color.
  - No appear animation.
- **Area to clipboard:** no 5 s thumbnail. Show a non-focus-stealing toast (32 pt thumbnail + "COPIED · 1280×720") for 1.6 s; clicking it opens the editor.
- **Editor:**
  - Standard toolbar with grouped tools (Crop V, Pen P, Text, OCR T). Swatches and 3-step thickness go in their own group; Copy and Save on the right.
  - A dimension box at top right (Shottr).
  - Status line: x,y · zoom · hex · "TAB COPY COLOR".
  - Crop: 8 pt hairline handles and a live size label. Arrows nudge 1 px, Shift 10 px. ↩ crops, Esc copies and closes.
  - OCR flashes 1 px line boxes, then toasts "23 LINES COPIED".
  - The color-copy toast is the one big swatch.

**Archive progress**
- Show the panel only if extraction runs past 400 ms.
- Rows: middle-truncated name, a 2 pt determinate track, a monospaced "34% · 12.4/36.1 MB · 8 s", and ×. No barber poles.
- Errors inline in plain words. Passwords in a sheet.
- Preferences: Destination, Create folder (Never / Only if more than one top-level item / Always), Trash archive, Reveal, Encoding.

**Onboarding and permissions**
- Four steps:
  1. Modules.
  2. Permissions. Each row says what it powers (Screen Recording → Screenshots and OCR), shows live ○/● status (colored only at the moment it flips) and has "Open Settings". Poll only while visible.
  3. Shortcut keycaps.
  4. CornerClick test on the live trackpad.
- Also flag conflicting running apps.

## D. Motion spec

| Token | SwiftUI | Use |
|---|---|---|
| `none` | no animation | Palette open, list highlight, preview swap, hover, overlay, window snaps |
| `press` | scale 0.97, `.easeOut(duration: 0.12)` | Buttons and tiles on mouse-down |
| `micro` | `.spring(duration: 0.20, bounce: 0)` | Toggles, segmented controls, tool indicator (`matchedGeometryEffect`) |
| `snappy` | `.spring(duration: 0.28, bounce: 0.05)` (≈ CornerClick's 0.28 / 0.86) | Toasts, panel content changes, crop-handle settle |
| `smooth` | `.spring(duration: 0.40, bounce: 0)` | Page changes, onboarding steps, popover resize |
| `numeric` | `.contentTransition(.numericText(value:))` + `.monospacedDigit()` | Stats, at most 1 update/s and only while visible |

- **Ceiling:** 0.45 s. Most motion runs 0.15–0.28 s. Exits take about 0.7× the enter duration.
- **Enter:** opacity 0→1, scale 0.96→1, y +6 pt, blur 4→0.
- **Toast:** y +8 pt, 1.6 s dwell. Hover pauses it.
- **Stagger:** 25 ms × the first 6 items, only on a page's first appearance.
- **Bounce:** 0.05 or below. SwiftUI presets default to 0.5 s with bounce 0/0.15/0.3 (smooth/snappy/bouncy, verified in the macOS 26.5 SDK), so pass explicit durations.
- **Springs only, interruptible.** Never block input.
- **Glass morph** (`GlassEffectContainer` + `glassEffectID`) only for the editor toolbar.
- **Haptics:** `NSHapticFeedbackManager` `.alignment` on crop edge snaps and CornerClick S/M/L detents, and `.levelChange` on thickness steps. Never on hover or drag.
- **Reduce Motion:** a 0.15 s fade, no bounce, no stagger, no blur (HIG: avoid "animating into and out of blurs").
- **Idle performance:**
  - No `repeatForever`, `TimelineView(.animation)` or animated menu bar icon.
  - Sampling stops within 1 s of hiding.
  - SwiftUI animations tick in-process (Macomber), so prefer no motion, or Core Animation layer animations, for anything long.
  - Sensors are Stats' heaviest module, so read them only while visible.

## E. Anti-patterns to avoid

- Animated keyboard-invoked palettes. Motion over 0.45 s or that can't be skipped.
- 5 s floating thumbnails after a clipboard capture.
- Glass on glass, tinted glass on several controls, custom sidebar or toolbar backgrounds, and fake corner radii (Heger: Tahoe's corners already hurt resizing).
- Gradients, glows, gloss, colored charts or icons, and meaning carried by color alone.
- Scale-from-0, ease-in entrances, springs with bounce of 0.15 or more, and stagger in frequently used lists.
- Proportional digits that jitter in width, and live menu bar animation.
- Kitchen-sink settings, and toasts or panels that steal focus.

## F. Sources

- X: [Tendedero](https://x.com/alejandr0bujan/status/2107726966304690416) ([repo](https://github.com/alejandrobujan/tendedero)) · [freewrite](https://x.com/FarzaTV/status/1910789505722036357) · [notch agents](https://x.com/edwardluox/status/2078111197212414447) · [MacTap](https://x.com/jaskirat/status/2097465888341643650) · [Bryl Lim](https://x.com/bryllim_/status/2099049704822907277) · [Mole](https://x.com/HiTw93/status/2056172775291973758) · [CleanShot 5](https://x.com/CleanShot/status/2094803447920967862) · [Raycast 2.0](https://x.com/raycast/status/2054878311541850293) · [Droppy](https://x.com/Droppyformac/status/2107416617940291587) · [Emil monochrome](https://x.com/emilkowalski/status/2072301069271552363) · [Emil small apps](https://x.com/emilkowalski/status/2074600259443921078) · [press](https://x.com/emilkowalski/status/1952354760637505541) · [scale 0.93](https://x.com/emilkowalski/status/1954891053032755560) · [blur 2px](https://x.com/emilkowalski/status/2028470888090280392) · [blur + stagger](https://x.com/emilkowalski/status/1987892934587412676) · [Rauno](https://x.com/raunofreiberg/status/2049592715860447540) · [MKBHD](https://x.com/MKBHD/status/2064034468005073147) · [Diego](https://x.com/1000kilobytes/status/2074978753747558882) · [Valerian](https://x.com/valeriansaliou/status/2084925453760930033) · [Macomber](https://x.com/kylemacomber/status/2100029347419877794)
- Essays: [Emil, You don't need animations](https://emilkowal.ski/ui/you-dont-need-animations) · [Great animations](https://emilkowal.ski/ui/great-animations) · [animations.dev vocabulary](https://animations.dev/vocabulary) · [Rauno, Invisible Details](https://rauno.me/craft/interaction-design) · [Linear refresh](https://linear.app/now/behind-the-latest-design-refresh) · [The New Raycast](https://www.raycast.com/blog/the-new-raycast)
- Apple: HIG [Menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) · [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [Color](https://developer.apple.com/design/human-interface-guidelines/color) · [Motion](https://developer.apple.com/design/human-interface-guidelines/motion) · [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) · [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) · [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) · [WWDC23 Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/) · macOS 26.5 SDK (`SwiftUICore.swiftinterface`, `NSHapticFeedback.h`)
- Reference apps: [Raycast Clipboard](https://manual.raycast.com/clipboard-history) · [Raycast Windows](https://manual.raycast.com/window-management) · [Shottr](https://shottr.cc/) · [CleanShot](https://cleanshot.com/features) · [iStat Menus](https://bjango.com/mac/istatmenus/) · [Stats](https://github.com/exelban/stats) (`Kit/constants.swift`, `Modules/Battery/popup.swift`)
- OS context: [macOS 27 glass changes](https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/) · [26.1 Tinted](https://techcrunch.com/2025/10/20/apple-will-let-users-roll-back-the-liquid-glass-look-with-new-tinted-option) · [Heger corners](https://gigazine.net/gsc_news/en/20260113-macos-tahoe-windows)
