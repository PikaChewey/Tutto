//
//  MemoryLab.swift
//  Tutto
//
//  Debug-only: `Tutto --memory-lab main <rounds>` builds the main window the way
//  MainWindowController does, off screen, shows every page, closes it as the close button
//  does, and prints whether the window and its views were freed, with Tutto's footprint
//  after each round. Nothing appears on screen and, as with snapshots, only the System and
//  Sensors modules start, so it runs beside the installed app without touching its state.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum MemoryLab {
    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--memory-lab"), args.count > flag + 1, args[flag + 1] == "main" else { return false }
        let rounds = args.count > flag + 2 ? Int(args[flag + 2]) ?? 4 : 4
        let model = AppModel.shared
        AppModel.rendersOffscreen = true
        model.launch(quietly: true)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        print(String(format: "start: %.1f MB · ", footprint()) + mallocInUse())
        var windows: [Weak<NSWindow>] = []
        var hosts: [Weak<NSViewController>] = []
        for round in 1...rounds {
            autoreleasepool {
                // As MainWindowController.show builds it (no frame autosave: that would write the app's defaults).
                let navigation = MainWindowController.shared.navigation
                let hosting = NSHostingController(rootView: MainView(model: model, navigation: navigation))
                hosting.sizingOptions = []
                let window = NSWindow(contentViewController: hosting)
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbarStyle = .unified
                window.title = "Tutto"
                window.setContentSize(NSSize(width: 920, height: 640))
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.orderFrontRegardless()
                for page in MainPage.allCases {
                    navigation.page = page
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                }
                windows.append(Weak(window))
                hosts.append(Weak(hosting))
                window.performClose(nil)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let liveWindows = windows.filter { $0.value != nil }.count
            let liveHosts = hosts.filter { $0.value != nil }.count
            print(String(format: "round %d: %.1f MB · windows alive %d of %d · hosting controllers alive %d of %d · ",
                         round, footprint(), liveWindows, windows.count, liveHosts, hosts.count) + mallocInUse())
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        print(String(format: "5 s later: %.1f MB · windows alive %d · hosting controllers alive %d · ", footprint(),
                     windows.filter { $0.value != nil }.count, hosts.filter { $0.value != nil }.count) + mallocInUse())
        let returned = malloc_zone_pressure_relief(nil, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        print(String(format: "after pressure relief (%.1f MB returned): %.1f MB · ", Double(returned) / 1_048_576, footprint()) + mallocInUse())
        if args.contains("hold") {
            // Time to look from outside: footprint, heap, vmmap on this pid.
            print("holding 40 s, pid \(getpid())")
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(40))
        }
        model.shutdown()
        return true
    }

    /// Bytes malloc has handed out and not had back, against what it holds from the system.
    private static func mallocInUse() -> String {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return String(format: "malloc in use %.1f of %.1f MB", Double(stats.size_in_use) / 1_048_576, Double(stats.size_allocated) / 1_048_576)
    }

    private static func footprint() -> Double {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }
}
#endif
