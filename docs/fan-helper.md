# Fan helper (TuttoHelper)

TuttoHelper also holds sleep off for Stay Awake (helper 1.1.0; see "Stay Awake" at the end) and holds charging off for the charge limit under a lease the app renews every minute (helper 1.2.0; see [features/charge-limit.md](features/charge-limit.md)).

Fan speeds are SMC writes, and the SMC refuses writes from non-root processes with `kIOReturnNotPrivileged` (0xe00002c1). Tutto therefore ships a small root LaunchDaemon, `TuttoHelper`. The app registers it with `SMAppService` and talks to it over XPC. Reading temperatures and fans needs no helper: use `TemperatureSensors` and `Fans` in TuttoKit.

## Pieces

| File | Role |
|---|---|
| `Sources/TuttoKit/Sensors/FanHelperProtocol.swift` | `TuttoFanHelperProtocol` (`@objc(TuttoFanHelperProtocol)`) and `TuttoFanHelper` constants: Mach service, plist name, version, both code-signing requirements, idle delay. |
| `Sources/TuttoKit/Sensors/FanControlCore.swift` | `FanStatus` (IOReturn codes), `FanSMC` (keys, clamping, `flt`/`fpe2` encoding) and `FanController`, the write sequence the helper runs. |
| `Sources/TuttoKit/Sensors/SMCDevice.swift` | The real SMC, through CBridges. |
| `Sources/TuttoHelper/Shared/*.swift` | **Symlinks** to the three files above, so the helper compiles the same code without linking TuttoKit (the release build is about 200 KB and links only system libraries). Edit the originals. |
| `Sources/TuttoHelper/{main,HelperService,SelfTest}.swift` | The daemon: listener, caller check, lifetime and `--self-test`. |
| `Resources/ca.bryanyao.Tutto.helper.plist` | The launchd plist for `SMAppService.daemon(plistName:)`. |

## Bundle layout

```
Tutto.app/Contents/
  Info.plist                                    CFBundleIdentifier = ca.bryanyao.Tutto
  MacOS/Tutto
  MacOS/TuttoHelper                             ← swift build -c release --product TuttoHelper
  Library/LaunchDaemons/ca.bryanyao.Tutto.helper.plist   ← copy of Resources/ca.bryanyao.Tutto.helper.plist
```

The plist sets:
- `Label` and `MachServices` to `ca.bryanyao.Tutto.helper`.
- `BundleProgram` to `Contents/MacOS/TuttoHelper`. The path is relative to the app bundle.
- `AssociatedBundleIdentifiers` to `[ca.bryanyao.Tutto]`.

There is no `KeepAlive` and no `RunAtLoad`. launchd starts the helper when the app first messages the Mach service. The helper exits about 15 s after its last client leaves, once every fan is back on automatic.

## Signing

Sign the helper first, then any other nested code, then the app. Don't use `--deep`. Both the app and the helper need the same Apple-issued identity: each reads its team from its own signature (`TuttoFanHelper.teamIdentifier`) and accepts only the other signed by that team. Ad-hoc signing breaks `SMAppService` registration.

```sh
IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"   # security find-identity -v -p codesigning
APP=build/Products.noindex/Tutto.app

codesign --force --options runtime --timestamp=none \
  --identifier ca.bryanyao.Tutto.helper --sign "$IDENTITY" "$APP/Contents/MacOS/TuttoHelper"
# … sign the Finder extension and any other nested code here …
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"   # identifier comes from Info.plist

# Check the result:
codesign --verify --strict --verbose=2 "$APP"
codesign --verify -R='anchor apple generic and identifier "ca.bryanyao.Tutto.helper" and certificate leaf[subject.OU] = "<your team ID>"' "$APP/Contents/MacOS/TuttoHelper"
codesign --verify -R='anchor apple generic and identifier "ca.bryanyao.Tutto" and certificate leaf[subject.OU] = "<your team ID>"' "$APP"
```

- **Entitlements.** The helper needs none. It opens `AppleSMC` as root.
- **Hardened runtime.** It is on (`--options runtime`).
- **Releases.** Use Developer ID and notarization (`--timestamp`) to distribute. For local builds, an Apple Development signature on a non-quarantined app in `/Applications` is expected to work (see "Verified vs not verified").

## Registering (app side)

