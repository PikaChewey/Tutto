//
//  ScreenshotNames.swift
//  Tutto
//
//  What a saved screenshot is called: Finder's "Screenshot <date> at <time>" with " 2", " 3" for
//  a name already taken, and a name typed in the save window given the chosen format's extension.
//

import Foundation

public enum ScreenshotNames {
    /// "Screenshot 2026-11-10 at 14.05.16", in the Mac's time zone.
    public static func base(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date))"
    }

    /// The first of "base.ext", "base 2.ext", "base 3.ext"… in `folder` that doesn't exist.
    public static func unique(_ base: String, ext: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    /// Image extensions a typed name may already end with.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// A name from the save window, ending in the chosen format's extension: "notes" → "notes.png",
    /// "notes.jpg" saved as PNG → "notes.png", "v1.2" → "v1.2.png".
    public static func withExtension(_ url: URL, ext: String) -> URL {
        let current = url.pathExtension.lowercased()
        if current == ext.lowercased() || (ext == "jpg" && current == "jpeg") { return url }
        let stem = imageExtensions.contains(current) ? url.deletingPathExtension() : url
        return stem.appendingPathExtension(ext)
    }
}
