//
//  WorkFolder.swift
//  Tutto
//
//  Where a result changed again in place (the result card's Half and Crop) is written first, so
//  the swap is a rename on the same disk.
//

import Foundation

enum WorkFolder {
    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ca.bryanyao.Tutto/Work")
    }

    /// A fresh folder for one job's results.
    static func make() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Clears folders left by a job that didn't finish (a quit mid-video), off the main thread, and
    /// the empty folder compressing by itself used to keep originals in.
    static func clearLeftovers() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for leftover in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: leftover) }
            let originals = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tutto/Originals")
            if (try? fm.contentsOfDirectory(atPath: originals.path))?.isEmpty == true { try? fm.removeItem(at: originals) }
        }
    }
}