```swift
import ServiceManagement

let daemon = SMAppService.daemon(plistName: TuttoFanHelper.plistName)   // "ca.bryanyao.Tutto.helper.plist"
switch daemon.status {
case .notRegistered:
    do { try daemon.register() } catch { /* usually "Operation not permitted": approval needed */ }
    // Read daemon.status again. After the first register() it is normally .requiresApproval.
case .requiresApproval:
    SMAppService.openSystemSettingsLoginItems()
    // macOS 26.5: System Settings › General › Login Items & Extensions › App Background Activity
    // ("Allow in the Background" on macOS 13–15). Turning Tutto on needs an admin password.
case .enabled:
    break   // ready: connect
case .notFound:
    break   // plist missing from Contents/Library/LaunchDaemons, or the bundle is broken
@unknown default:
    break
}
```

Status mapping for FAN-4:

| Condition | Message |
|---|---|
| `.notRegistered` | Fan control is off. Offer "Enable fan control". |
| `.requiresApproval` | Needs approval in System Settings. Show a button that calls `openSystemSettingsLoginItems()`. |
| `.notFound` | The helper is missing from the app. This is a build or bundle error. |
| `Fans.count == 0` | No fans on this Mac. Hide the controls. Temperatures still work. |

Poll `daemon.status` when the app becomes active, because the user approves in System Settings. Unregister with `try await daemon.unregister()` when the user turns fan control off for good.

## Connecting (app side)

```swift
let connection = NSXPCConnection(machServiceName: TuttoFanHelper.machServiceName, options: .privileged)
connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
connection.setCodeSigningRequirement(TuttoFanHelper.helperRequirement)   // only talk to our helper (macOS 13+, call once, before resume)
connection.invalidationHandler = { /* drop the connection; the next command reconnects */ }
connection.interruptionHandler = { /* the helper exited or crashed; fans state unknown: reconnect, then resetAllFans or re-apply */ }
connection.resume()

let helper = connection.remoteObjectProxyWithErrorHandler { error in
    // Code-signing mismatch, helper not approved, and similar errors land here.
} as? TuttoFanHelperProtocol

helper?.version { version in /* if version != TuttoFanHelper.version: unregister + register, reconnect */ }

let fan = Fans.read()[0]
let (mode, rpm) = FanCommand.rpm(4500).helperArguments(for: fan)    // clamped; .auto → (0, 0), .maximum → (1, max)
helper?.setFan(fan.index, mode: mode, rpm: rpm) { status, message in
    // status is an IOReturn: FanStatus.success, .badArgument, .unsupported, .notPrivileged …; message explains failures
}
helper?.resetAllFans { status in }
```

### Rules the app must follow

1. **Keep one connection open while any fan is manual.** When the last connection closes, the helper puts every fan back on automatic. That covers quit and crash (FAN-3). It also means a short-lived connection per command undoes itself.
2. **Module off.** Call `resetAllFans` when the fan module is turned off, then invalidate the connection.
3. **Sleep.** The helper resets every fan on `kIOMessageSystemWillSleep` by itself. On `NSWorkspace.didWakeNotification`, re-read `Fans.read()` and show "Automatic". FAN-3 says sleep resets to automatic, so don't re-apply silently.
4. **Interrupted connection.** Treat fan state as unknown. Reconnect and either re-apply the user's choice or call `resetAllFans`.
5. **Display.** Show `Fans.read()` (current, min, max, target, mode) for the UI. Don't trust what you last sent.
6. **Clashes.** If another fan-control tool or its privileged helper is active, it will fight Tutto over the same keys (APP-9).

## What the helper does

**Caller check.** The helper calls `NSXPCListener.setConnectionCodeSigningRequirement`, so a non-matching peer is rejected before the delegate runs. It also calls `NSXPCConnection.setCodeSigningRequirement` on every accepted connection. The requirement is:

```
anchor apple generic and identifier "ca.bryanyao.Tutto" and certificate leaf[subject.OU] = "<your team ID>"
```

