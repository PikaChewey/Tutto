//
//  MemoryRelief.swift
//  Tutto
//
//  Pictures are most of what Tutto keeps in memory, and all of them are kept only for speed:
//  window pictures for the switcher and the strip bar, the switcher's cards, the bar's tiles.
//  They go on their own when unused (30 s after the switcher closes, a minute after the bar
//  hides), and all at once when macOS says memory is short; each comes back the next time it's
//  shown. Their pixels live in memory of their own (MappedImage), so letting go of a picture
//  gives its memory back to macOS at once.
//

import Darwin
import Foundation

@MainActor
enum MemoryRelief {
    private static var source: DispatchSourceMemoryPressure?

    /// Calls `purge` whenever macOS reports memory pressure (warning or critical).
    static func start(_ purge: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                purge()
                returnFreedPages()
            }
        }
        source.resume()
        self.source = source
    }

    static func stop() {
        source?.cancel()
        source = nil
    }

    /// Asks the allocator to give back what it's keeping for reuse. Under pressure only: measured
    /// on macOS 26, it returns nothing for picture-sized blocks (MappedImage is what fixes those).
    static func returnFreedPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
