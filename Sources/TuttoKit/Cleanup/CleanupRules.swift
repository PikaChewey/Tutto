//
//  CleanupRules.swift
//  Tutto
//
//  The judgement behind Clean Up, kept apart from the file system so it can be tested: what
//  name in ~/Library belongs to which app, whether that app is still here, which paths are
//  safe to move to the Trash at all, and which developer caches rebuild themselves.
//
//  The rules lean safe, as good cleaners do: anything Apple's is never touched, a cache whose
//  app is running is left (deleting an open database can make the app loop writing to it), a
//  name that matches an installed app (or its helper, or its vendor) is that app's, and a path
//  that leaves the folder being cleaned, through ".." or a link, is refused.
//

import Foundation

public enum CleanupCategory: String, CaseIterable, Codable, Sendable {
    /// Left behind by an app that's no longer installed.
    case leftover
    /// Named for no installed app and looks like an app's data, but isn't a bundle ID: listed, not ticked.
    case probableLeftover
    case cache
    case log
    case developer

    public var title: String {
        switch self {
        case .leftover: "Left behind by removed apps"
        case .probableLeftover: "Probably left behind"
        case .cache: "Caches"
        case .log: "Logs"
        case .developer: "Developer caches"
        }
    }

    /// Ticked when found: everything but the guesses and the caches that take time to rebuild.
    public var selectedByDefault: Bool {
        switch self {
        case .leftover, .cache, .log: true
        case .probableLeftover, .developer: false
        }
    }
}

public enum CleanupRules {
    // MARK: Bundle IDs

