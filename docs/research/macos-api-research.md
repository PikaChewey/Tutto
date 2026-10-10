# macOS 26 system-API research for Tutto

Target: MacBook Pro 14" **M5** (`Mac17,2`, board `J704`, GPU `AGXAcceleratorG17G` / `gpu,t8142`, 10 GPU cores, 4 Super + 6 Efficiency CPU cores). macOS 26.5.2 (25F84), SDK `MacOSX26.5.sdk`. Research date: 2026-10-10.

Labels:
- **[V-local]**: measured on this Mac with read-only probes. No SMC writes were made.
- **[V-src]**: read in source code, an SDK header or Apple documentation.
- **[U]**: uncertain or third-party only.

---

## 1. Fan control (SMC) and the privileged helper

### SMC user-client ABI [V-local]
- Open the service with `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))`, then `IOServiceOpen(svc, mach_task_self(), 0, &conn)`.
- Every operation is `IOConnectCallStructMethod(conn, 2, &in, 80, &out, &outSize)`. Put the command in `data8`:
  - `9`: get key info
  - `5`: read bytes
  - `6`: write bytes
  - `8`: get key at index (`data32` = index; `#KEY` holds the key count, 2778 on this M5)
- Check the firmware result in `out.result`: `0x84` = not found, `0x82` = bad command, `0x85` = not readable.

```c
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;      // 6 B
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit; // 16 B
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;    // 12 B (padded)
typedef struct { UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
                 char result, status, data8; UInt32 data32; UInt8 bytes[32]; } SMCKeyData_t;
// sizeof=80; keyInfo@28 result@40 data8@42 data32@44 bytes@48  (offsets checked with offsetof on this Mac)
```

In Swift, pass `MemoryLayout<SMCKeyData_t>.stride`.

### Fan keys on this M5 [V-local]
- `FNum` (`ui8`) = **1**. This base 14" M5 has one fan.
- Fan 0:

| Key | Type | Attr | Notes |
|---|---|---|---|
| `F0Ac` | `flt ` | | Actual RPM. Reads 0, because the fan idles stopped. |
| `F0Mn` | `flt ` | | 2317 |
| `F0Mx` | `flt ` | | 6550 |
| `F0Tg` | `flt ` | 0xd4 | Target RPM |
| **`F0md`** | `ui8 ` | 0xd0 | Lowercase mode key. Currently reads 0. |
| `F0St` | `ui8` | | Reads 3 |

- `F0Md` (uppercase) and **`Ftst` do not exist** on this machine.
- `flt ` is a 4-byte **little-endian IEEE-754** float. `fpe2` (14.2 fixed-point, big-endian) appears only on Intel.

### Write sequence [V-src]
Published open-source fan-control code (with separate changes for M3/M4 and for M5) establishes this sequence.

1. **Pick the mode key.** Read `F0md`; if it exists, use `F%dmd`, otherwise use `F%dMd`.
2. **Unlock manual mode.**
   - Write mode = `1` (`ui8`). This works directly on M1 and M5.
   - If that write fails and `Ftst` exists (M3/M4): write `Ftst=1`, sleep about 3 s while `thermalmonitord` yields, then retry the mode write every 100 ms for up to 300 tries.
3. **Set the speed.** Write `F%dTg` as a `Float` (4 bytes LE). Clamp the value to `F%dMx`; independent reverse-engineering notes report that the hardware itself accepts values below `Mn` and above `Mx`.
4. **Reset to automatic.**
   - Write mode = `0` and `F%dTg = 0.0`.
   - If `Ftst` exists and equals 1, write `Ftst=0` after the last fan returns to auto.
   - If `Ftst` is absent (M5), reset each `F%dmd` to `0`.

Mode values: `0` = auto, `1` = manual, `3` = "system". On M4, mode 3 means `thermalmonitord` mitigation and firmware rejects mode writes with `0x82`.

