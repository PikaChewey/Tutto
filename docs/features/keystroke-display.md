# Show keys you press (screen recording)

Shows the keys you press as keycaps near the bottom of a screen recording, like "⌘ ⇧ 4", so a demo shows what you did. Pressing the same shortcut again and again shows "×3". It fades out about a second after the last key. Off by default.

## Where it lives

Screenshots page › Screen recording, one row, "Show keys you press", right after "Show clicks": Off / Shortcuts / Every key. Nothing changes in the menu bar panel.

- **Shortcuts:** keys pressed with ⌘, ⌃ or ⌥, plus Esc, Return, Tab, Delete, the arrows and F-keys. A held ⌘, ⌃ or ⌥ shows on its own so the cap is up before the key.
- **Every key:** the same, and plain typing shows as a short rolling string (the last 14 characters; it starts again after a pause).

## How it works

- `Sources/TuttoKit/Recording/KeystrokeRules.swift` holds the pure rules: keycap text from a key code and modifiers (⌃ ⌥ ⇧ ⌘ order, words for Return, Esc, Tab, Space, Delete), the Shortcuts filter, the repeat counter and the typing string. Tests are in `Tests/TuttoKitTests/KeystrokeTests.swift`.
- `Sources/Tutto/Modules/Screenshots/KeystrokeOverlay.swift` is a click-through panel near the bottom centre of the recorded area, fed by `NSEvent.addGlobalMonitorForEvents` (key down and modifier changes). The monitor, the panel and the fade timer exist only between the recording starting and stopping.
- Tutto's floating windows are left out of recordings. The recorder keeps this one panel's window id out of that exclusion, so the keycaps are in the video and everything else of Tutto stays out.
- Auto-repeat from a held key is ignored, so holding a key doesn't count up.

## Limits

- Needs Tutto in Privacy & Security › Accessibility. Without it the recording still runs and a toast says the keys won't show.
- While macOS Secure Input is on (a password field, some terminals' secure keyboard entry), nothing is shown. Checked on every key.
- The caps are on the screen too, so they appear in anything else capturing it.
- Keys typed into another Mac or a virtual machine that grabs the keyboard may not reach the monitor.

## Live test steps (not run yet)

1. Switch on "Show keys you press" › Shortcuts; leave "Show clicks" on. Confirm Tutto is in Accessibility.
2. Open TextEdit with a new document. Press ⌃⇧R, click the TextEdit window, wait out the countdown.
3. Press ⌘B, then ⌘B twice more quickly (should read "×2", "×3"), then type "hello", then Return and Esc, then Stop (⌃⇧R).
4. Pull frames from the MP4 at 0.5 s steps (for example `ffmpeg -i file.mp4 -vf fps=2 f%02d.png`, or QuickLook). Pass: a frame shows dark keycaps "⌘ B" near the bottom centre, a later one shows "×3", "Return" and "Esc" appear, "hello" does not. No Tutto outline, panel or toast is in any frame. Caps are readable at phone size (about 36 pt text in the video's pixels at the display's scale).
5. Repeat with Every key: "hello" shows as typing; about 1.2 s after the last key the caps are gone from the frames.
6. Secure Input: in Terminal turn on Secure Keyboard Entry (Terminal menu), record 5 s while pressing ⌘B and typing. Pass: no caps in any frame.
7. Recording with the setting Off, or Accessibility off: no caps, no errors, and Activity Monitor shows no extra CPU before and after a recording.