**`setFan(i, mode: 1, rpm)`, manual.** This follows the known-good write sequence for Apple silicon SMCs (from published open-source SMC research):
1. Validate the fan index against `FNum`.
2. Find the mode key: `F<i>md` (M5), falling back to `F<i>Md`.
3. Clamp `rpm` to [`F<i>Mn`, `F<i>Mx`] read from the SMC.
4. Write mode = 1.
   - If that fails and `Ftst` exists (M3/M4): write `Ftst` = 1, wait 3 s, and retry the mode write every 100 ms (up to 100 times).
   - If the write fails with `kIOReturnNotPrivileged`, the helper stops and returns that status.
5. Write `F<i>Tg` in the key's own type: a little-endian `flt` on Apple silicon, big-endian `fpe2` on Intel.
6. If writing the target fails, the fan goes back to automatic.

**`mode: 0`, automatic.** Only for a fan that is manual (set by Tutto, or SMC mode = 1):
1. Write mode = 0.
2. Write `F<i>Tg` = 0.0. This is Apple silicon only.
3. Once no fan is manual, write `Ftst` = 0 where that key exists and is set.

A fan that is already automatic gets no writes.

**When fans return to automatic:**
- The last client disconnects (quit or crash).
- SIGTERM, SIGINT or SIGHUP, after which the helper exits.
- System sleep.
- Idle exit. The helper checks again 15 s after the last client leaves. If a fan is still manual, it retries up to three times and then exits anyway, rather than fighting another fan tool.

**Serialization.** All SMC access runs on one serial queue.

## Reading sensors (no helper)

- `TemperatureSensors.read()` returns `[TemperatureReading]`, sorted by group and then by natural label. Each reading has:
  - `id`: `hid:<name>` or `smc:<key>`
  - `name`
  - `label`
  - `group`: `.cpu`, `.soc`, `.gpu`, `.battery`, `.storage`, `.ambient` or `.other`
  - `celsius`
  - `source`
  - `sampleCount`
- `readings.summary` returns a `TemperatureSummary`: CPU, GPU and SoC average and hottest, battery average, `ssd`, and `headline`.
- Call `TemperatureSensors.release()` when the page closes and after wake.
- **Junk filtering.** Readings outside −20…130 °C are dropped. IOHID services that share a name are averaged; this M5 has six "gas gauge battery" services.
- **CPU/GPU labels on the M5.**
  - Labels come from a published open-source M5 SMC key map: `Tp*` becomes "CPU n" (11 keys present) and `Tg*` becomes "GPU n" (8 keys).
  - Both were checked under load. GPU keys rose 22–26 °C under a Metal load. CPU keys rose 10–15 °C under a Super-core load and did not move under an Efficiency-only load.
  - That map names some of the M5 keys "performance core", but this M5 has no performance cores, so the labels stay neutral. Tutto makes no per-core claim.
- **IOHID labels.**
  - "PMU tdie*" is shown as "SoC die n". It responds to both CPU and GPU load.
  - "PMU2 tdie*" barely moves under either load, so it stays in `.other`.
- **Other chips.** The M1–M4 SMC tables come from published open-source SMC research and are unverified.
- `Fans.read()` returns `[FanReading]`: index, current, min, max, target, and mode (`.auto`, `.manual` or `.unknown`). Use `Fans.count` and `Fans.modeKey(for:)` for the rest.

## Debugging

```sh
.build/release/TuttoHelper --self-test     # as your user; changes nothing (see below)
.build/release/TuttoHelper --version
sfltool dumpbtm | grep -A12 ca.bryanyao.Tutto
sudo launchctl print system/ca.bryanyao.Tutto.helper
log stream --predicate 'subsystem == "ca.bryanyao.Tutto.helper"' --info
```

- `--self-test` prints the fans and keys, then runs these checks:
  - The helper's own attach/accept code accepts a client with no requirement and a client matching its own cdhash. These are control cases.
  - The same code **rejects** this process under Tutto's client requirement.
  - `resetAll` on fans that are already automatic issues no writes.
  - A non-root write of the value a key already holds returns `kIOReturnNotPrivileged`.
- Writes in the self-test go through a write-blocking SMC, except the privilege probe, which writes back the current bytes. The self-test refuses to write as root.
- Started any other way than by launchd, the helper prints usage and exits with status 64.

## Verified vs not verified (MacBook Pro 14" M5, macOS 26.5.2)

