# DESIGN — Tutto (menu bar panel and identity, v4)

Binding for the menu bar panel, the menu bar glyph and the app icon. Sources:
- X posts and Hacker News threads, read 2026-10-26 and 2026-10-27 (27 + 18). Dates and engagement were confirmed through api.fxtwitter.com and HN's Algolia API, and the replies were read.
- Apple's HIG on app icons and menu bar extras, plus the Icon Composer documentation.
- Bryan's house style: Download More RAM's and Grab's `DESIGN.md`. The house style wins where X and the house disagree.
- Bryan on the panel. Version 1 (716 pt): "very cluttered". Version 3 (475 pt): "a bit too minimalistic … create a new mix of the old GUI and what it is currently". Version 4 is that mix.
- Bryan on the mark: the "tt" of v3 "genuinely just looks really bad"; of ∀, "i dont even get what it is".

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

| 16 | [Menu bar system HUD, calmer release](https://x.com/HiTw93/status/2058207787419877735) | 2026-05-23 | 622 / 143K | A verdict ("battery drain is high"), then six 2-column tiles (CPU, GPU, memory, disk, network, fan), each a caption, a number and a detail, then a process list and a footer: about 40 live values in a panel that still scans. |
| 17 | [Same HUD with sparklines](https://x.com/HiTw93/status/2062164018392088652) | 2026-06-03 | 482 / 96K | A small chart per tile (a dual line for network) and a fan segmented control; the author's thread says the release was about making the app calmer. |
| 18 | [Task manager for the Mac](https://x.com/davepl1968/status/2082189145871679587) | 2026-07-28 | 3,463 / 603K | Device rows with current values and charts; replies hope process percentages aren't whole-system scaled. On HN, glow effects "hurt readability". |
| 19 | [Same, summary dashboard](https://x.com/davepl1968/status/2093795413824581793) | 2026-08-29 | 508 / 19K | Replies ask what a watt is (units need a word), and want a light mode under 30 MB: a monitor's own cost is part of its review. |
| 20 | [Open-source USB-C cable inspector](https://x.com/GitHub_Daily/status/2053467649091441064) | 2026-05-10 | 3,862 / 347K | Light rounded cards, a large plain-language diagnosis per port; praise for ending the mystery in plain words. |
| 21 | [Battery app](https://x.com/sobedominik/status/2075476017993642069) | 2026-07-10 | 128 / 21K | Watts in and out, health over time, charge limit on dark glass cards; called "the battery app Apple should have built". |
| 22 | [Menu bar server dashboard](https://x.com/DFintelligence/status/2077350230794621408) | 2026-07-15 | 175 / 16K | A status sentence with a dot, then rows with icons, titles and grey subtitles; captions only as small section labels. |
| 23 | [Next macOS network menu](https://x.com/aaronp613/status/2064115903445233864) | 2026-06-08 | 852 / 28K | Sentence-case section headers, the active connection shown as state; praise is for showing what's actually happening. |
| 24 | [Menu bar AI-usage panel](https://x.com/steipete/status/2055163690790334865) | 2026-05-15 | 158 / 22K | One reply uninstalled it because it was their most energy-hungry app. |
| I13 | [macOS 27 first-party icons](https://x.com/avstorm/status/2099487935015907628) | 2026-09-14 | 16,693 / 1.58M | Sharper glass and bolder shapes praised as a glow-up; the top reply mourns lost depth. |
| I14 | [A new radial mark](https://x.com/avstorm/status/2100218395404784058) | 2026-09-16 | 2,511 / 89K | Replies say radial marks read as an AI logo. |
| I15 | [Archive app icon, simplified](https://x.com/privatetalky/status/2080298458926219283) | 2026-07-23 | 393 / 21K | "Didn't realise it was a zipper until…": an object simplified too far stops reading. |

Kept from the house style: posts on one object and one number, a quiet bar, glass that costs time, and counting the animations (Download More RAM's `DESIGN.md`, rows 1, 5, 30, 31).

## 2. Principles

1. **A verdict, then the detail** (3, 4, 16, 20, 22). The header pairs the mark with how the Mac is doing in plain words, from measurements only: a problem first, otherwise the battery's state. The battery card follows (percent, watts, health, cycles, and the three apps using the processor most), then the tiles. Every number opens its page.
2. **Detail lives inside tiles, not in more sections** (16, 17, 18, 21). Six tiles in two columns: CPU, memory, GPU, disk, network, temperature. Each has an engraved caption and a detail on top, and the number with the last minute as a line (or a meter) beneath. Version 1 stacked captioned sections; version 3 dropped the detail. Tiles carry it without either.
3. **Only what you click the menu bar for** (1, 2, 15). Settings, health history, process tables and Trackpad Corner's editor live in the app. The fan's Auto / Custom / Max came back into the panel as a card of its own (Bryan, 2026-10-28: "very useful and convenient to have there"); its helper set-up and full page stay in the app. The rare toggles (pause clipboard history, pause Trackpad Corner) sit in the ⋯ menu.
4. **Sound is a strip of apps, not a mixer** (5, 8, 9). Click an icon to mute it. A muted icon is greyed with a slash badge; one that's playing wears a speaker badge in the accent. "Unmute All" appears only when an app shown there is muted and unmutes just those (an app muted while it's closed stays muted).
5. **The tools are a grid, keys included** (12, 2). One row of six tiles: a symbol, a short name and the keys as small keycaps. Clicking one lights its keys one after another, as if pressed, then the tool runs. The list is built from the live bindings, so it can't drift.
6. **Show your own cost** (19, 24). The footer shows what Tutto itself uses right now ("31 MB · 0.1 % CPU"). The busiest-apps list reads the kernel directly (no `top`), so opening the panel starts no process.

## 3. Tokens (panel)

| Role | Value | Use |
|---|---|---|
| card | `primary` at 5.5 %, radius 12 continuous | the battery card, Sound, tools |
| tile | `primary` at 5.5 % (8.5 % on hover), radius 10 | the six stat tiles |
| hover | `primary` at 8 %, radius 8 | rows and buttons; reaches 6–8 pt past the content, so nothing moves |
| ink / ink2 / ink3 | `primary` at 100 / 84 / 74 % | text; ink2 and ink3 keep at least 4.5:1 on the light menu material (#ECECEC), per `Theme.swift` |
| accent | the system accent colour | what's live: the tiles' lines (1.25 pt, area at 14 %), meters, the playing badge, pressed keys |
| notice | ⚠︎ in ink2 ahead of the verdict | something worth a look (disk nearly full, CPU busy) |
| alert | system red | battery low, heat, memory full: the ⚠︎, the verdict's detail, the number and its meter |

- **Colour:** the accent marks what's live and red is the only alarm. Nothing else is coloured, and there's no orange.
- **Type:**
  - verdict: 12.5 semibold, with its detail 12 medium ink3 on the right;
  - battery: 24 semibold with the unit 13 ink3; watts 17 medium;
  - tile numbers: 21 medium tabular (network 15), units 11 medium ink3;
  - engraved captions: Geist 10 uppercase with 0.8 tracking, only as tile labels and the battery card's section labels (version 1's character, kept inside tiles);
  - details: 10.5–11 ink3;
  - tools: names 10.5, keycaps 8.5 rounded.
- **Grid:** 320 pt wide. Cards sit 10 pt in from the panel's edge and their content 12 pt inside, so text runs from x 22 to 298, with 8 pt between blocks. Tiles are half that width (146 pt) with 12 pt inner margins, so their text keeps the 22/298 grid. App icons are 30 pt and pulled 3 pt left so their artwork lines up with the text. About 610 pt tall.
- **Motion:**
  - pressing a tool scales it to 0.97 over 0.12 s and lights its keys 30 ms apart; the tool runs 80 ms after the last key (Reduce Motion: the keys light at once);
  - hover changes no layout;
  - live numbers and lines update without animation (on the glass panel every animated frame is drawn on the CPU).
- **Cost:** while the panel is open it reads the 1 Hz numbers, the sensors every 2 s, and every app's processor time every 2 s from the kernel (about 2 ms, no process started). Closing the panel stops all of it.

## 4. Identity

**Mark.** Three sliders: the controls the panel holds. Graphite tracks filled to white knobs, the top one in the system blue, on white glass. These are the GUI's own colours: ink, grey cards and one blue for what's live, as in the panel's meters and lines. It takes two words to name ("the sliders"), and it says what Tutto is: one place for the Mac's controls. Bryan on ∀, the mark before it: "i dont even get what it is", and "why does it have a maximalist colour theme?? … doesnt match with any of the GUI".

**Chosen by:**
- **Three concepts in the GUI's palette only** (white glass, graphite, at most one system blue), each rendered in every macOS look, at 16/32/64 px and in the owner's real menu bar:
  - **Levels** (chosen): three sliders. The only glyph that reads as a system symbol beside volume and Wi-Fi, and the icon shows a control everyone knows.
  - **Panel:** the panel in miniature, a blue line over two tiles. It reads as a stats app, which Tutto is only in part, and its glyph is busy at 1x.
  - **Tiles:** four tiles, one blue. It reads as an app launcher, close to the old four-quarter tile, and its glyph turns into four dots at menu bar size.
- **The blue on the top row:** on the middle row the fill was a stub under the knob, and the one accent should be visible at 16 px.

**Menu bar glyph:**
- An 18 × 16 pt template image drawn like the system's slider symbol: each line stops at its knob, a ring.
- On Retina: 1.5 pt lines centred at y 12.75, 8.25 and 3.75, so each is three full pixel rows, with rings of 2.1 pt radius at x 11.5, 6 and 10 (the icon's levels).
- A separate 1x drawing: 1 pt lines and 2 pt rings on pixel centres.

**App icon** (`Resources/AppIcon.icon`, Icon Composer):
- **Fill:** an automatic gradient from near-white (sRGB 0.965 / 0.965 / 0.975), so the glass is white.
- **Three groups, front to back:**
  - knobs (glass, neutral shadow): white discs of radius 92 px with a 22 px graphite edge;
  - fills (glass, no shadow): the top one in the system blue (sRGB 0 / 0.48 / 1.0), the others graphite (0.17 / 0.17 / 0.19);
  - tracks (flat, no shadow): light grey (0.78 / 0.78 / 0.80).
- **Geometry on 1024:** rows at y 328, 512 and 696; tracks from x 188 to 836, 60 px high; levels at 70, 32 and 56 %.
- `scripts/make-icon-layers.swift` writes the whole document. Checked with `ictool` in the default, dark, tinted and clear looks, and at 16, 32 and 64 px.

**Tried and rejected earlier:**
- the four-quarter tile (the old mark, from Trackpad Corner);
- "tt" (lettering);
- ∀, "for all" (not understood; amber on navy matched nothing in the GUI), and the five concepts that lost to it: overlapping circle and square, a pocket multi-tool, a slit of light, a lit seven-segment 8 and a prism;
- a coloured crossbar;
- three stacked glass stones;
- an ampersand.

**Avoid:**
- lettering;
- symbols that need explaining;
- colours the GUI doesn't use;
- grids and tiles;
- notch pills;
- asterisks and starbursts;
- dot grids;
- capsules with a dot;
- stacked arcs;
- vertical bars (the owner's dictation app wears a waveform);
- radial marks (they read as AI logos, I14).

## 5. Hero clip (15 s, 4:5, a real recording)

| Time | Shot |
|---|---|
| 0.0 | The real menu bar with the sliders glyph, the pointer already on it |
| 0.3 | Click. The panel is there in one frame: "On battery · 4 h left", the battery at 64 % drawing 6.8 W, the three busiest apps, six tiles with their lines moving |
| 3.0 | The pointer runs down the Sound strip; click a browser and it greys out with a slash |
| 5.5 | Click "Area" in the tools: ⇧ ⌘ 2 light one after another, the panel goes, the crosshair comes up over an undimmed screen |
| 9.0 | Cut to the footer: "31 MB · 0.1 % CPU" |
| 11.0 | The Dock icon in light and dark; end card: "Tutto. Everything in one place." |

Captions are no longer than 5 words.

## 6. Anti-goals

- **Bryan's:**
  - clutter (version 1);
  - too minimal (version 3);
  - settings in the panel;
  - lettering as a mark ("tt");
  - a mark that needs explaining, in colours the GUI doesn't use (∀ in amber on navy);
  - grey hairline lists;
  - a wall of uppercase captions (captions live inside tiles);
  - unreadable icons;
  - hint or fluff text;
  - orange next to green;
  - anything costing battery while idle;
  - memory that grows over hours.
- **Commenters:**
  - "not native, overdesigned" (13);
  - slow or always-running motion (2, 13);
  - implementation detail nobody needs (15);
  - a full mixer for something rarely used (9);
  - heavy glyphs (I10);
  - blurry glass (I1, I5);
  - glow that hurts readability (18);
  - units without a word (19);
  - a monitor that is itself the top energy user (24).

## 7. House style kept

- Native SwiftUI/AppKit, SF Symbols and system type (Geist stays for the app's small captions).
- A template glyph.
- Near-zero cost at rest.
- `Tutto --snapshot DIR panel` renders the panel in light and dark beside the running app.
- Every number comes from a measurement.
