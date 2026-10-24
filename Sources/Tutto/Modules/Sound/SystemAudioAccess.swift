//
//  SystemAudioAccess.swift
//  Tutto
//
//  "System Audio Recording" (Privacy & Security › Screen & System Audio Recording) is
//  what lets Tutto put a tap on another app's sound, which is how muting works. macOS has
//  no public call to check or request it, so this uses the privacy framework's own
//  functions, looked up at runtime. If they ever go away the status reads "unknown" and
//  creating the tap asks macOS instead.
//

import Foundation

enum SystemAudioAccess {
    enum Status: Equatable { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's prompt the first time; later calls answer straight away.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in completion(granted) }
    }
}