Other behaviour reported in those reverse-engineering notes:
- On M4, control is reclaimed within seconds after the controlling process exits.
- Firmware resets `Ftst` on sleep, so manual control must be re-applied on wake.
- Whether manual mode persists on **M5** after the helper exits is **[U]**. The helper must restore auto when the XPC client invalidates, on SIGTERM, and before sleep.

### Root requirement [V-src]
- Reads work unprivileged. All the reads above ran as uid 501. [V-local]
- Writes to fan keys return `kIOReturnNotPrivileged` (`0xe00002c2`) unless the caller is root. Independent research notes attribute this to per-key attributes.
- Every shipping fan-control utility uses a root launchd daemon for writes. Intel-era tools used a setuid-root `smc` binary, which is legacy.

### Common privileged-helper pattern [V-src]
This is how an existing open-source menu bar monitor installs and talks to its helper. Labels below are shown with Tutto's own identifiers.

**Installation**
- On macOS 13 and later: `SMAppService.daemon(plistName: "ca.bryanyao.Tutto.helper.plist").register()`. On `.requiresApproval`, call `SMAppService.openSystemSettingsLoginItems()`.
- Older systems fall back to `SMJobBless` (helper `Info.plist` `SMAuthorizedClients`), and the app cleans up any legacy `/Library/PrivilegedHelperTools` install.
- The daemon plist is copied to `Contents/Library/LaunchDaemons`:
```xml
<key>Label</key><string>ca.bryanyao.Tutto.helper</string>
<key>BundleProgram</key><string>Contents/Library/LaunchServices/ca.bryanyao.Tutto.helper</string>
<key>MachServices</key><dict><key>ca.bryanyao.Tutto.helper</key><true/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>ca.bryanyao.Tutto</string></array>
```

**Connection and caller check**
- The client connects with `NSXPCConnection(machServiceName: "ca.bryanyao.Tutto.helper", options: .privileged)`, using an `@objc protocol HelperProtocol`.
- The helper's `shouldAcceptNewConnection` checks the caller:
  1. Reads the audit token with `connection.value(forKey: "auditToken")` (private KVC).
  2. Calls `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData], …)` and then `SecCodeCopyStaticCode`.
  3. Compares `kSecCodeInfoCertificates` with its own certificates.
- In that pattern the helper does not write the SMC itself. It runs a bundled `smc` CLI after a signature check, and exits when idle.

