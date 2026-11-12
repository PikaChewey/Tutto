# Bluetooth batteries

Shows the charge of your AirPods, Magic Keyboard, Magic Mouse and Magic Trackpad on the menu bar panel and the Battery page, so you know which one is about to die before it does. A device at 20 % or under turns red. Nothing is drawn when none is connected.

## Where it lives

- **Menu bar panel:** a card right after the battery card, one line per device: symbol, name, levels. Earbuds read "L 80 % · R 82 % · Case 50 %", everything else "64 %". Clicking it opens the Battery page. When no device reports a level there is no card and no gap.
- **Battery page:** a "Bluetooth devices" section with the same rows. Until macOS has been asked for Bluetooth access it shows one line, "Show the charge of AirPods and other headphones", with an Allow Bluetooth button. Keyboards, mice and trackpads show without it.
- **Customize page:** listed as "Bluetooth devices", visible by default, wide only. In the preview it shows a one-line stand-in so it can be moved or hidden even with nothing connected.

No new tile in the tools row.

## How it works

Two reads, merged into one list (`Sources/TuttoKit/System/BluetoothBatteries.swift`, the reads in `Sources/Tutto/Modules/Battery/BluetoothBatteries.swift`):

1. **Apple audio devices:** IOBluetooth's paired, connected devices, through the `batteryPercentLeft`, `Right`, `Case` and `Single` properties. These use 0 for "no reading", so 0 is treated as unknown. Each property is checked with `responds(to:)` first (asking for one a device lacks would raise an exception), so a missing value just means no level.
2. **Keyboards, mice and trackpads:** the IORegistry `BatteryPercent` property on `AppleDeviceManagementHIDEventService` (and a few older class names), with the entry's `Product` name. Here 0 is a real, empty level.

A device in both lists is joined by its address (or its name) and its levels are combined. Kind comes from the name (keyboard, mouse, trackpad, headphones), else the Bluetooth device class. Every kind has its own SF Symbol.

macOS asks for Bluetooth access once before IOBluetooth may list devices (an app without `NSBluetoothAlwaysUsageDescription` is killed on the first call, so Info.plist has it). Tutto never triggers that prompt by itself: it only reads IOBluetooth once the permission is already granted, and the Allow Bluetooth button on the Battery page is what asks. Denied or restricted: the audio devices are skipped quietly and the registry ones still show.

Idle cost: nothing runs unless the panel, the Battery page or the Customize preview is on screen. Then it reads once, again every 30 s, and 2 s after a device connects or disconnects. When the last of those goes off screen the timer and the notifications are released. No process is started.

## Limits

- Needs the device to be connected, and AirPods need to be connected to this Mac.
- Bluetooth devices other than Apple's (and Apple devices that don't report) appear only if they expose the same properties.
- The audio keys are not public API. If a future macOS removes them the audio rows quietly disappear; the keyboard, mouse and trackpad rows do not depend on them.
- The panel shows names without a leading owner ("Bryan's AirPods Pro" is "AirPods Pro"); the Battery page shows the full name.

## Live tests

Run these on the built, installed app (not done here: nothing was run live). Bryan's AirPods and a Magic Keyboard or Mouse should be available.

1. **Cold start, no permission yet.** Reset the permission first (`tccutil reset Bluetooth ca.bryanyao.Tutto`), then open the panel. Pass: no macOS prompt appears; with only a Magic device connected its card appears, with AirPods only there is no card and no gap under the battery card. Open Tutto, Battery: the section shows the Allow Bluetooth line.
2. **Allow.** Click Allow Bluetooth. Pass: macOS asks once; after Allow, within a few seconds the connected AirPods appear on the Battery page with L, R and Case figures matching the Battery & Bluetooth settings (they may differ by a few percent). Deny instead: the line disappears and nothing crashes.
3. **Panel.** With AirPods connected, open the panel. Pass: one line per device after the battery card, symbols match kinds, no truncated levels, and the AirPods name reads "AirPods Pro" without the owner.
4. **Connect and disconnect.** With the panel open, put the AirPods in the case, then take them out. Pass: the line goes within about 2 s of disconnecting and comes back within about 2 s plus the time the AirPods take to report.
5. **Low level.** Any level at or under 20 % shows red, and only that level on a multi-level line. (Use a device that is low, or check the 20 % rule in `BluetoothBatteriesTests`.)
6. **Idle cost.** Close the panel and the main window, then run `sample Tutto 5` (or Activity Monitor): no Bluetooth timer fires; CPU 0.0 % and wakeups stay at the idle baseline. Open the panel: a read every 30 s, nothing after closing it. No child process appears at any point (`pgrep -P $(pgrep -x Tutto)` is empty).
7. **Customize.** Hide the card on the Customize page. Pass: the panel never reads Bluetooth (no timer) while it is hidden. Move it above the battery card and restore defaults: it returns after the battery card.
8. **Dark and light, large text.** The line fits on one line at the panel's width with long names.
