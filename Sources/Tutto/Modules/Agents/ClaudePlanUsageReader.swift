//
//  ClaudePlanUsageReader.swift
//  Tutto
//
//  Asks Claude for its limits (TuttoKit's ClaudePlanUsage), with Claude Code's own sign-in, read
//  through `/usr/bin/security` as Claude Code itself reads it (so macOS doesn't ask about Tutto).
//  The token never leaves memory except to api.anthropic.com, and is never logged. Only while the
//  Agents card or page is on screen, at most every few minutes; a "too many requests" waits as
//  long as Claude says (5 minutes if it doesn't). An expired sign-in is renewed only when
//  `renews` is on, and the renewed one goes back into Claude Code's Keychain item, so Claude Code
//  and Tutto keep using one sign-in.
//

import Foundation
import os
import TuttoKit

final class ClaudePlanUsageReader: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case unknown
        case reading
        /// Claude Code isn't signed in on this Mac (no Claude sign-in in the Keychain).
        case noSignIn
        /// The sign-in has run out (Claude Code renews it when it runs).
        case signInExpired
        /// The sign-in has run out and has nothing to renew it with: only `claude /login` brings it back.
        case needsLogin
        /// Claude said to wait.
        case waiting(until: Date)
        case failed
        case ok
    }

    static let service = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client (as the usage apps use it).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let interval: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "ca.bryanyao.Tutto.claude-plan-usage", qos: .utility)
    private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "agents")
    private var busy = false
    private var blockedUntil = Date.distantPast
    private var lastAsked = Date.distantPast
    /// Renew an expired sign-in (and write it back for Claude Code).
    var renews = false

    /// On the main queue: each reading (nil when there's none) and the status.
    var onResult: (@MainActor (ClaudePlanUsage?, Status) -> Void)?

    /// Asks now unless it asked less than `interval` ago (`force`: a click on Refresh).
    func read(force: Bool = false) {
        queue.async { [self] in
            let now = Date()
            guard !busy else { return }
            if now < blockedUntil { return publish(nil, .waiting(until: blockedUntil)) }
            if !force, now.timeIntervalSince(lastAsked) < Self.interval { return }
            busy = true
            lastAsked = now
            defer { busy = false }
            let (usage, status) = fetch(now: now)
            publish(usage, status)
        }
    }

    private func publish(_ usage: ClaudePlanUsage?, _ status: Status) {
        DispatchQueue.main.async { [onResult] in MainActor.assumeIsolated { onResult?(usage, status) } }
    }

    private func fetch(now: Date) -> (ClaudePlanUsage?, Status) {
        guard let data = Self.keychainPassword(), var signIn = ClaudeSignIn(json: data), signIn.canReadUsage else {
            return (nil, .noSignIn)
        }
        if signIn.isExpired(now: now) {
            if signIn.refreshToken == nil { return (nil, .needsLogin) }
            guard renews, let renewed = renew(signIn, now: now) else { return (nil, .signInExpired) }
            signIn = renewed
        }
        switch get(Self.usageURL, token: signIn.accessToken) {
        case .ok(let body):
            guard let usage = ClaudePlanUsage(json: body, at: now) else { return (nil, .failed) }
            return (usage, .ok)
        case .status(401, _):
            // Taken back or run out early: renew once, if allowed.
            guard signIn.refreshToken != nil else { return (nil, .needsLogin) }
            guard renews, let renewed = renew(signIn, now: now), case .ok(let body) = get(Self.usageURL, token: renewed.accessToken),
                  let usage = ClaudePlanUsage(json: body, at: now) else { return (nil, .signInExpired) }
            return (usage, .ok)
        case .status(429, let retryAfter):
            blockedUntil = now.addingTimeInterval(retryAfter ?? 5 * 60)
            return (nil, .waiting(until: blockedUntil))
        case .status(let code, _):
            log.notice("Claude usage: HTTP \(code)")
            return (nil, .failed)
        case .failed:
            return (nil, .failed)
        }
    }

    // MARK: HTTP

    private enum Reply { case ok(Data), status(Int, TimeInterval?), failed }

    private func get(_ url: URL, token: String) -> Reply {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tutto", forHTTPHeaderField: "User-Agent")
        return send(request)
    }

    private func send(_ request: URLRequest) -> Reply {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = Reply.failed
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { body, response, _ in
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode), let body {
                    reply = .ok(body)
                } else {
                    let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                    reply = .status(http.statusCode, retry)
                }
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        session.finishTasksAndInvalidate()
        return reply
    }

    // MARK: Renewing the sign-in

    private func renew(_ signIn: ClaudeSignIn, now: Date) -> ClaudeSignIn? {
        guard let refreshToken = signIn.refreshToken else { return nil }
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: refreshToken),
                           URLQueryItem(name: "client_id", value: Self.clientID)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        guard case .ok(let body) = send(request),
              let reply = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = reply["access_token"] as? String else {
            log.notice("Claude usage: the sign-in couldn't be renewed")
            return nil
        }
        let expiresIn = (reply["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        guard let item = signIn.renewed(accessToken: access, refreshToken: reply["refresh_token"] as? String, expiresIn: expiresIn, now: now),
              let renewed = ClaudeSignIn(json: item) else { return nil }
        // Back where Claude Code reads it: a refresh token used here may no longer work for it.
        if !Self.writeKeychainPassword(item) { log.notice("Claude usage: the renewed sign-in couldn't be saved") }
        return renewed
    }

    // MARK: Keychain, through /usr/bin/security

    static func keychainPassword() -> Data? {
        guard let output = run(["find-generic-password", "-s", service, "-w"]), !output.isEmpty else { return nil }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(text.utf8)
    }

    /// The account the item is kept under (`acct`), to write it back to the same item.
    static func keychainAccount() -> String? {
        guard let output = run(["find-generic-password", "-s", service]) else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"acct\"") }),
              let start = line.range(of: "=\"")?.upperBound, let end = line.lastIndex(of: "\""), start < end else { return nil }
        return String(line[start..<end])
    }

    /// Written through `security -i` on standard input, as hex: the secret never appears in a
    /// command line other processes can read.
    static func writeKeychainPassword(_ data: Data) -> Bool {
        guard let account = keychainAccount(), !account.contains("\""), !account.contains("\n") else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        return run(["-i"], input: Data(command.utf8)) != nil
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe }
        do { try process.run() } catch { return nil }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
