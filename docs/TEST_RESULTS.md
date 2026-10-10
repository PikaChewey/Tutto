# Test results

Machine: MacBook Pro 14" (Apple M5), macOS 26.5.2, Xcode 26.6 / Swift 6.3.3. Date: 2026-10-10.

## Automated (`swift test`)

**189 tests, 0 failures** (141 XCTest + 48 Swift Testing).

| Suite | Tests | Covers |
|---|---|---|
| CornerClick engine (ported verbatim from CornerClick) | 48 | zone geometry, physical clicks, taps with Tap-to-click on/off, multi-finger rejection, re-click rule, menus, real CGEvents through the tap handler |
| Archives | 68 | zip (store/deflate, ZipCrypto, AES-128/256, splits), 7z (LZMA/LZMA2/PPMd/bzip2, splits), RAR4 + RAR5 stored and multi-volume (hand-built fixtures), tar/pax/ustar with gz/bz2/xz/lzma/lz/Z, cpio, ISO, xar, ar, WARC, CAB, LHA; legacy filename encodings (Shift-JIS incl. 0x5C trail bytes, GBK, Big5, CP949, CP866, CP1251, CP437, Mac Roman…); folder rules; unique naming; path traversal / absolute paths / symlink escapes contained; cancellation cleanup; passwords; refusal of encrypted RAR/7z and zstd/lz4; compress→extract round trips |
| Sensors & fans | 47 | IOHID + SMC readings plausible, junk filtering, grouping/labels, fan reading (1 fan, 2317–6550 rpm here), command clamping, SMC float encoding, mode-key detection, helper protocol and code-signing requirements |
| System readers | 5 | CPU tick deltas incl. 32-bit wrap, live readers, battery parsing (health 94 % = System Settings), `top` parsing |
| Clipboard store | 8 | dedupe → top, search/filter/pinning, limits keep pinned, image cap, persistence with blobs, blob deletion, link detection, titles |
| Window layout + fuzzy matching | 7 | halves/thirds/quarters/maximize/center/height, gaps, moving between displays, Cocoa→AX flip, "left half"/"lh"/"max" matching |
| Shortcuts | 5 | symbol order, Carbon modifiers, grave key, validity, Codable |

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
| Performance | See [PERFORMANCE.md](PERFORMANCE.md) | ✅ all idle budgets |

## Not yet verified on device (and why)

| Item | Status |
|---|---|
| Area selection overlay, editor (draw, crop, OCR, Tab color, Esc), window palette, clipboard palette paste, shortcut recorder | Blocked while macOS's screen-capture consent prompt for Tutto was waiting for the user: synthetic Return/Esc could have answered a security prompt. Rendering verified offscreen; logic unit-tested where possible. |
| CornerClick corner press inside Tutto | Needs a physical trackpad press. The engine is CornerClick's (48 tests, real CGEvents); the module's event tap is verified installed. |
| Fan speed changes | Needs the user to approve the root helper (App Background Activity). Non-root SMC writes verified to be refused (0xe00002c1); helper code-signing checks verified. |
| Installed app in /Applications: Spotlight launch, login item, its own TCC grants | Needs installation + user approval of the TCC prompts. |
