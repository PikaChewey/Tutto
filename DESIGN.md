# DESIGN — Tutto (menu bar panel and identity, v5)

Binding for the menu bar panel, the menu bar glyph and the app icon. Sources:
- X posts and Hacker News threads, read 2026-10-26 and 2026-10-27 (27 + 18), plus five on dark and monochrome icons read 2026-11-02. Dates and engagement were confirmed through api.fxtwitter.com and HN's Algolia API, and the replies were read (for the 2026-11-02 posts, the posts and their pictures only).
- Apple's HIG on app icons and menu bar extras, plus the Icon Composer documentation.
- Bryan's house style: Download More RAM's and Grab's `DESIGN.md`. The house style wins where X and the house disagree.
- Bryan on the panel. Version 1 (716 pt): "very cluttered". Version 3 (475 pt): "a bit too minimalistic … create a new mix of the old GUI and what it is currently". Version 4 is that mix.
- Bryan on the mark: the "tt" of v3 "genuinely just looks really bad"; of ∀, "i dont even get what it is". On the sliders in white glass (2026-11-02): "i think id prefer a more minimalistic app icon for tutto. like maybe a more like dark themed colour palette", and "i liked the original tutto one where it was black with a 2x2 grid outline where bottom right was white, its just that that didnt really fit tutto anymore".

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
| I16 | [A first-party icon goes black and white](https://x.com/zollotech/status/2110079336569090544) | 2026-10-13 | 1,131 / 51K | A music app's coloured icon reduced to one black symbol on white; the reactions split between cleaner and missing the colour it was known by. |
| I17 | [Same icon, final release](https://x.com/itsdurreadan/status/2114791472834990382) | 2026-10-26 | 1,778 / 114K | Shipped as the final icon with "no Liquid Glass detailing": black and white is now a first-party look. |
| I18 | [The same rebrand, defended](https://x.com/sabeshbharathi/status/2113263520703975569) | 2026-10-22 | 132 / 10K | A first "this ain't it" turned around once glass carried the look. |
| I19 | [Why the new icons look flat](https://x.com/OutofGalaxyy/status/2073597296487362890) | 2026-07-05 | 431 / 31K | Icons look most like real glass in the dark tinted look; a solid white glyph on a light field hides the highlights that make glass read. |
| I20 | [Glass on black, rebuilt in Icon Composer](https://x.com/flyosity/status/2093512419410628940) | 2026-08-29 | 163 / 7.6K | Glass shapes on a black field, rebuilt from a 3D and image-editor workflow in Icon Composer. |

Kept from the house style: posts on one object and one number, a quiet bar, glass that costs time, and counting the animations (Download More RAM's `DESIGN.md`, rows 1, 5, 30, 31).

## 2. Principles

1. **A verdict, then the detail** (3, 4, 16, 20, 22). The header pairs the mark with how the Mac is doing in plain words, from measurements only: a problem first, otherwise the battery's state. The battery card follows (percent, watts, health, cycles, and the three apps using the processor most), then the tiles. Every number opens its page.
2. **Detail lives inside tiles, not in more sections** (16, 17, 18, 21). Six tiles in two columns: CPU, memory, GPU, disk, network, temperature. Each has an engraved caption and a detail on top, and the number with the last minute as a line (or a meter) beneath. Version 1 stacked captioned sections; version 3 dropped the detail. Tiles carry it without either.
3. **Only what you click the menu bar for** (1, 2, 15). Settings, health history, process tables and Trackpad Corner's editor live in the app. The fan's Auto / Custom / Max came back into the panel as a card of its own (Bryan, 2026-10-28: "very useful and convenient to have there"); its helper set-up and full page stay in the app. The rare toggles (pause clipboard history, pause Trackpad Corner) sit in the ⋯ menu.
4. **Sound is a strip of apps, not a mixer** (5, 8, 9). Click an icon to mute it. A muted icon is greyed with a slash badge; one that's playing wears a speaker badge in the accent. "Unmute All" appears only when an app shown there is muted and unmutes just those (an app muted while it's closed stays muted).
5. **The tools are a grid, keys included** (12, 2). One row of six tiles: a symbol, a short name and the keys as small keycaps. Clicking one lights its keys one after another, as if pressed, then the tool runs. The list is built from the live bindings, so it can't drift.
6. **Show your own cost** (19, 24). The footer shows what Tutto itself uses right now ("31 MB · 0.1 % CPU"). The busiest-apps list reads the kernel directly (no `top`), so opening the panel starts no process.

7. **The auto clicker is one line that opens** (13, 12, 23; Bryan 2026-11-11: "kind of scuffed … very cluttered"). Closed: "Auto clicker", what it'll do ("10 CPS · 1 min") with a small chevron, and its switch; the name and detail are one button that opens it. Open: a quiet well with three settings, each a name on the left and one control on the right (Speed: − 10 CPS +; Click: a pop-up for button, double-click and where; Stops: a pop-up of times and click counts), then its keys as keycaps and "All settings". While it runs the line says "Clicking" with the speed, or the time left when it stops after a time; changes apply at once. No click count anywhere (Bryan, 2026-11-11: "you don't need to have the number of clicks in the GUI … maybe just a small one to show how to cancel it and the keybind"): the pill at the top of the screen is set once per run and says only how to stop it ("Auto clicker ⌃⇧A or a corner stops it"), with nothing moving. Version 1 said the speed three times when open (header, a bare stepper number, a summary line), floated the chevron far from what it opens, wrote the keys as text and left the timer to the app. Other Mac clickers ([Clicker](https://github.com/xentriom/Clicker), [Clakr](https://github.com/SenpaiHunters/Clakr), [Tapper](https://apps.apple.com/app/id6743667204), [Tap-Bot](https://apps.apple.com/us/app/tap-bot-auto-click-refresh/id6444782835), read 2026-11-11) agree on the same few things: speed, a hotkey, a run limit; most add a live count, which Tutto leaves out.

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

**Mark.** Three sliders: the controls the panel holds. The app icon draws them the way the first Tutto icon was drawn: a near-black field, the tracks in white glass at 24 % (on black they read as outlines) and the knobs in solid white glass, the one lit thing. Three tones, no colour; the GUI's ink and paper. It takes two words to name ("the sliders"), and it says what Tutto is: one place for the Mac's controls. Bryan asked for it minimal and dark, like the first icon (2026-11-02, quoted above); on ∀, the mark before the sliders: "i dont even get what it is", and "why does it have a maximalist colour theme?? … doesnt match with any of the GUI".

**Chosen by** (2026-11-02, Bryan's pick):
- **Three concepts in the first icon's recipe** (black, white glass at 24 %, one solid white shape), each rendered in every macOS look, at 16/32/64 px, in a Dock on a black desktop and with its menu bar glyph:
  - **Levels** (chosen): the sliders. The app icon, the menu bar glyph and the panel's mark stay one drawing, and the glyph reads as a system symbol beside volume and Wi-Fi.
  - **Corner:** the first icon grown to nine tiles, the top-right one lit (where Tutto sits). The closest to the first icon, but its glyph is a dot grid.
  - **Strip:** three windows side by side, the one you're on lit. Its glyph is three bars, beside the dictation app's waveform.
- **Variants tried:** heavier knobs (64 px tracks, 88 px knobs) looked bold rather than minimal; one knob lit and two dim stopped reading as sliders at 32 px.
- **Before** (2026-10-28): the same sliders on white glass, graphite fills with the top one in the system blue, chosen over Panel (the panel in miniature; reads as a stats app) and Tiles (reads as a launcher).

**Menu bar glyph:**
- An 18 × 16 pt template image drawn like the system's slider symbol: each line stops at its knob, a ring.
- On Retina: 1.5 pt lines centred at y 12.75, 8.25 and 3.75, so each is three full pixel rows, with rings of 2.1 pt radius at x 11.5, 6 and 10 (the icon's levels).
- A separate 1x drawing: 1 pt lines and 2 pt rings on pixel centres.

**App icon** (`Resources/AppIcon.icon`, Icon Composer):
- **Fill:** solid near-black (sRGB 0.043 / 0.043 / 0.047), the first icon's; the dark look lifts it to graphite.
- **Two groups, front to back, both white glass with a neutral shadow:**
  - knobs (solid): discs of radius 78 px;
  - tracks (24 % opacity, translucency 50 %): capsules 52 px high.
- **Geometry on 1024:** rows at y 328, 512 and 696; tracks from x 188 to 836; levels at 70, 32 and 56 %.
- `scripts/make-icon-layers.swift` writes the whole document. Checked with `ictool` in the default, dark, tinted and clear looks, and at 16, 32 and 64 px.

**Tried and rejected earlier:**
- the four-quarter tile (the old mark, from Trackpad Corner);
- "tt" (lettering);
- ∀, "for all" (not understood; amber on navy matched nothing in the GUI), and the five concepts that lost to it: overlapping circle and square, a pocket multi-tool, a slit of light, a lit seven-segment 8 and a prism;
- the sliders on white glass with graphite and blue fills (not minimal enough, and light where Bryan wanted dark);
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

## 5b. Version 5: fits the screen (2026-11-12)

Bryan, on v4 with every tool on: "the menu bar GUI is getting very long and cluttered … over extending the verticality of my macbook … the GUI could be more organized", and "dont make the GUI look exactly like vorssaint". His screenshot measured 938 pt on a 945 pt screen, and it "isnt even the longest it can be".

Read 2026-11-12, confirmed through api.fxtwitter.com and HN's Algolia API:

| # | Source | Date | Likes / views | Taken |
|---|---|---|---|---|
| 25 | [Apple Silicon monitor](https://x.com/GitHub_Daily/status/2069601434077921763) | 2026-06-24 | 157 / 13K | Sensor rows that expand and a process card that scrolls inside itself: depth is hidden until asked for. |
| 26 | [macOS 27 menu bar overflow](https://x.com/aaronp613/status/2064124339767636148) | 2026-06-08 | 1,434 / 93K | The system itself collapses what doesn't fit behind a "more" control. |
| 27 | [Native, single-purpose menu bar app](https://x.com/t11s__/status/2115146796846723178) | 2026-10-27 | 111 / 30K | ~20 MB and 0 % at rest is the pitch; scope discipline reads as quality. |
| 28 | [Show HN: a menu bar app, crowding](https://news.ycombinator.com/item?id=49952148) | 2026-10-04 | 89 pts / 28 comments | "The last thing most of us need is even more clutter in that space." |
| 29 | [The competing all-in-one](https://x.com/tom_doerr/status/2095705215496253930) | 2026-09-04 | 125 / 12K | Its panel (README images): a capsule of eight icon-only tabs with a blue active square, a logo on top, letter-spaced caps section labels, one big charcoal card, blue toggle cards, and a Settings / Quit button pair. Tutto must not look like this. |
| 30 | [Its mixer tab](https://x.com/mattdagley/status/2105978036310945988) | 2026-10-02 | 3 / 392 (image only) | A full mixer with pill sliders and per-app device pop-ups, ~700 pt tall. |

Rules (they extend principles 1–7):

8. **The panel never outgrows the screen** (25, 26). The header and footer stay put; the cards between them scroll inside the panel once they'd pass the screen's height (visible frame − 24 pt). Default layout with everything on: about 700 pt, not 940.
9. **Depth on demand, not on show** (25, 26, 9). The busiest apps are one row of chips (icon and CPU %; the name on hover), not three rows. Levels replace the app strip instead of adding a mixer under it, and list every open app (Bryan 2026-11-12: an app that's quiet now may play later), muted first, then playing; past eight the list scrolls inside the card. Levels stay open between opens of the panel.
10. **The tools are a bar, keys on hover** (12, 2, 27). One row of icon buttons; pointing at one shows a small floating label with its name and keys (no layout shift); a click still lights the keys as if pressed.
11. **No tabs** (29). Tabs hide what you came for behind a guess, and an icon-only tab capsule is the competitor's signature. Tutto stays one calm scroll of cards in its own monochrome ink-and-paper look.
12. **Three tiles for the controls, a grid for the readings** (14, 16, 26; Bryan 2026-11-12: "its still so cluttered … just make it cleaner"). The six readings sit three across as a label and a number with a faint line; their details are in the tooltip, their charts on the pages they open. Stay awake, the auto clicker and the fan were three small tiles with menus; Bryan found that too minimal and, shown four layouts side by side (tiles, rows, typed lines, tiles with a drawer), picked the rows: one card, a line each, with the time field and chips, the clicker's switch and settings, the fan's Auto / Custom / Max. Measured: 938 pt (v4) → 512 pt.
13. **Laid out to the point** (Bryan 2026-11-12: "the entire GUI is squished such that frames don't fit"). Every card, tile and row is sized from the cards' width (300 pt): readings and control tiles are exact thirds, and a Sound level's slider takes what the icon, name and level leave. A fixed 126 pt slider had made each level line 322 pt wide in a 300 pt card, which widened the cards' column and pushed the whole panel 11 pt left, past its window. Renders run through the same scroll view the menu bar uses, so a card wider than 300 pt shows as clipped corners there.
14. **Bars at the top of the screen stay under the notch** (Bryan 2026-11-12). The scrolling-capture bar, the recording bar, the auto clicker's bar and the archive progress go no higher than `NSScreen.hudTop`: under the menu bar, and under the camera housing when a full-screen app hides the menu bar.

## 6. Anti-goals

- **Bryan's:**
  - clutter (version 1);
  - too minimal (version 3);
  - settings in the panel;
  - lettering as a mark ("tt");
  - a mark that needs explaining, in colours the GUI doesn't use (∀ in amber on navy);
  - a light, many-toned app icon (the sliders on white glass): he wants it minimal and dark;
  - grey hairline lists;
  - a wall of uppercase captions (captions live inside tiles);
  - unreadable icons;
  - hint or fluff text;
  - orange next to green;
  - anything costing battery while idle;
  - memory that grows over hours.
  - looking like the competing all-in-one (29): no icon-only tab capsule, no logo above the cards, no letter-spaced caps section labels, no Settings / Quit button pair, no blue toggle cards, no charcoal shell with blue, green and cyan charts;
  - a panel taller than the screen (v4, 938 pt).
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


## Liquid Glass preview (2026-11-12)

Bryan: "design and then show me a preview of a glass version, similar to … apple new glass rework … research … how the UI looks so good and also how the UX works so good." Built as the `Liquid Glass` theme (`Background.liquid`, macOS 26 only, `Design/LiquidGlass.swift`), rendered with `--snapshot DIR glass-stage "theme:Liquid Glass" wall-dark:<img> wall-light:<img>`: glass can't be drawn offscreen, so the panel is put on screen over a wallpaper and captured. Not offered on the Appearance page yet: the menu bar's own window brings a plain 16 pt material, and the theme needs that window to become the glass sheet.

**Apple's guidance** ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/), [Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/), [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/)): glass is the functional layer floating over content; it lenses light rather than scattering it; regular for text-heavy surfaces like popovers, clear only over media with a dimming layer; never mix the two; avoid glass on glass and use fills and vibrancy on it; shapes are fixed, capsule or concentric (the parent's radius less the padding); tint only the primary action; controls morph and menus open from their source; glass materializes by modulating its lensing instead of fading; Reduce Transparency, Increase Contrast and Reduce Motion apply on their own.

**What people say** (confirmed dates and counts): [@chan_k](https://x.com/chan_k/status/1932185261162766459) 2025-06-09, 28.2K likes, "bend and shape light"; [@XorDev](https://x.com/XorDev/status/1932429551256101328) 2025-06-10, 10.1K likes, contrast and readability first; [@ClassicII_MrMac](https://x.com/ClassicII_MrMac/status/1933211756442050881) 2025-06-12, 441 likes, Reduce Transparency to get the menu bar back; [@minimalnerd1](https://x.com/minimalnerd1/status/1999184120099012794) 2025-12-11, mixed glass styles in the menu bar; [@SnazzyLabs](https://x.com/SnazzyLabs/status/2008277783211110810) 2026-01-05, 372 likes, glass on the Mac ignoring the HIG; [@BetaProfiles](https://x.com/BetaProfiles/status/2056390509292314955) 2026-05-18, 2.1K likes, early glass too clear; [@BasicAppleGuy](https://x.com/BasicAppleGuy/status/2066942999272235160) 2026-06-16, 1.8K likes, refraction and specular control; [@shadcn](https://x.com/shadcn/status/2096797264370950464) 2026-09-07, 1.7K likes, "some of the glass, almost none of the liquid", menus should open instantly; [@bidah](https://x.com/bidah/status/2081789573160419761) 2026-07-27, glass only for navigation; HN [45544044](https://news.ycombinator.com/item?id=45544044) (752 points), [45648266](https://news.ycombinator.com/item?id=45648266) (207), [45174297](https://news.ycombinator.com/item?id=45174297) (495): legibility, Increase Contrast over Reduce Transparency, springy motion liked, lag disliked.

**Rules taken:** one sheet of regular glass (the panel); cards are platters on it (translucent fill, a hairline of light on the top edge), so text never sits straight on clear glass; controls on the sheet (chips, buttons, the segmented thumb, the tools bar's lens) are raised platters too: real glass inside the glass drew as dark blobs and hid its own label on the stage; only the floating tool label is glass of its own; corners concentric (sheet 26, cards ≈17, capsules for controls); the lens glides between icons on a spring and magnifies the icon 1.14×; the label grows out of its icon; the switch is the system's (accent track, white knob); nothing animates at rest and opening the panel stays instant.

**Default since 2026-11-12** (Bryan: "add glass as the default option … and then have a setting in appearance … to change it to what it is currently"). Liquid Glass is the look on macOS 26: once, the theme in use moves to it and is kept as **Classic** (`theme.classic`; Bryan's was Forest); Appearance › Look switches Liquid Glass ⇄ Classic, and Liquid Glass also leads the theme gallery and the Panel background choices. In the menu bar the sheet is the system's own: the panel's window gets its glass from the window server (no view or layer of ours draws it, checked with a view and layer dump), and a second sheet of ours over it doubled the glass and darkened it over a bright wallpaper, so there the cards sit straight on the system's glass. Only the glass stage draws its own 26 pt sheet.

**Floating glass, shipped 2026-11-13** (Bryan, shown the installed sheet: "i dont think it looks glassy enough … not as clean or smooth as the actual glass from apple"; shown three prototypes, picked "A · Floating glass"). The panel has no sheet: every card, the header and the footer are their own pieces of Liquid Glass with a rim of light (`GlassRim`), and the desktop shows in the gaps, as in Control Center. That needs a clear window, which MenuBarExtra's isn't (its material is drawn by the window server), so the icon and the panel are Tutto's own (`MenuBar/PanelController.swift`): an NSStatusItem saved under MenuBarExtra's old name (`Item-0`, so it keeps its place; macOS 26's `VisibleCC` flag is set shown) and a borderless, clear, non-activating panel that can take the keyboard. It opens under the icon (centered, 8 pt inside the screen, its top fixed as it grows), fades in over 0.1 s, and closes on a click elsewhere, Esc, the icon again, or switching apps or Spaces; it is built fresh on open and dropped on close, so readings stop with it. The Classic look draws the system popover material and a hairline itself. Laying the glass out inside the click's own Accessibility callout, before the window was on screen, overflowed the stack in SwiftUI's glass code: the window goes on screen first and the toggle runs a moment later on the main queue.

**Frosted frame, 2026-11-13** (Bryan, on the installed floating glass: "it looks a bit odd … bare naked … everything surrounding it and in between the frames is perfectly seen"; asked to choose between the Battery / Wi-Fi menus' one translucent frame and Notification Center's colourless frosted pane, "considering which would do the best on X"). Chose Notification Center's: the floating glass cards stay (the shareable, distinctive part; the Battery / Wi-Fi look is every menu bar app's), and behind them one frosted frame (26 pt corners, a faint rim) blurs whatever is behind the panel without colouring it, which answers the most repeated complaint about Liquid Glass (text over busy backgrounds). Material `fullScreenUI`, chosen from four rendered over Sonoma, Tahoe and the real desktop: it blurs and keeps the wallpaper's colours, where `hudWindow` darkens and `underWindowBackground` goes near black.

**Clear sheet, 2026-11-13** (Bryan, on the frosted frame: "the notification centre equivalent for the GUI doesnt look the best, take more from the outer frame from the original option B"). The panel is now prototype B for real: one sheet of `Glass.clear` (the most see-through glass) in Tutto's own clear window, a rim of light around it, cards as barely-there platters with their own rims, header and footer straight on the sheet. The desktop's colour comes through instead of a grey frost. 

**Pane, 2026-11-13** (Bryan, on B's sheet installed: "almost completely opaque and that doesn't really match the glass vibe ... at minimum, the background frame should be more glassy"). Cause, found by rendering over a capture of the real screen behind the panel: clear glass blurs away everything behind it, so over a dark app window (his usual backdrop) it shows nothing and reads as a dark slab whatever the dimming (28 %, 20 %, 10 %, 0 % and a 38 % version all looked alike there). The frame is now a pane without blur: the desktop shows through it, darkened 16 % (paled 8 % in the light look), with a rim of light (1.5×) and a sheen brightest along the top, so it reads as glass even over a black window. Cards are each their own glass on it (as in A), which keeps their text legible over the busy window now visible through the frame; flat cards on the clear pane were unreadable there (rendered and rejected), and white-tinted clear glass only turned the frame grey.

**Frost, 2026-11-13** (Bryan, on the pane: "what I meant by making the background more translucent. I meant the frame that encompasses the entirety of the menu bar, not just like the background frames for CPU, battery, memory, stay awake"). Over a window the pane all but vanished: only its rim showed, with the text behind crisp in every gap, so it read as no frame at all. The frame is B's sheet of `Glass.clear` again, now frosted rather than dimmed: a 6 % white frost in the dark look (8 % in the light), light scattered by the glass, so over a dark window it reads as frosted glass, a shade lighter than what's behind, instead of a dark slab; the sheen and the rim stay. Cards stay their own glass, which keeps their text readable over a white page as well as a dark window (rendered over the real desktop, Sonoma, Tahoe and a white page; flat white platters went unreadable over the white page in the dark look, and a half-opacity sheet put crisp text behind the cards). In the real window the clear glass blurs less than on the stage: what's behind shows through softened.

## Convert & Compress card and result card (2026-11-13)

Bryan: compressing "is a pretty important and convenient feature and should be something that people can access easily and not something hidden in like the horizontal taskbar". Research on the leading Mac media optimizer (its public source is GPL-3.0: mechanics borrowed, no code; its site and repo, and its users on Product Hunt, MPU Talk and Hacker News, read 2026-11-13; open-source neighbours [ImageOptim](https://github.com/ImageOptim/ImageOptim), [Squoosh](https://github.com/GoogleChromeLabs/squoosh), [Kompakt](https://github.com/edinabazi/Kompakt), [Konverter](https://github.com/davidpraznik/Konverter)). What people praise: it happens by itself ("automatically optimizes downloaded images and screenshots"), and the little card after each file ("highly addictive to see the notification"). What they complain about: limits and price, settings that are hard to find, a 105 MB download of bundled encoders.

- **The panel card, Convert & Compress, v3** (Bryan: "isn't just compress—it also has file conversion and stuff"; "don't make it automatically expanded"; then "I don't like the GUI ... it's like sort of cluttered right now. Do research online about how tools like these look and how they have nice UX"). v2 showed four tiles with four dropdown chips at rest (eight controls). v3 shows what a drop will do and nothing else until files move:
  - **Closed:** one line, its name, what compressing has saved (opens the Convert page) and an arrow.
  - **Open, at rest:** one dashed drop well that says exactly what a drop does, "Drop files to convert to JPEG", "or click to choose them"; one ⌃⌄ menu at its end picks the action with its setting (Compress › Smaller copies | One .zip, Convert to › formats by kind, Resize › sizes, Crop › shapes and sizes). One primary action, one secondary.
  - **While files are dragged over the panel:** the well becomes four targets, Compress · Convert · Resize · Crop, each with its setting under it; the one under the files lights up in the accent, grows 6 % and solidifies; targets that don't suit the dragged files (read once from the drag pasteboard) dim to 40 %. Closed, the one line becomes the four targets at the same 28 pt height, so the panel never jumps (the drop surface replaces content instead of pushing it, as the drop-zone posts below do). ⌥ on a drop opens the Convert window; ⇧ while dragging anywhere still opens the wheel.
  - **Under it:** the last result as a row: its picture, its name, "83 % smaller · 410 KB" in words (a signed "−83 %" reads either way), Undo and Show only under the pointer; drag the row out to use the file.
  - **Motion:** the tools bar's lens spring (0.3 s, bounce 0.18) for the well, targets and hover; nothing moves at rest.
- **The result card** (bottom right, 340 pt, glass): the picture, the name, "169 KB → 68 KB · 60 % smaller" with the saving in the accent, what happened, then Undo · Half · Crop · Show as chips. Drag the picture out. 12 s, kept while the pointer is on it.
- **Research for v3** (2026-11-13; X posts confirmed for date and engagement; Reddit refused automated reading, so user voice is from X replies, HN, Setapp and the App Store; names and links kept out of this repo, sources logged in the session's research notes). Patterns kept, each seen in 3+ sources:
  - *Where you drop is the choice.* A Mac converter's "hold ⇧ and drag" ring of formats (X, 2026-10-01, 4,285 likes, 415K views; 2026-09-07, 1,461 likes, 123K views); an open-source converter's "hold a key, drag, drop on the format" donut (X, 2026-10-20, 913 likes, 47K views; 2026-10-19, 287 likes, 56K views); a right-click "pick a format, done" converter (X, 2026-10-07, 4,921 likes, 330K views; replies: "so simple and elegant, should come with the OS").
  - *Only valid targets show; the drop surface appears when a drag starts.* Two menu bar compressors and two shelf apps show their drop zone only once a drag begins; the donut shows "only the ones that make sense for the files you drag".
  - *Drop zones float over content, no resize jitter, corners matching macOS 26* (a terminal maker's drop-zone animation, X, 2026-06-25, 712 likes, 84K views; 2026-06-29, 1,593 likes, 105K views).
  - *Readable glass:* glass for controls, not under text people read (a launcher's designer, X, 2026-11-06, 154 likes, 46K views); bouncier, native-feeling springs, not "aggressive" pop-ups (a reply under the 4,285-like post; Control Center's bouncier tiles, X, 2026-09-17, 567 likes; system pop-ups' stretch physics, X, 2026-09-20, 896 likes; fluid interactions built as in-process animations, X, 2026-09-16, 895 likes, 196K views).
  - *Smart defaults, settings off the main surface, results that keep the original, one honest number* (an image optimizer that starts on drop with no choices; a compressor showing "Original kept" instead of a negative saving; a web compressor's author on "-30 %" confusing people, HN).
  - Rejected: a ring at the cursor as the only way in (the panel already has the ⇧ wheel); pop-ups that scale in hard; choosing the format after the drop in a window (two clicks more than a target).
- **Panel scrolling** (Bryan: the scroll bar "is very fat and takes up a lot of the UI ... Make it like right next to the border of the outer frame ... way thinner"). The system scroller (11 pt, on the cards' edge) is hidden; a 3 pt line runs in the panel's margin along the frame while scrolling, 7 pt with a faint groove under the pointer, dragged or clicked to jump; it shows once when the panel opens if it scrolls, and fades 0.9 s after the last move. Content fades out over 14 pt at an edge that has more beyond it. (Browser engines that imitate macOS's overlay scrollers widen on hover and hide after half a second idle.)
- **One hover for the whole panel** (Bryan: the tools bar's hover "feels super smooth and it feels super clean, but the rest of it doesn't"). The tools bar's lens (raised glass, its spring, a small swell: 5 % for text, 12 % for icons) is now every hover: chips, links, the footer, segmented options (a faint lens under the thumb's height), the sound strip (one lens sliding along it, as on the tools bar), the card's buttons; tiles and plugin cards lift (brighter rim, a sheen, 2 %). Every press pushes in to 97 %. `Design/Lens.swift` holds it.
- **Nothing by itself** (Bryan, 2026-11-13: "dont make auto a feature for compressing screenshots, it just doesnt make sense"). Compressing new screenshots, recordings and copied pictures by themselves, and the **Auto** switch for it, are gone: a screenshot is for sharing as it is, and a file changed behind your back is a surprise. Files are compressed only when you drop or choose them, and only copies are made. Nothing is watched at rest (no folder stream, no clipboard timer).
