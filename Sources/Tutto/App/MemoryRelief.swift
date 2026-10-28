//
//  MemoryRelief.swift
//  Tutto
//
//  Pictures are most of what Tutto keeps in memory, and all of them are kept only for speed:
//  window pictures for the switcher and the strip bar, the switcher's cards, the bar's tiles.
//  They go on their own when unused (30 s after the switcher closes, a minute after the bar
//  hides), and all at once when macOS says memory is short; each comes back the next time it's
//  shown. After letting go, the freed pages are handed back so the footprint drops too.
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

    /// Freed picture buffers can stay in the allocator's free lists, still counted against Tutto;
    /// this hands them back to macOS. A few milliseconds, so only after letting go of pictures.
    static func returnFreedPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
