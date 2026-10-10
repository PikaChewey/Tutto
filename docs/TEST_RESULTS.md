# Test results

Machine: MacBook Pro 14" (Apple M5), macOS 26.5.2, Xcode 26.6 / Swift 6.3.3. Date: 2026-10-10.

## Automated (`swift test`)

**194 tests, 0 failures** (146 XCTest + 48 Swift Testing).

| Suite | Tests | Covers |
|---|---|---|
| CornerClick engine (ported verbatim from CornerClick) | 48 | zone geometry, physical clicks, taps with Tap-to-click on/off, multi-finger rejection, re-click rule, menus, real CGEvents through the tap handler |
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
| Screenshots | Shared shortcut with Shottr running | ⚠️ macOS delivers ⌘⇧1 to **both** apps (Shottr opened its editor too). Tutto now warns per shortcut and in the panel; quit Shottr when switching |
| Menu bar | Panel opens (via the status item's Accessibility press — the icon was behind the notch) | ✅ after two fixes: first layout too short (trackpad collapsed to 0 pt) and 15.5 % CPU while open |
| Menu bar | Sampling stops when closed | ✅ `top` 1 → 0 processes; CPU back to 0.03 % |
| Main window | Opens on reopen (as from Spotlight/Finder); sidebar, overview, pages render | ✅ |
| Modules | CornerClick switch off/on from Overview | ✅ event tap 1 → 0 → 1, setting persisted |
| Screenshots | Area → clipboard via (test) shortcut, mouse selection | ✅ 800 × 600 PNG; overlay 60–121 ms after the shortcut; mouse-up → clipboard ≤ 72 ms; TIFF generated only when an app asks |
| Screenshots | Overlay visuals | ✅ hairline crosshair, loupe with pixel grid + center outline + hex, live size pill; right-click cancels |
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
| Windows | Per-action shortcuts: Left Half on ⌃⌥⌘L, Maximize on ⌃⌥⌘M | ✅ (0, 33, 756 × 858) then (0, 33, 1512 × 858) |
| Accessibility | Editor controls in the AX tree | ✅ Select, Draw, Highlight, Arrow, Rectangle, Pixelate, Text, Undo, Redo, Save, Copy all labeled |
| Performance | See [PERFORMANCE.md](PERFORMANCE.md) | ✅ all idle budgets |

## Not yet verified on device (and why)

| Item | Status |
|---|---|
| Shortcut recorder UI (clicking a recorder and pressing keys) | Custom shortcuts saved in settings were verified to register and fire; driving the recorder itself was deferred while the user was active. |
| CornerClick corner press inside Tutto | Needs a physical trackpad press. The engine is CornerClick's (48 tests, real CGEvents); the module's event tap is verified installed. |
| Fan speed changes | Needs the user to approve the root helper (App Background Activity). Non-root SMC writes verified to be refused (0xe00002c1); helper code-signing checks verified. |
| Installed app in /Applications: Spotlight launch, login item, its own TCC grants | Needs installation + user approval of the TCC prompts. |
