//
//  AudioProcesses.swift
//  Tutto
//
//  Which processes Core Audio knows about, and which app each one belongs to.
//
//  Apps rarely play sound from their own process: Discord plays through
//  "Discord Helper (Renderer)", Opera GX through "Opera Helper" (bundle ID
//  com.operasoftware.Opera.helper, not even the app's prefix), Safari through
//  WebKit's GPU service, Firefox through a content process. So a sound process is
//  matched to its app by, in order: macOS's own "responsible process" record (covers
//  XPC services), the executable living inside the app's bundle, then the parent chain.
//  A process that matches nothing belongs to no app and is never muted.
//

import CoreAudio
import Darwin
import Foundation

public struct AudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// The process has an output stream running (it may still be sending silence).
    public let isRunningOutput: Bool
}

public enum AudioProcessList {
    /// Every process Core Audio has an object for. Cheap: a handful of property reads.
    public static func read() -> [AudioProcess] {
        objectIDs().compactMap { id in
            guard let pid: pid_t = property(id, kAudioProcessPropertyPID) else { return nil }
            var bundle: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let bundleID: String?
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &bundle) == noErr, let bundle {
                let text = bundle.takeRetainedValue() as String
                bundleID = text.isEmpty ? nil : text
            } else {
                bundleID = nil
            }
            let running: UInt32 = property(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    /// Only the "is it producing output" flag, for a live indicator.
    public static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        let running: UInt32 = property(id, kAudioProcessPropertyIsRunningOutput) ?? 0
        return running != 0
    }

    static func objectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}

// MARK: - Ownership

public enum AudioOwnership {
    public struct App: Equatable, Sendable {
        public let pid: pid_t
        public let bundleID: String
        /// e.g. "/Applications/Discord.app"
        public let bundlePath: String

        public init(pid: pid_t, bundleID: String, bundlePath: String) {
            self.pid = pid
            self.bundleID = bundleID
            self.bundlePath = bundlePath
        }
    }

    /// Lookups the matcher needs from the system, injectable for tests.
    public struct System: Sendable {
        public var responsible: @Sendable (pid_t) -> pid_t?
        public var path: @Sendable (pid_t) -> String?
        public var parent: @Sendable (pid_t) -> pid_t?

        public init(responsible: @escaping @Sendable (pid_t) -> pid_t?, path: @escaping @Sendable (pid_t) -> String?,
                    parent: @escaping @Sendable (pid_t) -> pid_t?) {
            self.responsible = responsible
            self.path = path
            self.parent = parent
        }

        public static let live = System(responsible: ProcessInfoLookup.responsiblePID,
                                        path: ProcessInfoLookup.executablePath,
                                        parent: ProcessInfoLookup.parentPID)
    }

    /// The app a sound-making process belongs to, or nil.
    public static func owner(of pid: pid_t, among apps: [App], system: System = .live) -> App? {
        if let app = apps.first(where: { $0.pid == pid }) { return app }
        if let responsible = system.responsible(pid), responsible != pid,
           let app = apps.first(where: { $0.pid == responsible }) {
            return app
        }
        if let path = system.path(pid) {
            // Longest bundle path wins, so an app nested in another app's bundle is told apart.
            let containing = apps.filter { !$0.bundlePath.isEmpty && path.hasPrefix($0.bundlePath + "/") }
            if let app = containing.max(by: { $0.bundlePath.count < $1.bundlePath.count }) { return app }
        }
        var current = pid
        for _ in 0..<8 {
            guard let parent = system.parent(current), parent > 1, parent != current else { break }
            if let app = apps.first(where: { $0.pid == parent }) { return app }
            current = parent
        }
        return nil
    }
}

/// Process facts from the kernel. All unprivileged.
public enum ProcessInfoLookup {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// macOS records which app is "responsible" for each process (the one privacy prompts name).
    /// Not in the public headers, so it's looked up at runtime; nil if it ever disappears.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    @Sendable public static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let result = responsibleFunction(pid)
        return result > 0 ? result : nil
    }

    @Sendable public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    @Sendable public static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