### Recommended modern design for Tutto [V-src APIs]
- **Plist.** Put `Contents/Library/LaunchDaemons/<label>.plist` in the bundle. Include `Label`, `BundleProgram` (relative to the app bundle, for example `Contents/MacOS/TuttoHelper`), `MachServices`, and `AssociatedBundleIdentifiers`. The `plistName` argument must include `.plist` ([forum 792826](https://developer.apple.com/forums/thread/792826)).
- **Do SMC writes in-process in the helper.** Expose a small API: `setFan(id:rpm:)`, `setAuto(id:)`, `resetAll()`. Validate the id against `FNum` and clamp the RPM.
- **Check callers.** Either API works:
  - macOS 13+: `listener.setConnectionCodeSigningRequirement("anchor apple generic and identifier \"ca.bryanyao.Tutto\" and certificate leaf[subject.OU] = \"TEAMID\"")`. On the client, call `connection.setCodeSigningRequirement(…)` before `resume()`. A malformed requirement traps in Swift, and calling it twice is an error.
  - macOS 26: `XPCListener(service: "ca.bryanyao.Tutto.helper", requirement: .isFromSameTeam(andMatchesSigningIdentifier: "ca.bryanyao.Tutto"), incomingSessionHandler:)`, paired with `XPCSession(machService:options: .privileged, requirement:)`.
  - Lower level: `xpc_connection_set_peer_code_signing_requirement` (12.0) and `…_team_identity_requirement` (14.4).
- **Approval flow on macOS 26** [V-local strings, V-src docs]:
  1. `register()` posts a "Background Items Added" notification. It typically throws `Operation not permitted` with status `.requiresApproval`.
  2. The user turns the app on in **System Settings › General › Login Items & Extensions › App Background Activity**. "App Background Activity" is the 26.5 string in `LoginItems.appex`; 13–15 called it "Allow in the Background". This needs admin authentication.
  3. launchd then starts the daemon on demand when the app connects to the Mach service.
- **Debugging and caveats:**
  - Inspect with `sfltool dumpbtm` and `launchctl print system/<label>`. Reset with `sfltool resetbtm`.
  - Unregister then re-register can fail transiently.
  - Test from `/Applications`, with no stale copies in DerivedData.
- **Signing [U]:**
  - Apple DTS guidance in the forums: sign the app and the daemon with the *same Apple-issued identity*. Ad-hoc ("Sign to Run Locally") breaks registration.
  - Developer ID is only required for *distribution*; SMAppService adds no constraints beyond that ([forum 751439](https://developer.apple.com/forums/thread/751439)).
  - An **Apple Development**-signed, non-notarized, locally built (non-quarantined) app should work, but no Apple statement confirms it. One open-source fan-control project's README claims a Developer ID is mandatory, which conflicts with that guidance. Verify early.

---

## 2. Temperature sensors without root

### HID route
Private declarations, as used by published open-source sensor readers:

```c
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
#define IOHIDEventFieldBase(type) ((type) << 16)
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventTypePower 25
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t type, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef); // @"Product"
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t field);              // field = 15<<16
```

How to read them:
- Match on `{"PrimaryUsagePage": 0xff00, "PrimaryUsage": 5}`.
- Get services with `IOHIDEventSystemClientCopyServices`, then call `CopyEvent(svc, 15, 0, 0)` on each.
- Re-discover services every 60 s and reset on wake, as existing monitors do.

**Names on this M5** [V-local, 47 services]:
- `PMU tdie1…14`, `PMU tdev1…8`, `PMU tcal`
- `PMU2 tdie1…10`, `PMU2 tdev1…5`
- `NAND CH0 temp`
- `gas gauge battery` (×6)

Caveats:
- `PMU tdev1` returned −9202 (garbage), so filter values to 0–110 °C.
- **No names say CPU or GPU.** Published sensor tables only map the M1-era `pACC/eACC/GPU/SOC MTR Temp` names, so on M5 the HID route adds nothing to the CPU/GPU averages.
- The 0xff08 voltage/current pages returned implausible values (~16000) with field `25<<16`, so treat them as unusable.

### SMC route (what existing monitors use for CPU/GPU) [V-src, V-local]
Published open-source SMC key tables define the M5 set:
- **CPU "super core 1–6":** `Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K`
- **CPU "performance core 1–12":** `Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y`
- **GPU 1–8:** `Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g`

Skip missing keys. "Average CPU" is the mean of the present CPU keys flagged `average:true`, and "Hottest CPU" is their max; GPU works the same way.

On this base M5:
- These exist: `Tp00 Tp04 Tp0C Tp0G Tp0O Tp0R Tp0X Tp0a Tp0p Tp0u Tp0y`, plus all eight GPU keys.
- `Tp08`, `Tp0K`, `Tp0U`, `Tp0d`, `Tp0g`, `Tp0j` and `Tp0m` are absent.
- Other keys present, meaning **[U]**:
  - `Te04/08/0C/0R`
  - `Ts00…Ts0R`
  - `TB0T/TB1T/TB2T` (battery, ≈30 °C)
  - `TW0P`
  - `TPD*`, `TRD*`, `TD*`
- All of these are `flt ` LE. Ignore the `ioft` and `si32` T-keys.

Labels: sysctl reports `hw.perflevel0.name = "Super"` and `perflevel1 = "Efficiency"` [V-local], while some existing tools label the small cores "performance". **Recommendation:** label groups by `hw.perflevelN.name` and treat the per-core key mapping as heuristic.

---

## 3. Battery (AppleSmartBattery) and per-process energy

### Values on this Mac [V-local, `ioreg -rw0 -c AppleSmartBattery`]

| Key | Value | Meaning |
|---|---|---|
| `CurrentCapacity` / `MaxCapacity` | 95 / 100 | **Percent** on Apple Silicon. `MaxCapacity` is always 100. |
| `AppleRawCurrentCapacity` | 5376 | mAh remaining |
| `AppleRawMaxCapacity` | 5719 | mAh. Gauge full-charge capacity (= `BatteryData.FccComp1`). |
| `NominalChargeCapacity` | 5871 | mAh |
| `DesignCapacity` | 6249 | mAh |
| `CycleCount` | 127 | `DesignCycleCount9C` = 1000 |
| `Voltage` / `AppleRawBatteryVoltage` | 12871 | mV |
| `Amperage`, `InstantAmperage` | 0 | mA, signed (negative = discharging) |
| `Temperature` | 3037 | 0.01 °C (also `VirtualTemperature`) |

- `ioreg` prints negative numbers as two's-complement unsigned; read them as `Int64`.
- **"Maximum Capacity" matches `NominalChargeCapacity / DesignCapacity`.** `system_profiler SPPowerDataType` shows **94%**, and 5871/6249 = 93.95%.
- **Don't use `AppleRawMaxCapacity / DesignCapacity`.** Some existing monitors do; it gives 91.5% → 92% here and disagrees with Apple. SMC `PPBR` (battery W) and `PDTR` (DC-in W) are an alternative source for power figures.
- **`AdapterDetails`:**
  - `Watts` (68 for a 70 W adapter), `AdapterVoltage` (mV), `Current` (mA), `Name`, `Manufacturer`, `IsWireless`
  - `UsbHvcMenu` (the PD profiles) and `UsbHvcHvcIndex`
  - Public API alternative: `IOPSCopyExternalPowerAdapterDetails()` → `kIOPSPowerAdapterWattsKey`.
- **`PowerTelemetryData`** (mW):
  - `SystemPowerIn` = 10458. This matches `SystemVoltageIn` 20432 mV × `SystemCurrentIn` 511 mA = 10.44 W, and SMC `PSTR` = 10.41 W.
  - `SystemLoad` = 10458 and `BatteryPower` = 0 (on AC, not charging).
  - `AdapterEfficiencyLoss` = 87, plus `Accumulated*` counters.
  - Behaviour on battery power is **[U]**; it wasn't tested. Expect `SystemPowerIn` = 0 and `BatteryPower` > 0.
- **`ChargerData`:** `NotChargingReason`, `ChargingCurrent`, `ChargingVoltage`.

### Top energy processes
- **What existing monitors do** [V-src]: run `/usr/bin/top -o power -l 2 -n N -stats pid,command,power` and parse the second sample. That takes about 1 s per refresh.
- **Why `top` can see everything** [V-local]: `/usr/bin/top` is **setuid root** and has `com.apple.system-task-ports.read`.
- **`proc_pid_rusage` from a non-root, unsandboxed process** [V-local]: it succeeded for exactly the 360 uid-501 processes and returned **EPERM for every other-uid process** (169), including WindowServer and launchd.
- **Fields worth using** (`struct rusage_info_v6`, `RUSAGE_INFO_V6`):
  - `ri_energy_nj` is populated. Δ/Δt gives plausible watts, for example a 41 % CPU renderer at 0.34 W.
  - `ri_billed_energy` is mostly 0.
  - `ri_user_time` and `ri_system_time` are **mach ticks**: multiply by `timebase` 125/3.
- **Recommendation:** have the root helper sample all pids every few seconds and return `[pid: watts]`, or fall back to `top`.
- **Energy Impact:** Activity Monitor's score is an undocumented formula. On Intel it used the `/usr/share/pmenergy` coefficients; this Mac has only `default.plist` plus Intel board IDs ([Chromium energy_impact_mac.h](https://chromium.googlesource.com/chromium/src/+/9e001703a2/components/power_metrics/energy_impact_mac.h)).

---

## 4. GPU utilisation and CPU/GPU frequency without root

### GPU utilisation [V-local]
- Read `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics`. This works as a normal user:
  - `Device Utilization %` (16), `Renderer Utilization %` (16), `Tiler Utilization %` (10)
  - `In use system memory` (bytes, 955 MB), `Alloc system memory`, `Allocated PB Size`, `recoveryCount`
- `Temperature(C)`, `Core Clock(MHz)`, etc. exist on discrete/Intel GPUs only.

### IOReport [V-local]
Link `-lIOReport` and declare the private functions yourself:

```c
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef *out, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef);
// IOReportChannelGetGroup/SubGroup/ChannelName/UnitLabel, IOReportStateGetCount/NameForIndex/Residency,
// IOReportSimpleGetIntegerValue(ch, 0); iterate delta[@"IOReportChannels"]
```

What a subscription returns, as uid 501:
- **CPU:** `CPU Stats / CPU Core Performance States`, channels `ECPU0-5` (9 states: `IDLE` + 8) and `PCPU0-3` (20 states: `IDLE` + 19). IOReport still says "PCPU" for the Super cores.
- **GPU:** `GPU Stats / GPU Performance States`, channel `GPUPH` (16 states: `OFF`, `P1…P15`).
- **Energy:** `Energy Model` gives per-core values plus `ECPU`, `PCPU`, `CPU Energy`, `GPU Energy`, `ANE`, `DRAM`. Units vary (`mJ`, `uJ`, `nJ`), so read `UnitLabel`. CPU watts = ΔmJ / Δt.

**Frequency tables** come from the IORegistry `AppleARMIODevice` node `pmgr`. Each entry is a (freq, voltage) pair of LE `UInt32`s. On M4 and later, CPU values are in **kHz**; the GPU is in **Hz**.
- `voltage-states1-sram` (E-cluster): 972, 1152, 1584, 1992, 2352, 2700, 2964, 3048 MHz.
- `voltage-states5-sram` (Super cluster): 1308 … 4608 MHz (19 entries).
- `voltage-states9` (GPU): 0, 338, 486, … 1620 MHz.

**Computing average frequency:** Σ(residencyᵢ·fᵢ) / Σ(active residency), skipping `IDLE`, `DOWN` and `OFF`. Residency ticks are 24 MHz.

The GPU has 15 P-states but only 13 non-zero table entries. **[U]** The state-to-frequency mapping needs verification against open-source Apple Silicon monitors. M5 Pro/Max add `acc-clusters` and M6 adds `pmgr-child` to the `pmgr` layout, so handle those too.

`powermetrics` needs root; IOReport doesn't.

---

## 5. Finder integration (Finder Sync) and extraction preferences

### Finder Sync: monitoring all files [V-src]
- Set `FIFinderSyncController.default().directoryURLs = ["/"] + mountedVolumeURLs` and update it on `NSWorkspace.didMount`, `didUnmount` and `didRenameVolume`. Several open-source Finder Sync extensions use this pattern with a mounted-volume observer.
- Apple DTS says this "menu everywhere" use is unsupported ([forum 766680](https://developer.apple.com/forums/thread/766680)).
- Known costs:
  - Some locations never get menus (for example `/Applications`).
  - When another sync extension claims a folder, one of them wins.
  - Registering volume roots can replace sidebar volume icons (reported in an open-source extension's issue tracker).
  - Extra extension instances are spawned for Open/Save panels, so keep `init` and `menu(for:)` free of I/O.
- In `menu(for: .contextualMenuForItems)`, read `selectedItemURLs()` and show items only for archive extensions. The `FIMenuKind` values are 0–3.
- The action is sent to the principal object. Route on `tag`, because `representedObject` is unreliable.

### Building the .appex without Xcode [V-src: Xcode 26.6 xcspecs]
- Linker and compiler flags: `-e _NSExtensionMain`, `-application-extension` (swiftc), `-fapplication-extension` (clang).

```sh
swiftc -parse-as-library -module-name TuttoFinderExt -target arm64-apple-macos26.0 -application-extension \
  -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain FinderSync.swift -o TuttoFinderExt
```

- The SwiftPM equivalent is `linkerSettings: [.unsafeFlags(["-Xlinker","-e","-Xlinker","_NSExtensionMain"])]`.
- `Info.plist`:
  - `CFBundlePackageType` = `XPC!`
  - `NSExtension` = { `NSExtensionPointIdentifier` = `com.apple.FinderSync`, `NSExtensionPrincipalClass` = `TuttoFinderSync`, `NSExtensionAttributes` = {} }
  - Declare the class as `@objc(TuttoFinderSync) final class … : FIFinderSync` to avoid module-name mangling.
- Entitlements: `com.apple.security.app-sandbox` plus `files.user-selected.read-only`.
- Location: `Tutto.app/Contents/PlugIns/TuttoFinderExt.appex`.
- Signing: sign the appex first, with its entitlements, then the app (no `--deep`), using the same Apple Development identity.

### Registering and enabling [V-src, man page]
```sh
pluginkit -a <appex>
pluginkit -e use -i <bundle-id>
pluginkit -m -v -p com.apple.FinderSync
```
- In the `-m` output, `+` = enabled and `=` = superseded. Stale DerivedData copies win if their version is higher.
- The settings UI disappeared in 15.0 and returned in 15.2.
- On 26.5, the extensions pane contains a "Finder Sync" category [V-local strings]. Reach it via **General › Login Items & Extensions › Extensions**; the exact click path is **[U]**.
- Call `FIFinderSyncController.isExtensionEnabled` and `showExtensionManagementInterface()` (10.14+) from the app.

### Handing files to the main app [V-src]
- **Use a custom URL scheme.** For example, `tutto://extract?file=…&file=…&dest=…` built with `URLComponents` and opened with `NSWorkspace.shared.open(url)`. It needs no app group and launches the app if needed.
- The app must treat incoming paths as untrusted. Never trash an archive based only on a URL request.
- Alternatives and their problems:
  - Sandboxed distributed notifications drop `userInfo`.
  - An app group needs proper Team-ID group IDs on 15+.
  - A regular app can't publish an XPC service.
- **NSServices** is also available (some existing extraction utilities use it):
  - Keys: `NSSendFileTypes` (UTIs) plus a mandatory `NSRequiredContext`.
  - Services appear at the bottom of the context menu, or in a Services submenu. They are never top-level like Finder Sync items.

### Extraction preferences baseline [V-src]
The settings that comparable utilities converge on, with sensible defaults:

| Setting | Options | Default |
|---|---|---|
| Extract archives to | same folder / other path / ask | first run asks |
| Create a new folder for the extracted files | only if more than one top-level item / always / never | only if >1 |
| Set the folder's modification date to | now / the archive's date | now |
| …also for top-level items | on / off | off |
| Reveal expanded items in Finder | on / off | off |
| Move the archive to the Trash | on / off. Applies to all volumes, only when extraction had no errors. | off |
| Filename encoding | fixed, or Detect Automatically | Detect Automatically |
| Detection threshold | % confidence | 80 |

- Holding ⌥ or ⇧ while opening an archive forces "ask".
- **How encoding detection typically works** (open-source unarchiving libraries):
  - Pure-ASCII names skip detection. Otherwise all names in the archive are fed to Mozilla's UniversalDetector.
  - If detection fails, windows-1252 is used (MacRoman for Mac archives).
  - The detected charset is used when `confidence ≥ threshold` and the bytes decode cleanly. Otherwise a picker with a live preview is shown.

---

## 6. System libarchive [V-local]

### Version and linking
- Runtime: `archive_version_details()` = **"libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8"** (`bsdtar 3.5.3`).
- The dylib lives only in the dyld shared cache.
- The SDK ships `usr/lib/libarchive.tbd` / `libarchive.2.tbd` (install name `/usr/lib/libarchive.2.dylib`, current version 9.2), so `-larchive` links.
- **The SDK has no `archive.h`.** Vendor `archive.h` and `archive_entry.h` from libarchive tag **v3.7.4** (BSD-2) and expose them through a module map:
  ```
  module CArchive [system] { header "archive.h" header "archive_entry.h" link "archive" export * }
  ```
- **[U]** App Store acceptability is unclear because Apple publishes no header.

### Format support
`archive_read_support_*` return values:
- **ARCHIVE_OK** for these formats: `rar` (RAR4), `rar5`, `7zip`, `cab`, `lha`, `xar`, `iso9660`, `zip`.
- **ARCHIVE_OK** for these filters: `xz`, `lzma`, `bzip2`, `lzip`, gzip.
- **ARCHIVE_WARN (-20, "Using external … program")** for `zstd`, `lz4`, `lzop`, `lrzip`, `grzip`. These are not built in, and macOS ships no `zstd` binary.
- **`.tar.zst` and `.tar.lz4` will fail** unless you bundle libzstd/liblz4, or a full libarchive built with them.

### Passphrases
- Use `archive_read_add_passphrase(a, "pw")` or `archive_read_set_passphrase_callback`.
- **ZIP:** both ZipCrypto and **WinZip AES-256** decrypt. Verified with `bsdtar --passphrase`; a wrong password gives "Incorrect passphrase".
- **RAR4** ("RAR encryption support unavailable"), **RAR5** ("Encryption is not supported") and **7z AES** (entries are flagged with `archive_entry_is_data_encrypted`, but there is no decoder) **cannot be decrypted** [V-src, v3.7.4 sources].
- Detect these cases with `archive_read_has_encrypted_entries()` and `archive_entry_is_encrypted()`, and show "unsupported encryption" or fall back to another engine.

### Multi-volume archives
- Use `archive_read_open_filenames(a, (const char*[]){p1, p2, …, NULL}, 10240)`.
- RAR4 handles `MHD_VOLUME` / `FHD_SPLIT_*`, and RAR5 has multivolume switching [V-src].
- Split `.7z.001` files should work because the reader just concatenates them **[U]**.

### Filename encodings
- On POSIX, `archive_string_default_conversion_for_read()` returns **NULL**, meaning no conversion [V-src]. So for ZIP entries without the UTF-8 flag (bit 11), `archive_entry_pathname()` returns the **raw bytes**.
- To force a charset, call `archive_read_set_options(a, "zip:hdrcharset=CP932")` **before opening**. It returned OK here; the `rar` and `lha` readers have the same option.
- Practical approach:
  1. Collect the raw names.
  2. If the bytes are valid UTF-8, use them. Otherwise detect the encoding with `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)`, suggesting CP437, Shift-JIS, GBK, Big5, EUC-KR and CP1251.
  3. Apply a confidence threshold (80% is a common default).

---

## 7. ScreenCaptureKit stills [V-src SDK 26.5 headers unless noted]

### Available APIs
- `SCScreenshotManager.captureImage(contentFilter:configuration:)` (14.0)
- `captureImage(in: CGRect)` (**15.2**): global points, multi-display, **no filter**, so it can't exclude your own windows.
- `captureScreenshot(contentFilter:configuration: SCScreenshotConfiguration) -> SCScreenshotOutput` (**26.0**):
  - Returns `sdrImage`, `hdrImage` and `fileURL`.
  - Configuration includes `showsCursor`, `dynamicRange` (`.sdr`/`.hdr`/`.bothSDRAndHDR`), `displayIntent` and `fileURL`/`contentType`.

### Per-display grab
1. Cache `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`. Refresh it on `didChangeScreenParametersNotification`.
2. Build `SCContentFilter(display:excludingApplications:[ownSCRunningApplication], exceptingWindows: [])`.
3. Set width and height to `contentRect × pointPixelScale`, with `captureResolution = .best` and `showsCursor = false`.

### Latency [U, third-party]
- About 130 ms p50 for a one-shot capture including enumeration, and 40–45 ms for enumeration alone.
- `replayd` serialises concurrent captures, so capture the display under the cursor first and the others sequentially.
- Freeze one full-resolution frame and crop from it.

### Excluding your windows and legacy API
- Don't rely on `NSWindow.sharingType = .none`; SCK ignores or inconsistently honours it on 15+ (FB21115847).
- `CGWindowListCreateImage` is obsoleted in the 15 SDK.

### Permission
- `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` (10.15).
- **Recurring "bypass the system private window picker" prompt:**
  - 15.0 asked monthly. 15.1 reduced it for regularly used apps.
  - Apple DTS reproduced it with `SCShareableContent` + `captureImage`, so stills do trigger it.
  - Ways around it: `com.apple.developer.persistent-content-capture`, which needs Apple approval and is meant for remote-desktop apps; or `SCContentSharingPicker`, which is unsuitable for instant capture.
  - **[U]** It still exists on 26.
- TCC is keyed to the code signature. Ad-hoc builds lose the grant on every rebuild, so use Apple Development with a stable bundle ID.

---

## 8. Global hotkeys [V-src HIToolbox headers]

### Registration
- `RegisterEventHotKey(UInt32 keyCode, UInt32 mods, EventHotKeyID{OSType signature; UInt32 id}, GetEventDispatcherTarget(), 0, &ref)`.
- Install the handler with `InstallEventHandler` for `{kEventClassKeyboard, kEventHotKeyPressed}`.
- Modifier masks: `cmdKey` 0x100, `shiftKey` 0x200, `optionKey` 0x800, `controlKey` 0x1000.
- No TCC permission is needed. By contrast, `NSEvent.addGlobalMonitorForEvents` for keys needs Accessibility, and `CGEventTap` needs Input Monitoring.

### macOS 15.0–15.1 restriction
- Hotkeys whose modifiers were only Option or Option+Shift failed with **-9868 (`eventInternalErr`)**. Apple's stated reason was anti-keylogging.
- It mostly hit sandboxed apps and was **fixed in 15.2** ([forum 763878](https://developer.apple.com/forums/thread/763878), KeyboardShortcuts #176).

### Conflicts
- The same combo registered twice in one process returns `eventHotKeyExistsErr` (-9878).
- Across processes, both registrations succeed and both fire, unless `kEventHotKeyExclusive` is used.
- System shortcuts are **not** checked. Registration returns `noErr` but the hotkey may never fire.
- **⌘⇧`** is the implicit reverse of symbolic hotkey **27**, "Move focus to next window" (⌘`, params `[96, 50, 1048576]`). It is active by default on this Mac (ID 27 isn't overridden in `com.apple.symbolichotkeys`).
  - Registration will likely succeed, but behaviour is contested. Avoid it as a default, or warn the user.
- Detect conflicts with `CopySymbolicHotKeys` (keys `kHISymbolicHotKeyCode`, `…Modifiers`, `…Enabled`), plus a special case for ⌘⇧`.

### Recorder best practice
- Follow the pattern used by sindresorhus/KeyboardShortcuts (local `keyDown` monitor) and MASShortcut (`MASShortcutValidator`):
  - Require ⌘ or ⌃, or allow bare F-keys.
  - Reject Shift-only shortcuts.
  - Check system symbolic hotkeys and your own main menu.
- Store virtual key codes such as `kVK_ANSI_Grave` = 0x32. Display them with `UCKeyTranslate` on `TISCopyCurrentKeyboardLayoutInputSource`.

---

### Key sources
- Published open-source SMC key tables, sensor readers and fan-control research notes (not linked)
- [libarchive v3.7.4 sources](https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive)
- Apple documentation: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [XPCPeerRequirement](https://developer.apple.com/documentation/xpc/xpcpeerrequirement), [NSXPCListener.setConnectionCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
- Apple Developer Forums threads: [756846](https://developer.apple.com/forums/thread/756846), [761249](https://developer.apple.com/forums/thread/761249), [765103](https://developer.apple.com/forums/thread/765103), [766680](https://developer.apple.com/forums/thread/766680)
- [Chromium `energy_impact_mac.h`](https://chromium.googlesource.com/chromium/src/+/9e001703a2/components/power_metrics/energy_impact_mac.h)
