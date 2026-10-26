# DESIGN — Tutto (menu bar panel and identity, v3)

Binding for the menu bar panel, the menu bar glyph and the app icon. Sources:
- 27 X posts and one Hacker News thread, read 2026-10-26. Dates and engagement were confirmed through api.fxtwitter.com and HN's Algolia API, and the replies were read.
- Apple's HIG on app icons and menu bar extras, plus the Icon Composer documentation.
- Bryan's house style: Download More RAM's and Grab's `DESIGN.md`. The house style wins where X and the house disagree.

Other apps go unnamed here, as everywhere in Tutto.

## 1. References

| # | Post | Date | Likes / views | Taken |
|---|---|---|---|---|
| 1 | [Menu bar system HUD](https://x.com/HiTw93/status/2056172775291973758) | 2026-05-18 | 1,298 / 124K | Tiles for CPU, memory, network, disk, GPU and temperature, with large numbers and small units. Replies asked to choose fewer stats. |
| 2 | [Same HUD, later release](https://x.com/HiTw93/status/2069057881765503136) | 2026-06-22 | 974 / 132K | A user couldn't find an action in the stats panel; the author pointed to its hotkey. |
| 3 | [Open-source memory cleaner](https://x.com/virgilerietsch/status/2107463995070291985) | 2026-10-06 | 979 / 159K | Leads with a sentence-case verdict ("memory is the bottleneck"), then one hero number. |
| 4 | [Open-source "room to work" panel](https://x.com/coreyhainesco/status/2111465009754882178) | 2026-10-17 | 124 / 9K | No uppercase captions; a verdict line; app rows with icons; a footer. |
| 5 | [Stats dropdown with per-app sound](https://x.com/attacomsian/status/2103963942091649344) | 2026-09-26 | 151 / 15K | Per-app sound was called worth the price; a footer with open-app, gear and quit. |
| 8 | [Multi-output audio panel](https://x.com/BarryBarrywu/status/2074756054081278432) | 2026-07-08 | 1,150 / 109K | Shows what's actually playing; people bought it for the UI. |
| 9 | [Per-app volume question](https://x.com/adxtyahq/status/2056094544996053393) | 2026-05-17 | 102 / 18K | A full mixer is "stressful" for something used rarely. |
| 12 | [Bill-in-the-menu-bar panel](https://x.com/sudo_overflow/status/2089622151804735672) | 2026-08-18 | 952 / 79K | A hero number with grey decimals; an action row with its key combo right-aligned. |
| 13 | [Smart-light menu bar panel](https://x.com/jamesm/status/2101286767131513088) | 2026-09-19 | 326 / 29K | Sentence-case headers, rounded cards, one accent for "on". Criticised as "not native, overdesigned" with a slow transition. |
| 14 | [Next macOS Control Center](https://x.com/minimalnerd1/status/2065403001809117588) | 2026-06-12 | 845 / 85K | Clear glass modules without heavy blur, concentric radii, no captions. |
| 15 | [Show HN: cable inspector](https://news.ycombinator.com/item?id=47972511) | 2026-05-01 | 566 pts / 168 comments | Native and tiny was praised; showing implementation detail nobody needs was criticised. |
| I1 | [macOS 26 → 27 icon comparison](https://x.com/BasicAppleGuy/status/2064371585239421035) | 2026-06-09 | 2,627 / 294K | Crisper glass is praised and blurry glass criticised; removing detail is punished. |
| I5 | [Glass flower rebuilt in Icon Composer](https://x.com/luciascarlet/status/2065033082126713179) | 2026-06-11 | 4,044 / 213K | Saturated, crisp glass layers draw admiration; replies say drop the blur for crispness. |
| I6 | [Mascot icon in every appearance](https://x.com/advaithj1/status/2099603907328778708) | 2026-09-14 | 2,425 / 64K | One mark designed for default, dark, clear and tinted. |
| I9 | [Designer: use Icon Composer](https://x.com/ktnr23/status/2066431870888251403) | 2026-06-15 | 3,072 / 193K | A simple mark that works in every appearance; dark and tint control help. |
| I10 | [New battery glyph, too heavy](https://x.com/LuftkoppTim/status/2064075705994891326) | 2026-06-08 | 132 / 3K | Menu bar glyphs must match the system's weight. |
| I12 | [Menu bar item on by default](https://x.com/steipete/status/2089154019885490449) | 2026-08-17 | 313 / 91K | Users decide what lives in their menu bar. |

Kept from the house style: posts on one object and one number, a quiet bar, glass that costs time, and counting the animations (Download More RAM's `DESIGN.md`, rows 1, 5, 30, 31).

## 2. Principles

1. **A verdict, then the numbers** (3, 4, 15). The stats card's title says how the Mac is doing in plain words, from measurements only. A problem comes first, otherwise the battery's state. Four large numbers follow (battery, CPU, memory, temperature); GPU, disk and network sit small on the same four columns beneath. Every number opens its page.
2. **Only what you click the menu bar for** (1, 2, 15). Settings, health details, process lists, the fan modes and Trackpad Corner's editor live in the app. The rare toggles (pause clipboard history, pause Trackpad Corner) sit in the ⋯ menu.
3. **Sound is a strip of apps, not a mixer** (5, 8, 9). Click an icon to mute it. A muted icon is greyed with a slash badge; one that's playing wears a speaker badge in the accent. "Unmute All" appears only when something is muted.
4. **Shortcuts are menu rows** (12, 2). Each row has a symbol and a Title Case name on the left and the keys on the right, set the way a native menu sets them: modifiers right-aligned against a fixed column for the key. Clicking a row lights its keys one after another, as if pressed, then does what they do. The list is built from the live bindings, so it can't drift; ⋯ › Shortcuts… opens the rest.
5. **Structure instead of captions; native; still** (4, 13, 14, 15). Soft cards, sentence-case titles, no uppercase labels, the system material. Nothing moves at rest; motion is hover and press only.

## 3. Tokens (panel)

| Role | Value | Use |
|---|---|---|
| card | `primary` at 5.5 %, radius 12 continuous | groups |
| hover | `primary` at 8 %, radius 8 (concentric with the cards) | rows and numbers; it reaches 6–8 pt past the content, so nothing moves |
| ink / ink2 / ink3 | `primary` at 100 / 84 / 74 % | text. ink2 and ink3 are tuned for at least 4.5:1 on the light menu material (#ECECEC), per `Theme.swift` |
| accent | the system accent colour | what's live: meters, the playing badge, keys lighting up when a row is pressed |
| notice | ⚠︎ in ink2 ahead of the verdict | something worth a look (disk nearly full, CPU busy) |
| alert | system red | battery low, heat, memory full: the ⚠︎, the verdict's detail, the number and its meter |

- **Colour:** the accent marks what's live and red is the only alarm. Nothing else is coloured, and there's no orange.
- **Type:**
  - verdict and card titles: 12.5 semibold, the verdict's detail 12 medium ink3 on the right;
  - numbers: 28 light with tabular digits, units 11.5 medium ink3, labels 11 ink3;
  - the line beneath: 11.5, label ink3 and value ink2;
  - rows: 12.5, with keys in 12 ink3, 4 pt apart so each can light as its own keycap.
- **Grid:** 320 pt wide. Cards sit 10 pt in from the panel's edge and their content 12 pt inside them, so text runs from x 22 to 298; 8 pt between blocks. The stats card is four 69 pt columns shared by both of its lines. Rows are 26 pt. App icons are 30 pt and pulled 3 pt left, so their artwork (not their square) lines up with the text.
- **Motion:**
  - pressing a row scales it to 0.97 over 0.12 s and lights its keys 30 ms apart; the tool runs 80 ms after the last key (with Reduce Motion the keys light at once);
  - hover changes no layout;
  - live numbers update without animation, because on the glass panel every animated frame is drawn on the CPU;
  - Reduce Motion is honoured by the shared tokens.
- **Cost:** while the panel is open it reads only the 1 Hz numbers. No process list runs there, since `top` lives on the Battery, CPU and Memory pages. Closing the panel stops everything.

## 4. Identity

**Mark.** The double t of Tutto: two stems hanging from one bar, the way everything in Tutto hangs from the menu bar. The stems rise above the bar so it reads as "tt", never as π.

**Menu bar glyph:**
- An 18 × 16 pt template image.
- Strokes are 1.5 pt with round caps. The system's own items measure about 1.25 pt (Bluetooth) to 1.4 pt (play), and heavier glyphs get called out (I10); 1.5 is the nearest weight that puts every edge on a whole pixel at 2×, so the glyph has no soft edges.
- Stems sit at x 5.75 and 12.25 and run from 14.25 down to the tails at 1.75. The bar runs from 2.25 to 15.75 at y 10.25.
- A separate 1× drawing uses 1-pixel strokes centred on pixels, for external displays.
- Checked as a template image in the real menu bar at 1× and 2×, beside the system's own items (which render at 229–230 grey, not pure white).

**App icon** (`Resources/AppIcon.icon`, Icon Composer):
- **Fill:** an automatic graphite gradient (sRGB 0.15 / 0.15 / 0.165), following Apple's advice against pure black.
- **Two glass groups:** the stems in front, at 15 % translucency; the bar behind them, opaque.
- **Layers:** white PNGs at 1024 px. With SVG layers macOS turned the mark into dark glass in the dark appearance; PNGs keep it white.
- **Geometry:** a 104 px stroke on 1024. The bar runs from x 215 to 809 at y 415; the stems sit at x 369 and 655 and run from y 257 to the tails at 767.
- **Checked** with Apple's `ictool` in the default, dark, tinted and clear appearances, and at 16 and 32 px, where the mark stays readable.

**Tried and rejected:** a coloured crossbar (thin at small sizes, reads as "ll", and turns grey in the tinted and clear looks); three stacked glass stones; an ampersand (weak at 1× and 16 px).

**Avoid:**
- grids and tiles, the old mark;
- notch pills;
- asterisks and starbursts;
- dot grids;
- a lone "t" on navy;
- capsules with a dot;
- stacked arcs.

## 5. Hero clip (15 s, 4:5, a real recording)

| Time | Shot |
|---|---|
| 0.0 | The real menu bar with the "tt" glyph, the pointer already on it |
| 0.3 | Click. The panel is there in one frame: "On battery · 4 h left", then 35 · 29 · 84 · 67° |
| 2.0 | The pointer runs down the Sound strip; click a browser and it greys out with a slash |
| 4.5 | Click "Capture Area": its keys light ⇧ ⌘ 2 one after another, the panel goes, and the crosshair comes up over an undimmed screen |
| 8.0 | Cut to the Dock icon in light and dark |
| 11.0 | End card: "Tutto. Everything, quietly." |

Captions are no longer than 5 words.

## 6. Anti-goals

- **Bryan's:**
  - clutter;
  - settings in the panel;
  - grey hairline lists;
  - a wall of uppercase captions;
  - unreadable icons;
  - hint or fluff text;
  - orange next to green;
  - anything costing battery while idle.
- **Commenters:**
  - "not native, overdesigned" (13);
  - slow or always-running motion (2, 13);
  - implementation detail nobody needs (15);
  - a full mixer for something rarely used (9);
  - heavy glyphs (I10);
  - blurry glass (I1, I5).

## 7. House style kept

- Native SwiftUI/AppKit, SF Symbols and system type (Geist stays for the app's small captions).
- A template glyph.
- Near-zero cost at rest.
- `Tutto --snapshot DIR panel` renders the panel in light and dark beside the running app.
- Every number comes from a measurement.
