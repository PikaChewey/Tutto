# Test results

Machine: MacBook Pro 14" (Apple M5), macOS 26.5.2, Xcode 26.6 / Swift 6.3.3. Date: 2026-10-10.

## Automated (`swift test`)

**194 tests, 0 failures** (146 XCTest + 48 Swift Testing).

| Suite | Tests | Covers |
|---|---|---|
| Trackpad Corner engine (unchanged) | 48 | zone geometry, physical clicks, taps with Tap-to-click on/off, multi-finger rejection, re-click rule, menus, real CGEvents through the tap handler |
| Archives | 68 | zip (store/deflate, ZipCrypto, AES-128/256, splits), 7z (LZMA/LZMA2/PPMd/bzip2, splits), RAR4 + RAR5 stored and multi-volume (hand-built fixtures), tar/pax/ustar with gz/bz2/xz/lzma/lz/Z, cpio, ISO, xar, ar, WARC, CAB, LHA; legacy filename encodings (Shift-JIS incl. 0x5C trail bytes, GBK, Big5, CP949, CP866, CP1251, CP437, Mac Roman…); folder rules; unique naming; path traversal / absolute paths / symlink escapes contained; cancellation cleanup; passwords; refusal of encrypted RAR/7z and zstd/lz4; compress→extract round trips |
| Sensors & fans | 47 | IOHID + SMC readings plausible, junk filtering, grouping/labels, fan reading (1 fan, 2317–6550 rpm here), command clamping, SMC float encoding, mode-key detection, helper protocol and code-signing requirements |
| System readers | 5 | CPU tick deltas incl. 32-bit wrap, live readers, battery parsing (health 94 % = System Settings), `top` parsing |
| Clipboard store | 8 | dedupe → top, search/filter/pinning, limits keep pinned, image cap, persistence with blobs, blob deletion, link detection, titles |
| Window layout + fuzzy matching | 7 | halves/thirds/quarters/maximize/center/height, gaps, moving between displays, Cocoa→AX flip, "left half"/"lh"/"max" matching |
| Shortcuts | 5 | symbol order, Carbon modifiers, grave key, validity, Codable |
| Shortcut recording | 5 | Esc cancels, Delete removes, bare keys need a modifier (F-keys allowed), conflicts refused, defaults record |

Defects caught by these tests and fixed: "Center" grew windows by 1 pt (`integral` on a half-point origin); a test-helper name clash between suites.

## Live on-device tests

Run against the release build launched from `build/`, driven with real HID events (`scripts/drive.swift`) and checked with `screencapture`, `CGWindowList`, `CGGetEventTapList`, `pluginkit` and the clipboard.

