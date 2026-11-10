//
//  Hotspot.swift
//  Tutto
//
//  Stay Awake's optional hotspot fallback (off until you turn it on): if the Mac loses its
//  network during a session, it joins your phone's hotspot so agents' requests keep going
//  through. The network is watched only while a session runs with the option on. The password
//  stays in the login keychain and is read without ever showing a dialog (a prompt under a
//  closed lid would wait forever). macOS shows Wi-Fi names only to apps allowed Location
//  Services, so turning the option on asks for it; Tutto never reads your location.
//

import AppKit
import CoreLocation
import CoreWLAN
import LocalAuthentication
import Network
import Observation
import Security
import TuttoKit

// MARK: - Password

enum HotspotKeychain {
    static let service = "ca.bryanyao.Tutto.hotspot"

    static func password(for ssid: String) -> String? {
        let quiet = LAContext()
        quiet.interactionNotAllowed = true  // never a dialog: it may be read under a closed lid
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: quiet,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for ssid: String) -> Bool { password(for: ssid) != nil }

    /// Replaces any saved password for this network. Returns an error to show, or nil.
    static func save(_ password: String, for ssid: String) -> String? {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
        ]
        let data = Data(password.utf8)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tutto hotspot (\(ssid))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
        return nil
    }

    static func delete(for ssid: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: ssid] as CFDictionary)
    }
}

// MARK: - Location (only for Wi-Fi names)

@MainActor
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Mac apps have no "while using": a grant reads as always.
    var isAllowed: Bool { status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    func request() {
        guard status == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}

// MARK: - Watching the network

/// Runs during a session with the option on: watches the network and, after 5 s without one,
/// joins the hotspot, retrying with a growing wait until the network is back.
@MainActor
final class HotspotWatcher {
    /// What happened, for the panel ("Joined Bryan's iPhone").
    var onStatus: ((String) -> Void)?

    private let ssid: String
    private var monitor: NWPathMonitor?
    private var failover = HotspotFailover()
    private var timer: DispatchSourceTimer?
    private var joining = false

    init(ssid: String) { self.ssid = ssid }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        awakeLog.notice("hotspot: watching the network for \(self.ssid, privacy: .private)")
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.cancel()
        timer = nil
        failover = HotspotFailover()
    }

    private func pathChanged(satisfied: Bool) {
        let steps = satisfied ? failover.networkBack(at: Date()) : failover.networkLost(at: Date())
        handle(steps)
    }

    private func handle(_ steps: [HotspotFailover.Step]) {
        for step in steps {
            switch step {
            case .retry(let delay):
                timer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.handle(self.failover.timerFired(at: Date()))
                    }
                }
                timer.resume()
                self.timer = timer
            case .join:
                join()
            case .recovered(let gap):
                timer?.cancel()
                timer = nil
                awakeLog.notice("hotspot: network back after \(Int(gap))s")
            }
        }
    }

    private func join() {
        guard !joining else { return }
        let ssid = ssid
        guard let password = HotspotKeychain.password(for: ssid) else {
            onStatus?("No network, and the hotspot's password couldn't be read. Save it again in Stay Awake.")
            return
        }
        joining = true
        onStatus?("No network: joining \(ssid)…")
        DispatchQueue.global(qos: .utility).async {
            let outcome: String
            if let interface = CWWiFiClient.shared().interface() {
                do {
                    if interface.ssid() == ssid {
                        outcome = "On \(ssid), waiting for it to connect."
                    } else if let network = try interface.scanForNetworks(withSSID: Data(ssid.utf8)).first {
                        try interface.associate(to: network, password: password)
                        outcome = "No network, so Tutto joined \(ssid)."
                    } else {
                        outcome = "No network, and \(ssid) isn't in range. Is the hotspot on?"
                    }
                } catch {
                    outcome = "Couldn't join \(ssid): \(error.localizedDescription)"
                }
            } else {
                outcome = "No Wi-Fi to join \(ssid) with."
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.joining = false
                    awakeLog.notice("hotspot: \(outcome, privacy: .private)")
                    self.onStatus?(outcome)
                }
            }
        }
    }
}