    /// The bundle ID a name in ~/Library stands for, if it's one: "com.foo.Bar.plist" →
    /// "com.foo.Bar"; "group.com.foo.shared" → "com.foo.shared"; "ABCDE12345.com.foo" → "com.foo".
    public static func bundleID(fromName name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies", ".lockfile", ".lock"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        // A team ID prefix first ("3TH5R7YS88.group.com.vendor.app"), then "group." or "groups.".
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }), parts.count >= 3 {
            id = parts.dropFirst().joined(separator: ".")
        }
        for prefix in ["groups.", "group."] where id.hasPrefix(prefix) { id = String(id.dropFirst(prefix.count)) }
        let pieces = id.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 3, pieces.allSatisfy({ !$0.isEmpty }),
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
              let top = pieces.first, top.count >= 2, top.count <= 10, top.allSatisfy({ $0.isLowercase || $0.isNumber })
        else { return nil }
        return id
    }

    /// Apple's own, which Clean Up never touches: com.apple.* names, and the folders macOS keeps
    /// under plain names (Maps' GeoServices, CloudKit…).
    public static func isApple(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("com.apple.") || lower == "com.apple" || lower.hasPrefix("apple.") || appleNames.contains(lower)
            || systemVendors.contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    /// Parts of macOS that use their own IDs: Shortcuts kept its maker's ("is.workflow"), printing is CUPS.
    static let systemVendors = ["is.workflow", "org.cups", "com.openssh", "org.openssh"]

    static let appleNames: Set<String> = [
        "geoservices", "cloudkit", "familycircle", "passkit", "metadata", "siritts", "amsdatamigratortool", "fontregistry",
        "familycircled", "storeassetd", "nsurlsessiond", "quicklook", "privateframeworks", "diagnosticreports", "crashreporter",
        "coresimulator", "photosupgrade.aapbz", "photossearch.aapbz", "spotlight", "assistant", "duetexpertcenter",
        "askpermissiond", "jetpackcache", "animoji", "mbuseragent", "appstore", "softwareupdate", "icloudmailagent",
    ]

    // MARK: Leftovers

    /// Where apps keep things that rebuild by themselves; a leftover only there is safe to tick.
    public static let disposablePlaces: Set<String> = ["Caches", "Logs", "HTTPStorages", "Saved Application State", "WebKit"]

    /// File names that look like sign-in data (a command-line tool's login, an app's tokens).
    public static func looksLikeSignIn(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return ["auth", "token", "credential", "secret", "login data", "password", "keychain", ".pem", ".key", ".netrc", "id_rsa", "session"]
            .contains { lower.contains($0) }
    }

    /// Whether a removed app's leftovers start ticked: always when they're only caches and the
    /// like; when they include its data (settings, documents, sign-ins), only if nothing there has
    /// changed for a month and none of it looks like sign-in data. Anything else is listed, unticked.
    public static func suggestsRemoving(places: Set<String>, lastChange: Date?, hasSignIn: Bool, now: Date = Date()) -> Bool {
        if places.isSubset(of: disposablePlaces) { return true }
        guard !hasSignIn, let lastChange else { return false }
        return now.timeIntervalSince(lastChange) > staleAge
    }

    /// The vendor part of a bundle ID ("com.roblox" for "com.Roblox.RobloxStudio").
    public static func vendor(of id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Whether an installed (or running) app could be using this ID. Leaning safe, as a cleaner
    /// must: anything from a vendor with an app still here counts ("com.google.Keystone" while
    /// "com.google.Chrome" is installed is Chrome's updater, not a leftover). Only an ID whose
    /// vendor has nothing left on this Mac is "left behind".
    public static func isOwned(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if installed.contains(lower) { return true }
        let parts = lower.split(separator: ".")
        guard parts.count >= 2 else { return true }
        let vendor = parts.prefix(2).joined(separator: ".")
        return installed.contains { $0 == vendor || $0.hasPrefix(vendor + ".") }
    }

    /// Lower-cased IDs, as the installed set is kept.
    public static func normalized(_ ids: some Sequence<String>) -> Set<String> {
        Set(ids.map { $0.lowercased() })
    }

    // MARK: Paths

    /// Whether `path` may be moved to the Trash as part of cleaning `root`: absolute, plain (no
    /// "..", ".", control characters), strictly inside the root even after resolving links, and
    /// not one of the places that must never go.
    public static func isSafeToRemove(_ path: String, root: String, resolved: String? = nil) -> Bool {
        guard path.hasPrefix("/"), root.hasPrefix("/"), path != root else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(rootWithSlash) else { return false }
        if let resolved {
            guard resolved.hasPrefix(rootWithSlash) || resolved.hasPrefix(resolvedRoot(rootWithSlash)) else { return false }
        }
        return !protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// /var and /tmp resolve through /private.
    private static func resolvedRoot(_ root: String) -> String {
        root.hasPrefix("/private/") ? root : "/private" + root
    }

    /// Never moved, whatever a scan finds.
    static let protected: [String] = ["/", "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/private", "/Library", "/Applications"]

    /// Folders in Application Support that are never "probably left behind", whatever their name:
    /// macOS's own, device backups, and vendors' shared folders.
    public static let neverProbable: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter", "dock", "filesystemui",
        "icdd", "knowledge", "mobilesync", "networkserviceproxy", "quick look", "syncservices", "ubiquity", "accounts",
        "animoji", "app store", "com.apple.sharedfilelist", "contacts", "facetime", "fileprovider", "homeenergyd",
        "icloud", "managedclient", "messages", "photos", "safari", "siri", "tipsd", "videoconference", "dmd",
        "google", "microsoft", "adobe", "jetbrains", "steam", "mozilla", "firefox", "chrome", "zoom.us", "tutto",
    ]

    /// Markers inside a folder that make it look like an app's data store (Electron and
    /// Chromium apps leave these, often hundreds of megabytes).
    public static let appDataMarkers: Set<String> = ["Cache", "Code Cache", "GPUCache", "Local Storage", "IndexedDB",
                                                     "Session Storage", "blob_storage", "Preferences", "Service Worker"]

    // MARK: Developer caches

    public struct DeveloperCache: Sendable {
        /// From the home folder.
        public let path: String
        public let title: String
        public let note: String
    }

    /// Caches that tools rebuild by themselves, at the cost of time (so they start unticked).
    public static let developerCaches: [DeveloperCache] = [
        DeveloperCache(path: "Library/Developer/Xcode/DerivedData", title: "Xcode DerivedData", note: "Build products; rebuilt on the next build"),
        DeveloperCache(path: "Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device support", note: "Symbols for devices you've connected; fetched again when needed"),
        DeveloperCache(path: "Library/Developer/CoreSimulator/Caches", title: "Simulator caches", note: "Rebuilt when a simulator starts"),
        DeveloperCache(path: "Library/Caches/com.apple.dt.Xcode", title: "Xcode caches", note: "Rebuilt by Xcode"),
        DeveloperCache(path: ".npm/_cacache", title: "npm cache", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/Caches/Yarn", title: "Yarn cache", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/pnpm/store", title: "pnpm store", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/Caches/pip", title: "pip cache", note: "Packages download again when needed"),
        DeveloperCache(path: ".cache/uv", title: "uv cache", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/Caches/Homebrew", title: "Homebrew downloads", note: "Old bottles and downloads"),
        DeveloperCache(path: "Library/Caches/ms-playwright", title: "Playwright browsers", note: "Downloaded again by `playwright install`"),
        DeveloperCache(path: "Library/Caches/Cypress", title: "Cypress binaries", note: "Downloaded again on the next install"),
        DeveloperCache(path: ".gradle/caches", title: "Gradle caches", note: "Rebuilt on the next build"),
        DeveloperCache(path: "Library/Caches/CocoaPods", title: "CocoaPods cache", note: "Downloaded again when needed"),
        DeveloperCache(path: ".cargo/registry/cache", title: "Cargo downloads", note: "Crates download again when needed"),
        DeveloperCache(path: "go/pkg/mod/cache", title: "Go module cache", note: "Modules download again when needed"),
        DeveloperCache(path: "Library/Caches/go-build", title: "Go build cache", note: "Rebuilt on the next build"),
        DeveloperCache(path: "Library/Caches/org.swift.swiftpm", title: "Swift package cache", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/Caches/pnpm", title: "pnpm cache", note: "Packages download again when needed"),
        DeveloperCache(path: "Library/Caches/node-gyp", title: "node-gyp headers", note: "Downloaded again when a native module builds"),
        DeveloperCache(path: "Library/Caches/electron", title: "Electron downloads", note: "Downloaded again on the next install"),
        DeveloperCache(path: "Library/Caches/typescript", title: "TypeScript cache", note: "Rebuilt by the editor"),
    ]

    /// Whether a path in ~/Library/Caches is one of the developer caches (listed there instead).
    public static func isDeveloperCache(_ relativePath: String) -> Bool {
        developerCaches.contains { relativePath == $0.path || relativePath.hasPrefix($0.path + "/") }
    }

    // MARK: Time

    /// A cache touched more recently than this is in use: left alone.
    public static let busyCacheAge: TimeInterval = 120
    /// A log written more recently than this is being written: left alone.
    public static let busyLogAge: TimeInterval = 600
    /// A folder named for no installed app counts as "probably left behind" once untouched this long.
    public static let staleAge: TimeInterval = 30 * 24 * 3600
}
