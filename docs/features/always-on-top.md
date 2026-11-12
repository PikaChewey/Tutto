# Keep on top

**What it does.** Keep a video, your notes or a terminal above every other window. Press the keys (or pick **Keep on Top** in the window palette) and the front window stays on top while you work in other apps; press them again and it's back to normal. Click the window while it floats and you're straight back in it. Up to three windows at once.

## Where it lives

- **Windows page › Keep on top:** the shortcut (none by default; record one), and, only while something is pinned, the pinned windows with an **Unpin** button each.
- **Window palette (⌃⇧B):** a **Keep on Top** row (or **Stop Keeping on Top** for a window that's already pinned). It comes last when nothing is typed, so the list you know doesn't move; type "pin", "top", "float" or "on top" to find it.
- **Link:** `tutto://do/pin-window` toggles the front window.
- Toasts: "Kept on top" when pinned, "Back to normal" when unpinned with the keys or the palette.
- Nothing new in the menu bar panel.

## How it works

macOS has no public way to change another app's window level, so Tutto doesn't move the window at all. It puts a **live copy** on top:

- A borderless, non-activating panel at the floating level (on every Space, beside full-screen apps, left out of ⌘Tab and window cycling) sits exactly over the real window. It's filled by a ScreenCaptureKit stream of that one window (`SCContentFilter(desktopIndependentWindow:)`, so whatever is covering the real window doesn't show), at the window's own pixel size, up to 30 frames a second, no pointer, no shadow in the capture. Frames go to the layer as IOSurfaces, with no copy. A small pin badge sits in its top right corner.
- **When it shows** (`PinRules.showsCopy` in TuttoKit, tested): while the window is on screen and you're somewhere else, meaning another app or another window of the same app. It hides while you're in the window itself, and while the window isn't on screen (minimized, its app hidden, on another Space). If the pinned app is in front and its focused window can't be read, it stays hidden, so a copy never sits over the window you're typing in.
- **Clicking the copy** hides it, raises the real window (`AXRaise`, made main) and brings its app forward.
- **Following the window:** an Accessibility observer per app (moved, resized, minimized, restored, closed, retitled, focus changed) and workspace notices (app switched, hidden, shown, quit; Space changed; displays changed) trigger the same check. The window server's frame places the copy; a resize updates the stream's size. A window that closes, or whose app quits, is unpinned quietly.
- **Cost:** with nothing pinned, nothing at all (no observers, no notices). While pinned, the capture runs only while the copy is on screen; hidden, the stream is stopped and the last frame released. No timers or polling; the only delayed calls are single one-off checks after an animation (0.4–0.85 s).
- **Permissions:** Accessibility (to find the front window and raise it) and Screen Recording (for the copy). Without Screen Recording, Tutto asks the same way screen recording does and shows "Screen Recording needed".

Code: `Sources/Tutto/Modules/Windows/WindowPins.swift` (pins, observers, the show/hide pass), `WindowPinMirror.swift` (panel, stream, badge), `Sources/TuttoKit/Windows/PinRules.swift` (rules), `Tests/TuttoKitTests/PinRulesTests.swift`. Snapshots: `Tutto --snapshot DIR windows windows-pinned tall` and `window-palette-top`.

## Limits

- It's a copy: while it floats, scrolling or typing over it does nothing; click it first. Hover effects in the real window don't show.
- Some apps slow down or stop drawing windows they think are hidden (some video players and browsers save power this way), so the copy can freeze or play at a lower rate.
- A copy appears a moment (one stream start, about 50–150 ms) after you switch away, so the real window can blink behind the new front window first.
- Popovers, sheets and menus that are separate windows of the pinned app don't show in the copy.
- Tutto's own screen recordings leave out Tutto's floating windows, so a recording shows the real (covered) window, not the copy.
- Windows in native full screen, Tutto's own windows and panels or menus can't be pinned (a toast says so). Pins don't survive quitting Tutto or switching off the Windows tool.
- Other apps' floating panels at the same level may sit above or below the copy.

## Live test (for Bryan's assistant; needs Accessibility and Screen Recording for Tutto)

Setup: install the build, record a shortcut for **Keep the front window on top** on the Windows page (say ⌃⌥P), open TextEdit with a new document and type a few lines; open a Finder window that overlaps it.

1. **Pin.** Click into TextEdit, press ⌃⌥P. Pass: toast "Kept on top · TextEdit stays above other windows"; the Windows page lists "TextEdit — Untitled" with Unpin. Nothing visible changes yet (you're in the window).
2. **Copy over the real window.** Click the Finder window so it comes in front, overlapping TextEdit. Pass: TextEdit stays visible above Finder within about 0.2 s, with the pin badge top right. Take a screenshot (⌘⇧3) and compare the copy's edges with the window's frame from `osascript -e 'tell application "System Events" to get {position, size} of window 1 of process "TextEdit"'`: they must match to within 1 pt on every side, and the text must be sharp (no scaling blur).
3. **It updates.** With Finder in front, make TextEdit change on its own: `osascript -e 'tell application "TextEdit" to set text of document 1 to (text of document 1) & "added line"'`. Pass: the new line appears in the copy within a second.
4. **Click it.** Click the copy. Pass: the copy disappears, TextEdit comes in front and has keyboard focus (typing goes into it), and the copy doesn't flash back.
5. **Same app, other window.** With the pinned TextEdit window, open a second TextEdit document overlapping it and click into the second. Pass: the copy of the first shows above the second.
6. **Off screen.** Minimize the pinned window (⌘M), then switch to another Space. Pass: no copy anywhere; restoring it from the Dock shows it normally (you're in it, so no copy).
7. **Move.** With Finder in front, move the pinned window with the palette (⌃⇧B, "left half" while TextEdit is in front, then click Finder). Pass: the copy follows to the new place and size.
8. **CPU while copied.** With Finder in front and the copy showing, run `top -l 6 -s 2 -stats pid,command,cpu -pid $(pgrep -x Tutto)` while TextEdit is idle, and again while a video plays in a pinned QuickTime window. Pass: Tutto under about 3 % CPU with a still window and under about 12 % with a playing 1080p video (also note WindowServer's CPU). Then click into the pinned window (copy hidden) and measure again. Pass: Tutto back to about 0 %, and `log stream --predicate 'subsystem == "ca.bryanyao.Tutto" AND category == "pins"'` shows no errors.
9. **Limit.** Pin three windows, try a fourth. Pass: toast "Three windows are on top already".
10. **Unpin.** Press ⌃⌥P in a pinned window. Pass: toast "Back to normal", the row disappears from the Windows page. Use **Unpin** on the page for another: the copy disappears at once.
11. **Close.** With a window pinned, close it (⌘W). Pass: it's no longer listed and no copy remains.
12. **Idle cost.** With nothing pinned, Tutto's CPU stays at 0 % and memory returns to where it was before pinning (within a few MB) within a minute.
13. **Palette.** ⌃⇧B, type "pin", ↩ in an unpinned window: pinned. Open it again in that window: the row reads "Stop Keeping on Top".
