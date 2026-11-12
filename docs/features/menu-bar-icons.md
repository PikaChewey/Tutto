# Menu Bar Icons

Tuck away the menu bar icons you rarely use. Hold ⌘ and drag an icon to the left of Tutto's small divider, and one click on the divider hides everything left of it; another click brings it all back. On a Mac with a camera notch, that frees the room macOS needs to keep your icons in sight. It is off until you turn it on.

## Where it lives

- Menu bar: one extra item, a thin line with a small chevron, just left of Tutto's own icon. Chevron pointing left: icons are hidden, click to show. Chevron pointing right: icons are showing, click to tuck them away.
- App: Menu Bar Icons page (sidebar, last of the tools). A small drawing of the menu bar (icons, divider, Tutto's icon), the Show or Hide button, "Hide again after" (5 s, 10 s, 30 s or Never; 10 s to start) and the shortcut (none set to start).
- Also: the shortcut, and `open -g tutto://do/menu-bar-icons`.
- Nothing is added to the menu bar panel.

## How it works

macOS lays menu bar items out from the right. Making one item 10,000 pt long pushes every item to its left off the screen, and making it 24 pt again lets them back. That is all the divider does: nothing is quit, moved or restarted, and the icons are only out of sight. Which icons are tucked is your choice, made by ⌘-dragging them across the divider (a macOS feature).

- Turning the module on adds the divider, waits for the menu bar to lay it out (under half a second), then collapses it. If it finds Tutto's own icon on the wrong side, it stays open and the page says so.
- Auto-hide is one one-shot timer that exists only while icons are showing. When it fires, the icons hide unless the pointer is in the menu bar; then it looks again two seconds later. "Never" runs no timer.
- The divider's place is saved by macOS under the name `tutto.divider`. The first time, Tutto writes `NSStatusItem Preferred Position tutto.divider` in its own defaults (Tutto's icon's saved position plus 34) so it starts next to Tutto's icon. After that it never touches that key, except for "Put Divider Back".
- Turning the module off or quitting Tutto removes the divider. Every icon is visible again.
- Idle cost: one status item, no polling, no timers while hidden.

## Limits

- It can only tuck away icons macOS lets you move (almost all of them). Items drawn by macOS itself that can't be reordered stay where they are.
- Tutto's own icon is never tucked: collapsing is refused while Tutto's icon is left of the divider.
- If the chevron is not at the right end of the divider while it is hidden, the shortcut, the page's Show button and the URL still bring the icons back.

## Live tests

For Bryan's assistant, later. These change the menu bar, so run them with Bryan's say-so, on a build from this branch. Note the starting arrangement first.

1. **Turn it on.** Open the Menu Bar Icons page, switch it on. Pass: within about a second a small `|>` or `|<` item appears just left of Tutto's icon; the icons you had left of it are unchanged at first; no icon right of Tutto's icon moves.
2. **Nothing tucked yet.** With nothing left of the divider, the divider collapses and the only visible change is the chevron pointing left. Pass: the chevron is visible at the right end of the collapsed divider, next to Tutto's icon (not missing). Fail: no chevron anywhere; use the shortcut to recover and report it.
3. **Tuck two icons.** Show the divider (click it). Hold ⌘ and drag two icons you rarely use to the left of it. Pass: they stay where dropped. Click the divider: both disappear, every icon right of the divider stays, Tutto's icon stays, and the chevron flips.
4. **Show again.** Click the divider. Pass: both icons are back in the same order, and the chevron flips.
5. **Auto-hide.** Show the icons, move the pointer off the menu bar, count. Pass: they hide on their own after the chosen delay, within 1 s (check 5 s, 10 s and 30 s). Set it to Never: they stay showing for a minute. Show them and leave the pointer in the menu bar for twice the delay: they stay; move it away and they hide within 2 s of the delay having passed.
6. **Shortcut.** Record a shortcut on the page. Pass: it shows and hides the icons; `open -g tutto://do/menu-bar-icons` does the same.
7. **Wrong side.** Show the icons and ⌘-drag Tutto's own icon to the left of the divider. Click the divider. Pass: it does not collapse, a short message says why, the page shows "Tutto's own icon is left of the divider", and Put Divider Back returns the divider to the left of Tutto's icon (collapse works again).
8. **Notch note.** On a Mac whose bar is full, with Tutto's icon behind the notch, the page shows the notch note; after tucking icons it goes away on Check Again.
9. **Off and quit.** Turn the module off: the divider disappears and every icon is visible. Turn it on, tuck icons, quit Tutto from its menu: every icon is visible after the quit. Relaunch: the divider returns to the same place.
10. **Cost.** With icons hidden, sample Tutto for 30 s (`sample` or Activity Monitor): no wakeups from this feature.

Measure for each: what is on screen (a screenshot of the right half of the menu bar before and after), and Tutto's CPU while idle.