Verified:
- **Builds.** `swift build --product TuttoHelper` and the release build succeed. The release binary is about 200 KB and links only system libraries.
- **Self-test.** `--self-test` passes as uid 501:
  - XPC control cases are accepted.
  - The unsigned or ad-hoc binary is rejected by the client requirement.
  - Non-root writes to `F0md` and `F0Tg` return 0xe00002c1 and change nothing.
- **Requirement matches a real signature.** A copy of the helper signed with the Apple Development identity as `ca.bryanyao.Tutto` was **accepted**. The same copy signed as `ca.bryanyao.Tutto.helper` was **rejected**, and it satisfies `helperRequirement`.
- **Unit tests.** `swift test --filter Sensor` (47 tests) covers the write sequence against fake SMCs:
  - M5 direct
  - M3/M4 `Ftst` unlock
  - Intel `F0Md` + `fpe2`
  - non-root fail-fast
  - rollback
  - no-op reset
  - clamping
  - encoding round trips, checked against the C decoder
  - XPC round trip of the protocol
  - rejection of a non-Tutto client

Not verified (needs root, launchd and approval):
- **Writes as root.** No SMC write has ever succeeded on this Mac. It is unknown whether `F0md` = 1 followed by `F0Tg` actually drives the M5 fan, and whether thermalmonitord reclaims it.
- **Registration.** `SMAppService` registration and approval with an Apple Development-signed, non-notarized build.
- **Daemon-only paths.** These run only under launchd: idle exit, SIGTERM, and the sleep notification (`IORegisterForSystemPower`).
- **Other Macs.** The M3/M4 `Ftst` path and the Intel paths have only been tested with fakes.

First real-world test to run once the app is built and approved:
1. Set 4000 rpm and read `Fans.read()`. Expect mode `.manual`, target 4000, and actual rising.
2. Quit the app. Within about 1 s, expect mode `.auto` and target 0.
3. `sudo launchctl kill TERM system/ca.bryanyao.Tutto.helper` while manual. Expect `.auto`.
4. Sleep and wake while manual. Expect `.auto`.

## Stay Awake (helper 1.1.0)

Keeping a MacBook on with its lid closed takes `pmset -a disablesleep 1`, which needs root, so the helper does it. The shared code is `Sources/TuttoKit/Awake/AwakeCore.swift` (symlinked into `Shared/` like the fan files). `AwakeController` runs `/usr/bin/pmset` with fixed arguments only.

| Call | What the helper does |
|---|---|
| `beginAwake(until:)` | Journals the session, then `pmset -a disablesleep 1` (only if it was off: a SleepDisabled someone else turned on is left alone, now and at the end). Called again, it moves the end. The end is capped at 7 days. |
| `setAwakeLowPower(_:)` | Reads the battery profile's `lowpowermode` from `pmset -g custom`, journals it, then sets `pmset -b lowpowermode 1`; off puts back exactly what was there. The charger's profile is never touched. |
| `setAwakePaused(_:)` | The processes the app paused (pid, start time, owner). Only the caller's own processes, alive and with the same start time, are kept. |
| `endAwake(sleepIfLidClosed:)` | Resumes the paused processes (SIGCONT, after checking each is still the same process), puts Low Power Mode and sleep back, then removes the journal. With `sleepIfLidClosed`, a lid still closed a second later gets `pmset sleepnow`. |
| `awakeState` | The end (0 = none) and whether Low Power Mode is held. |

Rules:

1. **Journal first.** `/Library/Application Support/Tutto/awake.json` (root, 0600) is written before each change, and an entry leaves it only once that change is undone. A failed restore stays journaled and is retried every 30 s.
2. **The helper keeps the end.** A wall-clock timer ends the session 60 s after the app's own end, in case the app is hung. Sleep is never held past it.
3. **The app goes away mid-session** (crash, kill -9): paused processes are resumed at once, and the session runs on to its end, since the lid may be closed with agents working. Unattended, the helper also ends it below 5 % on battery or at critical heat, and puts a closed Mac to sleep on battery.
4. **The helper itself stops:** the next start finds the journal, resumes what it lists, and keeps the session to its end, or ends it if that has passed. Tutto connects at launch whenever sleep is still disabled, so a stale journal is cleared even after a restart.
5. While a session runs the helper doesn't exit when idle.

The app keeps a power assertion (`PreventUserIdleSystemSleep`, named "Tutto Stay Awake") for the session as well, so the Mac stays on with the lid open even without the helper.
