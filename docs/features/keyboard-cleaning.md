# Keyboard cleaning

Locks the keys and trackpad clicks for 15, 30 or 60 seconds so you can wipe them, then gives everything back by itself. A calm dark screen on every display counts down. Nothing you type can end it early.

## Where it lives

- Settings › General › Keyboard: one row, "Clean the keyboard", with a 15 / 30 / 60 s choice (saved, 30 s by default) and a Start button.
- The menu bar panel's ⋯ menu: "Clean the Keyboard…".
- `tutto://do/clean-keyboard`, and a shortcut you can record on the Shortcuts page (none by default).

## How it works

`KeyboardCleaner.start()` creates a session event tap on its own thread (`KeyboardCleanTap`) and one borderless overlay window per display. The tap swallows key down and up, modifier changes, system-defined events (media, volume and brightness keys), left, right and other mouse buttons (down, up, dragged), scroll wheel and the trackpad gesture events. The pointer can still move. If macOS switches the tap off, it is switched straight back on. A 0.25 s timer exists only during the run and ends it from a monotonic deadline; then the tap is removed and the windows closed. Calling start while running does nothing. Which events are blocked, the lengths and the countdown text live in `KeyboardCleanLock` (TuttoKit, tested).

If the tap can't be created (Accessibility is off), nothing locks: a toast says so and macOS's Accessibility request opens.

## Limits

- The power button and Touch ID are handled below the event tap and still work.
- The pointer can still move; only clicks, scrolls and gestures are blocked.
- Nothing can end the lock early by design. If the app is force-quit, the tap goes with it.

## Live test steps (for Bryan's assistant; this locks the real keyboard, so do it deliberately)

1. Grant Accessibility. Open TextEdit with a blank document in front.
2. Set the length to 15 s and press Start on the General page.
3. During the lock: type letters, press ⌘Q, press volume and brightness keys, click, right-click and scroll. Nothing should arrive in TextEdit, the volume must not change, and the overlay should stay on every display, counting from 0:15 down to 0:00.
4. While it runs, from another shell, list event taps with a small Swift snippet calling `CGGetEventTapList`: one active tap owned by Tutto should appear.
5. At 0:00 the overlay disappears on its own. Type "ok" and click in TextEdit: both work. `CGGetEventTapList` no longer lists the Tutto tap.
6. Pass: nothing arrives during the lock, everything works within about a second after it, and no tap or overlay window remains. Also press Start twice quickly (the second is ignored), and try with Accessibility off (a toast, no lock).
7. Idle check: with no run active, Tutto's CPU stays at its usual idle level (no timer or tap).
