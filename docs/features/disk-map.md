# Disk map

See what's filling your disk. Scan your home folder (or, with Full Disk Access, the whole startup disk) and get rings of folders sized by what they take: hover one for its name and size, click a folder to go into it, and move what you don't need to the Trash from the list beside it. A scan only reads; nothing moves until you say so.

## Where it lives

Tools › Clean Up. A switch at the top of the page picks **Leftovers** (the Clean Up you know, unchanged) or **Disk map**. Nothing is added to the menu bar panel.

- **Before a scan:** one line of what it does, **Scan**, and (with Full Disk Access) **Home | Whole disk**. Without it, a line says the whole disk needs Full Disk Access.
- **While scanning:** items and bytes counted so far, and **Cancel**.
- **After:** the total, how many items, the folder's name and how long it took (and how many items couldn't be read); **Scan Again**.
- A trail (Home › Library › Caches) once you've gone into a folder; each step goes back there.
- The rings on the left (300 pt): the folder in the middle with its name and size, then up to five levels out. One calm hue per item of the first ring, lighter outwards; grey for merged slivers; the accent for the slice under the pointer, whose name, size and share replace the middle's label. Click a folder to go in, click the middle (it shows ↑) to go up.
- The biggest items in that folder on the right (up to 12), each with a size bar, **Show in Finder** and **Move to Trash…**. Clicking a folder's row goes into it.

## How it works

- `Sources/TuttoKit/DiskMap/DiskScanner.swift` reads folders with `open`/`readdir`/`fstatat` (no link following, one open folder per worker), three levels deep in parallel (`DispatchQueue.concurrentPerform`). Sizes are allocated blocks (`st_blocks × 512`), as `du` counts them. A file with more than one hard link counts once (device + inode set). Folders on another volume (a different `st_dev`) are skipped; the whole-disk scan also skips `/System/Volumes` (the data volume a second time), `/Volumes` and `/dev`. Apps and other bundles (`.app`, `.framework`, `.photoslibrary`…) are measured in full and kept as one item. Cancelling stops each worker at its next folder.
- **Compact tree:** each folder keeps only items of at least 1 MB, at most 200 of them; everything else becomes one "smaller items" node (with its count and bytes). A scan of an 8.8 GB, 109,000-item folder kept a tree small enough to draw in one frame.
- `SunburstLayout.swift` turns a folder into slices: depth gives the ring, angle is in proportion to size, children are biggest first, and slivers under 1.5° merge into one slice so a ring always adds up to its parent. `SunburstGeometry` does the hit test (ring from the distance, slice from the angle). `SunburstPalette` gives the colours.
- `DiskMapRules.swift` decides what can go to the Trash: only something inside the scanned folder (checked again with links resolved, right before the move), never the folder itself, your home's standard folders (Desktop, Documents, Library…), ~/Library's own folders, ~/.Trash, macOS's folders (/System, /usr, /Library, /private…), /Users or other accounts. An app in /Applications can go.
- `Sources/Tutto/Modules/Cleanup/DiskMapModel.swift` runs the scan off the main thread and reads its counts four times a second while it runs (that stops with the scan). After a move to the Trash (`FileManager.trashItem`, after a dialog stating the size) the item comes off the map and every folder above it shrinks, without a rescan.
- **Cost at rest:** nothing runs until you press Scan. No timers, no animation (so Reduce Motion has nothing to calm). The finished tree stays in memory until you scan again or switch Clean Up off (`CleanupModule.stop()` cancels a scan and drops the tree).

## Limits

- Without Full Disk Access, macOS asks once for Desktop, Documents and Downloads the first time a home scan reaches them, and app containers, Mail and Safari data can't be read; they're counted as "couldn't be read" and left out of the total.
- The whole-disk scan shows macOS's own sealed volume and the data volume together; swap, the recovery and preboot volumes (under /System/Volumes) aren't included, so the total is a little under what Finder reports as used. Purgeable space and local snapshots aren't shown.
- Files shared between APFS clones count in full in each place (as `du` does).
- Items under 1 MB are merged per folder, so a folder of many small files shows as one "smaller items" slice.
- When two folders share a hard-linked file, whichever is read first carries its size.

## Live test (for Bryan's assistant)

Run with Tutto built from this branch and Clean Up on. Don't trash anything but the test folder.

1. **Home scan, timed.** Tools › Clean Up › Disk map › Scan (Home). Time from click to the rings (stopwatch, or the `diskmap` log line: `log stream --predicate 'subsystem == "ca.bryanyao.Tutto" && category == "diskmap"'`, which prints items, bytes, seconds and nodes kept). If macOS asks about Desktop, Documents or Downloads, allow it (note which prompts appeared). Pass: done in under 90 s on an SSD home folder; the progress line counts up while it runs; Tutto's memory (Activity Monitor) is under 150 MB at the end and the log's "nodes kept" is under 100,000.
2. **Total against `du`.** In Terminal: `du -sk ~` (run it after the scan; with no Full Disk Access for Terminal, `du` prints permission errors for the same folders Tutto can't read). Compare `du`'s KiB × 1024 with the bytes in the log line. Pass: within 2 %. Also note the item count shown.
3. **Hover.** Move over a few slices. Pass: the slice turns the accent colour and the middle shows its name, size and share; moving off restores the folder's label. No lag.
4. **Drill down and back.** Click Library, then Caches. Pass: the trail reads Home › Library › Caches, the middle shows ↑, the list shows Caches' biggest items. Click the middle twice, then "Home" in the trail. Pass: back at the top each time.
5. **Show in Finder.** Click the magnifier on any row. Pass: Finder opens with that item selected.
6. **Refusals.** Hover the trash button on Documents, Library and (in Library) Caches. Pass: each is dimmed and its tooltip says it stays (one of the standard folders).
7. **Trash a test folder.** Before scanning: `mkdir -p ~/TuttoDiskMapTest && mkfile 300m ~/TuttoDiskMapTest/big.bin`. Scan Again, find TuttoDiskMapTest in the list at Home, click its trash button. Pass: the dialog names it and says about 300 MB; Cancel leaves it; Move to Trash puts it in the Trash (`ls ~/.Trash | grep TuttoDiskMapTest`), it disappears from the rings and list, and the total drops by about 300 MB. Then empty that one item from the Trash in Finder.
8. **Cancel.** Scan Again and press Cancel within a few seconds. Pass: the scan stops within a second and the previous map is still shown.
9. **Whole disk** (only with Full Disk Access granted). Pick Whole disk, Scan. Pass: finishes; the total is within 10 % of the "Used" column of `df -k /System/Volumes/Data` plus that of `df -k /` (local snapshots and swap make up most of any gap); no folder appears twice (no System › Volumes › Data branch).
10. **Idle.** Leave the page on the map for a minute without touching it, then switch to Leftovers. Pass: Tutto's CPU in Activity Monitor is 0.0 % throughout; Leftovers looks and works as before.
11. **Off means off.** Switch Clean Up off and on. Pass: Disk map is back to its Scan screen.
