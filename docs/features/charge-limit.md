# Charge limit

**What it does.** For a MacBook that's plugged in most of the time: Tutto stops charging at a level you choose (80 % unless you pick another, anywhere from 50 to 100 % in steps of 5) and the Mac runs on the adapter while the battery just sits. Charging starts again once the charge falls 5 % below the limit. "Charge to 100 %" lifts the limit once, for a day away from the desk, and the limit comes back by itself when the battery is full or you unplug. It's off until you turn it on.

## Where it lives

- **Battery page** (the app), a "Charge limit" group between Health/Power and "Using energy now":
  - "Stop charging at a set level" with a switch. Its line says what it does while off, and what it's doing while on: "Holding at 80 %, running on the adapter", "Charging to 80 %", "On battery. Charging stops at 80 % when plugged in.", or what went wrong.
  - While on: "Stop at" with a small slider (50–100 %, steps of 5) and the value, then "Full charge once" with a "Charge to 100 %" button (it becomes "Cancel" while it's charging up).
  - If Tutto's helper isn't set up: one more row, "Needs Tutto's helper" / "Approve Tutto's helper", with Set Up / Approve: the same helper and approval fans and Stay Awake use.
  - Under the group, while on: a short note that macOS's Optimized Battery Charging may also hold the charge.
- **Menu bar panel**: only inside the battery card, one dim line under health while the charge is held ("Held at 80 %"), or "Charging to 100 % once". Nothing else in the panel; no new tile.

## How it works

- **Keys.** Only root can stop charging: it's an SMC write. TuttoHelper does it, choosing by what the SMC actually has (read, never assumed):
  - `CHTE`, `ui32`, 4 bytes: newer Apple silicon firmware. `01 00 00 00` = don't charge, `00 00 00 00` = charge. **This Mac (M5, Mac17,2, macOS 26.5.2) has it**, read as `00 00 00 00` (charging allowed); `CH0B`/`CH0C` are absent here.
  - `CH0B` and `CH0C`, one byte each: older firmware. `02` = don't charge, `00` = charge (CH0C is written where it exists).
  - `CHTE` wins where both exist. The adapter stays on (the discharge keys `CHIE`/`CH0I`/`CH0J` are never touched), so the charge holds rather than drops.
  - Mechanics learned from the MIT-licensed open-source `battery` command-line tool; no code copied.
- **Lease.** The helper holds charging off only under a 90 s lease that the app renews every 60 s (`ChargeLease`). If the app stops renewing (hung), the helper allows charging by itself. It also allows charging when the last app connection ends (crash, quit), on SIGTERM, and at its next start if a journal (`/Library/Application Support/Tutto/charge.json`) says a killed helper was holding it. The lease runs on the monotonic clock, which stops during sleep, so it doesn't run out while the Mac sleeps. Every write is read back; a value the SMC didn't keep is an error and charging stays on. The helper only undoes its own hold: if something else stopped charging, Tutto leaves it.
- **Rules** (`ChargeLimitRules.decide`, TuttoKit, tested): unplugged → hold nothing and end "once"; "once" → charge until 100 %, then it clears; limit 100 → never hold; charge ≥ limit → hold; charge < limit − 5 → charge; in between → keep doing what it was doing.
- **Events, not polling.** While on, the controller listens to power-source changes (`IOPSNotificationCreateRunLoopSource`: plug, unplug, each percent), wake, and app activation (after approving the helper). The only timer is the lease renewal, and it runs only while charging is held off. Off: no source, no observer, no timer, no helper connection. The helper connection is open only while charging is held, so the helper still exits when idle.
- **Sleep.** Before sleep, if the charge is below the limit, charging is allowed (nothing can watch it while the Mac sleeps); at or above, the hold stays.
- **Off, quit.** Turning it off, or quitting Tutto, allows charging at once (on quit it waits up to 2 s for the helper; closing the connection makes the helper allow it anyway).
- Settings: `battery.chargeLimit.enabled`, `battery.chargeLimit.level`, `battery.chargeLimit.topUp` in UserDefaults.
- Helper protocol 1.2.0: `setChargingInhibited(_:lease:reply:)` and `chargingState(reply:)`.

## Limits

- The Mac charges as usual until Tutto's helper is set up and approved.
- A Mac that sleeps below the limit while plugged in can charge past it during sleep; the limit takes hold again when it wakes (it holds the charge where it is, it doesn't drain it back down).
- Above the limit (turned on at 95 %), it holds at 95 %; it doesn't discharge to the limit.
- An older helper still running from before an update doesn't know the new calls; the section says it couldn't reach the helper and the Mac keeps charging. It's fine after the old helper exits (about 15 s idle) or a restart.
- Macs whose SMC has neither key: the switch is greyed and says "This Mac doesn't let apps stop charging."
- Permissions' description of the helper still mentions fans and Stay Awake only (that file belongs to another hook).

## Live test steps (for Bryan's assistant, on a MacBook, plugged in, with the helper approved)

Baseline, read only:
1. `ioreg -rn AppleSmartBattery | grep -E '"(CurrentCapacity|IsCharging|ExternalConnected|InstantAmperage)"'` and note the charge (C %).
2. Read the key: `build/Products.noindex/Tutto.app/Contents/MacOS/TuttoHelper --self-test` as a normal user prints `charging control: CHTE = 00000000 (allowed)` on this Mac (its only writes are the existing fan probe's, which root alone could perform, so they're refused). Any read-only SMC reader works too (`TSMCRead` from CBridges, as used to check this Mac on 2026-11-11).

Holding:
3. Install the build (`scripts/build.sh --install`), open Battery, turn on "Stop charging at a set level", and set "Stop at" to the step just below C (C = 83 → 80). Plugged in, with the battery below C needing charge.
4. Within ~2 s: the status says "Holding at C %, running on the adapter"; the panel's battery card shows "Held at C %".
5. `ioreg …` shows `IsCharging = No`, `ExternalConnected = Yes`, and `InstantAmperage` about 0 (|I| < 0.1 A, i.e. ≤ 100 mA either way) within ~30 s. `log show --last 2m --predicate 'subsystem == "ca.bryanyao.Tutto.helper"'` shows `setChargingInhibited true lease 90.0: success`. Reading `CHTE` gives `01000000`.
6. Leave it 3 minutes: the log shows a renewal each minute (`setChargingInhibited true` again), and charging stays off. **Pass:** charge doesn't rise, amperage stays ~0.

Safety:
7. Kill the app (`kill -9` on Tutto) while holding. **Pass:** within a few seconds the helper log says `last client gone: charging allowed`, `IsCharging = Yes` (if below 100 %) and `CHTE` reads `00000000`.
8. Relaunch, turn the limit on again so it holds, then `kill -STOP` Tutto (hung, connection alive). **Pass:** within 90–120 s the log says `lease ran out … charging allowed` and charging resumes. `kill -CONT` afterwards: the next power event or renewal holds it again.
9. Turn the switch off. **Pass:** `IsCharging = Yes` and positive `InstantAmperage` within ~30 s, `CHTE = 00000000`, the panel line is gone, and ~15 s later the `TuttoHelper` process has exited (`pgrep TuttoHelper` empty, unless fans or Stay Awake hold it).
10. "Charge to 100 %" while holding: status "Charging to 100 % once, then back to 80 %", charging resumes; unplug: the button goes back to "Charge to 100 %".
11. Quit Tutto normally while holding. **Pass:** charging resumes at once.
12. Idle cost with the limit on and unplugged: `sample Tutto 5` shows no charge-limit timer; Tutto's CPU stays at its usual idle.