| Area | Test | Result |
|---|---|---|
| Archives | `tutto://` extract-here for project.zip / .7z / .tar.gz, a real RAR4 (Minecraft structure pack), readme.txt.gz, single.tar.xz | ✅ all extracted; zip/7z/tar.gz byte-identical (SHA-256), Finder-style "Project 2/3", RAR's 3 loose files got a "library" folder (smart rule), .gz → readme.txt, dates preserved |
| Archives | Compress a folder via the Finder action | ✅ Project.zip created; round trip byte-identical |
| Archives | **Finder right-click** on a .rar → menu shows Extract Here / Extract to "library" / Extract to… → click Extract Here | ✅ folder created with all 3 files |
| Archives | Module off → Finder extension disabled | ✅ `pluginkit` shows `-` (bug found: stayed `+` if Archives was off at launch; fixed) |
| Clipboard | Text, link, image, file captured; repeat moves to top (count 2) | ✅ |
| Clipboard | Item marked `org.nspasteboard.ConcealedType` (password managers) | ✅ not recorded |
| Screenshots | ⌘⇧1 → full display on clipboard | ✅ 3024 × 1964 PNG, toast shown (found 23 MB eager TIFF; now lazy) |
| Screenshots | Shared shortcut, with another app registered for the same keys | ⚠️ macOS delivers ⌘⇧1 to **both** apps (the other app opened its own capture UI too). Tutto does not name or detect other apps; the Shortcuts page has a general tip to change the shortcut in Tutto or in the other app |
| Menu bar | Panel opens (via the status item's Accessibility press — the icon was behind the notch) | ✅ after two fixes: first layout too short (trackpad collapsed to 0 pt) and 15.5 % CPU while open |
| Menu bar | Sampling stops when closed | ✅ `top` 1 → 0 processes; CPU back to 0.03 % |
| Main window | Opens on reopen (as from Spotlight/Finder); sidebar, overview, pages render | ✅ |
| Modules | Trackpad Corner switch off/on from Overview | ✅ event tap 1 → 0 → 1, setting persisted |
| Screenshots | Area → clipboard via (test) shortcut, mouse selection | ✅ 800 × 600 PNG; overlay 60–121 ms after the shortcut; mouse-up → clipboard ≤ 72 ms; TIFF generated only when an app asks |
| Screenshots | Overlay visuals (redesigned on request: no magnifier, no full-screen lines) | ✅ crosshair pointer; "1400 / 840" just below-right of it at (700, 420) pt; flips left/up near the screen edge ("2980 / 1920" at the bottom-right corner); white 12 pt numbers with a thin black outline and soft halo, photographed readable over pure white ("458 / 678") and over white text on dark ("1238 / 618"); a first, thicker outline filled in the digits' openings and was thinned; no dashed outline around the hovered window (only the dimming cutout); Esc closes the overlay |
| Screenshots | Area → editor; editor keyboard: Tab, T, Esc | ✅ Tab copied `#222222` under the pointer; T copied the recognized text; Esc copied the 1280 × 190 image and closed. Bug found: Finder stayed frontmost so keys went to Finder → editor is now a key-capable panel |
| Screenshots | OCR via the Text button | ✅ "Talk. It types." + two following lines exactly, in order, em dash preserved |
| Screenshots | Draw tool | ✅ stroke rendered; toolbar switches to colors + thickness |
| Screenshots | Selection → Crop button → Copy → Save | ✅ 402 × 202 px crop (same as the live size pill), PNG saved with Finder-style name in the chosen folder |
| Screenshots | Editor layout | Bugs found and fixed: toolbar squeezed text buttons to zero width on small captures; window placed half off-screen (SwiftUI resizing the window) |
| Windows | ⌃⌥⌘B palette → "left half" / "rh" / "center" / "restore" on a Finder window | ✅ (0, 33, 756 × 858) and (756, 33, 756 × 858) exactly; centered; restored. Bugs found and fixed: search field didn't get focus in the non-activating panel; a resting pointer selected rows on open |
| Archives | Open an archive with Tutto (`open -a Tutto x.zip`, what double-click does once Tutto is default) | ✅ extracted next to it |
| Archives | 3 GB archive | ✅ progress panel appeared (name, track, "40% · Huge/huge.bin", ×); Cancel left nothing behind. Bugs found and fixed: × wasn't reachable by VoiceOver; empty panel appeared after a password prompt |
| Archives | Password-protected zip | ✅ prompt appears (now a focus-taking panel; the first version, an alert, could leave typing going to the previous app). Decryption itself covered by unit tests (ZipCrypto, AES) |
| Clipboard | ⌃⇧V-style palette (test shortcut) → type "paste test" → ↩ with TextEdit in front | ✅ "tutto paste test 123" (the older of two clips) pasted into TextEdit, read back via Accessibility; footer showed "Paste to TextEdit" |
| Clipboard | Double-click an item in the palette (real HID double-click) with TextEdit in front; clipboard held "ORIGINAL-CLIP" | ✅ "tutto paste target 42" pasted into TextEdit, palette closed, clipboard back to "ORIGINAL-CLIP" (restored 0.6 s after ⌘V; not recorded as a new copy). With "Keep pasted items on the clipboard" on: pasted, and the item stayed on the clipboard |
| Windows | Per-action shortcuts: Left Half on ⌃⌥⌘L, Maximize on ⌃⌥⌘M | ✅ (0, 33, 756 × 858) then (0, 33, 1512 × 858) |
| Trackpad Corner | Physical press in the bottom-right corner with every module on (diagnostics log) | ✅ `decided=click result=right` for the touch at (0.740, 0.183), inside the saved 44 × 19 mm zone; ordinary clicks elsewhere stayed left clicks |
| Shortcuts | Recorder in the running app: press "Open Tutto" recorder (Accessibility), then real key events into Tutto (`drive keyto`) | ✅ ⌃⌥⌘J recorded (stored `{"app.open":{"modifiers":11,"keyCode":38}}`, VoiceOver value "Control Option Command J"); the same keys on another action → "Already used by “Open Tutto”", nothing stored; bare J → "Add ⌘, ⌃ or ⌥"; Esc → unchanged; Delete → removed (`null`); Restore Defaults → five defaults back, custom list empty |
| Fans | Helper installed and approved by the user, then Sensors & Fans › Max, then quit Tutto (fan read straight from the SMC by a separate read-only tool) | ✅ mode 0 → 1, target 6550; actual 0 → 5,787 → 6,461 → 6,553 rpm in 10 s; after quit: mode 0, target 0, fan stopped. Custom speed and the sleep/crash resets not exercised live |
| Accessibility | `scripts/ax-audit.swift` over all 16 main-window pages and the menu bar panel | ✅ 0 unlabeled interactive elements (2 found and fixed: encoding picker, archive Cancel) |
| Accessibility | Editor controls in the AX tree | ✅ Select, Draw, Highlight, Arrow, Rectangle, Pixelate, Text, Undo, Redo, Save, Copy all labeled |
| First run | Installed app, clean settings, launched through LaunchServices (`open -a`, as Spotlight does) while Claude was full screen | ✅ after two fixes. Bugs found: (1) the welcome window opened on another Space, so first launch looked like nothing happened; (2) after the first fix it opened over the full-screen app, but activating Tutto made macOS switch to the desktop and the window stayed behind (caught by checking again 2 s later, not just at 400 ms). Windows now follow the Space switch: 2 s after launch the welcome window is on screen, centered (it also sat half a window right of center; fixed). All four steps checked with the real buttons and live permission states (Accessibility "Allow" since the installed copy had no grant yet; Screen Recording and Finder extension "Allowed"); the five default keys; Try It showing the Accessibility card. Closing it with the close button: first run marked complete, no login item added ("Open at login" Off), Tutto back to menu-bar-only, previous app frontmost again |
| Spaces | ⌘-Tab back to Tutto from a full-screen app (real ⌘ key-down + Tab), window opened either over the full-screen app or on the desktop; Space of every window read from the window server | ✅ after a fix. Bug (reported): macOS switched to the desktop but the window stayed on, or jumped to, the full-screen Space, so Tutto came forward with no window. Cause: `.moveToActiveSpace` / `.fullScreenAuxiliary` on the main and welcome windows. They are now ordinary windows, and any Space switch on activation brings Tutto's front window along. In all four paths the window is on screen after ⌘-Tab; first launch over a full-screen app still shows the welcome window |
| Spotlight | `mdfind` for Tutto after `scripts/build.sh --install` | ✅ after a fix. Bug found: Spotlight also listed the build folder's copy, so typing "Tutto" could open the uninstalled one. Builds now go to `build/Products.noindex`; Spotlight lists only `/Applications/Tutto.app` |
| Performance | See [PERFORMANCE.md](PERFORMANCE.md) | ✅ all idle budgets |

## Not yet verified on device (and why)

| Item | Status |
|---|---|
| Installed app's own Accessibility grant; Open at login via Done | Granting Accessibility to the installed copy is the user's switch in System Settings (the test copy ran under an approved process). Done wasn't pressed so no login item was added to this Mac. |
