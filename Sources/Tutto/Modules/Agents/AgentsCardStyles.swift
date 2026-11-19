//
//  AgentsCardStyles.swift
//  Tutto
//
//  Design options for the Agents card, so one can be picked from pictures:
//  Tiles (limits as two tiles like CPU and Memory, sessions under), Inbox (sessions first, two
//  lines each, a slim meter per agent), Rings (two gauges and counts, only what's active listed),
//  Avatars (sessions as icons like the Sound card, names on hover, two meters side by side).
//  Every one draws a percent the way the rest of the panel does: a figure with a small "%" right
//  against it, and an estimate marked "est." instead of "≈".
//

import AppKit
import SwiftUI
import TuttoKit

enum AgentsStyle: String, CaseIterable {
    case current, tiles, inbox, rings, avatars

    static let key = "agents.cardStyle"
    nonisolated(unsafe) static var override: AgentsStyle?

    static var chosen: AgentsStyle {
        override ?? UserDefaults.standard.string(forKey: key).flatMap(AgentsStyle.init(rawValue:)) ?? .current
    }
}

// MARK: - Pieces every option shares

/// "66%" with the sign small and close, as the CPU and battery figures are.
struct PercentFigure: View {
    var value: Double
    var size: CGFloat
    var color: Color = .ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            Text("\(Int(value.rounded()))")
                .font(.figure(size, weight: .medium))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text("%")
                .font(.system(size: (size * 0.55).rounded(), weight: .medium))
                .foregroundStyle(Color.ink3)
        }
        .fixedSize()
    }
}

extension LimitEstimate {
    var urgent: Bool { reached || limitAt != nil || percent >= 85 }

    /// How far through its window we are (0…1): where an even pace would have the bar.
    func elapsed(now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let length: Double = window == .fiveHour ? 5 * 3600 : 7 * 86_400
        return min(max(1 - resetsAt.timeIntervalSince(now) / length, 0), 1)
    }

    var windowName: String { window == .fiveHour ? "5 hours" : "This week" }
    var shortWindow: String { window == .fiveHour ? "5 h" : "Week" }

    /// "Resets in 2 h 30 min", "Resets Sat 10 AM", "Out in 45 min", "Back in 3 h": a countdown
    /// within the day, a weekday and time past it.
    func when(now: Date) -> String {
        func at(_ date: Date) -> String {
            date.timeIntervalSince(now) < 20 * 3600 ? "in \(AgentText.age(since: now, now: date))" : AgentText.clock(date, now: now)
        }
        if reached { return resetsAt.map { "Back \(at($0))" } ?? "Reached" }
        if let limitAt { return "Out \(at(limitAt))" }
        return resetsAt.map { "Resets \(at($0))" } ?? ""
    }
}

/// A thin bar with a tick where an even pace would be: past the tick, you're using it faster than
/// the window allows.
struct PaceBar: View {
    var estimate: LimitEstimate
    var now: Date
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.1))
                Capsule()
                    .fill(estimate.urgent ? Color.themeAccent : Color.ink.opacity(0.75))
                    .frame(width: max(width * min(estimate.percent, 100) / 100, estimate.percent > 0 ? height : 0))
                if let elapsed = estimate.elapsed(now: now), elapsed > 0.02, elapsed < 0.98 {
                    Capsule()
                        .fill(Color.ink2)
                        .frame(width: 1.5, height: height + 5)
                        .offset(x: width * elapsed - 0.75)
                }
            }
        }
        .frame(height: height)
        .animation(Motion.snappy, value: estimate.percent)
        .accessibilityHidden(true)
    }
}

/// A ring with the percent inside and a dot where an even pace would be.
struct LimitRing: View {
    var estimate: LimitEstimate
    var now: Date
    var size: CGFloat = 56
    var line: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Color.ink.opacity(0.1), lineWidth: line)
            Circle()
                .trim(from: 0, to: min(estimate.percent, 100) / 100)
                .stroke(estimate.urgent ? Color.themeAccent : Color.ink.opacity(0.8),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let elapsed = estimate.elapsed(now: now), elapsed > 0.02, elapsed < 0.98 {
                Circle()
                    .fill(Color.ink2)
                    .frame(width: 3, height: 3)
                    .offset(y: -(size / 2) + line / 2)
                    .rotationEffect(.degrees(elapsed * 360))
            }
            PercentFigure(value: estimate.percent, size: size * 0.3, color: estimate.urgent ? .themeAccent : .ink)
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: estimate.percent)
    }
}

/// Claude's or Codex's own icon (the app's, when it's installed).
struct ToolIcon: View {
    var tool: AgentTool
    var size: CGFloat = 14

    @MainActor private static var cache: [AgentTool: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.icon(tool) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: tool == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                    .resizable().scaledToFit().foregroundStyle(Color.ink3).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @MainActor static func icon(_ tool: AgentTool) -> NSImage? {
        if let image = cache[tool] { return image }
        let id = tool == .claude ? AgentsModule.claudeAppID : AgentsModule.codexAppID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[tool] = image
        return image
    }
}

/// The app a session is in, with its state in a small badge.
struct SessionAvatar: View {
    var agents: AgentsModule
    var session: AgentSession
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = agents.hostIcon(session) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                ToolIcon(tool: session.tool, size: size)
            }
        }
        .frame(width: size, height: size)
        .opacity(session.activity == .yourTurn ? 0.6 : 1)
        .saturation(session.activity == .yourTurn ? 0.4 : 1)
        .overlay(alignment: .bottomTrailing) {
            AgentMark(activity: session.activity)
                .scaleEffect(size >= 24 ? 0.85 : 0.7)
                .background(Circle().fill(Color.paper).frame(width: size >= 24 ? 13 : 11, height: size >= 24 ? 13 : 11))
                .offset(x: size >= 24 ? 4 : 3, y: size >= 24 ? 4 : 3)
        }
        .accessibilityHidden(true)
    }
}

/// What a session is doing, short: a tinted pill when it needs you, otherwise quiet text.
struct SessionStatus: View {
    var agents: AgentsModule
    var session: AgentSession
    var hovering: Bool

    private var load: AgentLoad? { session.pid.flatMap { agents.loads[$0] } }

    var body: some View {
        let age = AgentText.age(since: session.since, now: agents.now)
        Group {
            if hovering, let load {
                Text(AgentText.cost(load))
                    .foregroundStyle(Color.ink2)
            } else {
                switch session.activity {
                case .needsYou:
                    Text("Waiting \(age)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.themeAccent)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.themeAccent.opacity(0.14)))
                case .working:
                    if let quiet = agents.quiet(session) {
                        Text("Quiet \(AgentText.age(since: agents.now.addingTimeInterval(-quiet), now: agents.now))")
                            .foregroundStyle(Color.ink2)
                    } else {
                        Text(age).foregroundStyle(Color.ink3)
                    }
                case .yourTurn:
                    Text("Done · \(age)").foregroundStyle(Color.ink3)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// One session: its app, its name (and where, on two-line rows), its state. A click opens it; under
/// the pointer it shows its cost and a stop button that asks first.
struct AgentSessionRow: View {
    @Bindable var agents: AgentsModule
    var session: AgentSession
    @Binding var confirming: String?
    var placeholder: Bool
    var twoLines = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            if confirming == session.id {
                Text("Stop \u{201C}\(session.name)\u{201D}?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                QuietLink(title: "Keep", size: 11.5) { confirming = nil }
                Button("Stop") {
                    agents.stop(session)
                    confirming = nil
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            } else {
                SessionAvatar(agents: agents, session: session, size: twoLines ? 22 : 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12.5, weight: session.activity.needsYou ? .semibold : .medium))
                        .foregroundStyle(session.activity == .yourTurn ? Color.ink2 : Color.ink)
                        .lineLimit(1)
                    if twoLines {
                        Text(place)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                SessionStatus(agents: agents, session: session, hovering: hovering && !placeholder)
                if hovering, !placeholder, session.pid != nil, session.tool == .claude {
                    Button {
                        confirming = session.id
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.ink2)
                            .lensHover(cornerRadius: 7, x: 2, y: 2, swell: Motion.iconSwell)
                    }
                    .buttonStyle(PressStyle())
                    .help("Stop this session: its process quits; the conversation is kept")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: twoLines ? 36 : 26)
        .hoverBackground(hovering && confirming != session.id, x: 0)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.micro) { hovering = inside } }
        .onTapGesture {
            guard !placeholder, confirming != session.id else { return }
            afterPanelCloses { agents.show(session) }
        }
        .opacity(session.pid.map { agents.stopping.contains($0) } == true ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(AgentText.state(session.activity))")
        .accessibilityHint("Opens the session")
        .accessibilityAddTraits(.isButton)
    }

    private var place: String {
        let host = session.host == .claudeApp ? "Claude app" : session.host == .codexApp ? "Codex app" : "Terminal"
        return "\(host) · \(AgentSession.displayFolder(session.folder))"
    }
}

// MARK: - The options

extension AgentsCard {
    private var visibleRows: Int { 4 }

    @ViewBuilder
    private func moreLink(shown: Int) -> some View {
        if agents.sessions.count > shown {
            QuietLink(title: "\(agents.sessions.count - shown) more", size: 11.5) { showInApp(.agents) }
        }
    }

    private var header: some View {
        CardTitle(title: "Agents") {
            QuietLink(title: summary) { showInApp(.agents) }
                .help("Open Agents in Tutto")
        }
    }

    @ViewBuilder
    private var emptyLine: some View {
        if agents.sessions.isEmpty {
            Text("No agents running")
                .font(.system(size: 12))
                .foregroundStyle(Color.ink3)
        }
    }

    @ViewBuilder
    private var footers: some View {
        if !agents.runaway.isEmpty { runawayLine }
        if !agents.leftRunning.isEmpty { leftoversLine }
    }

    private func rows(_ sessions: some Collection<AgentSession>, twoLines: Bool = false) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(sessions)) { session in
                AgentSessionRow(agents: agents, session: session, confirming: $confirming, placeholder: placeholder, twoLines: twoLines)
            }
        }
        .padding(.horizontal, -6)
    }

    // A — Tiles: each agent's limit as a tile like CPU and Memory; sessions under.
    var tilesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !agents.limits.isEmpty {
                HStack(spacing: 8) {
                    ForEach(agents.limits, id: \.tool) { limits in
                        if let estimate = limits.headline { LimitTile(limits: limits, estimate: estimate, now: agents.now) }
                    }
                }
            }
            emptyLine
            if !agents.sessions.isEmpty {
                rows(agents.sessions.prefix(visibleRows))
                moreLink(shown: visibleRows).padding(.top, -6)
            }
            footers
        }
    }

    // B — Inbox: sessions first, with where each one is; a slim meter per agent at the foot.
    var inboxContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            emptyLine
            if !agents.sessions.isEmpty {
                rows(agents.sessions.prefix(visibleRows), twoLines: true)
                moreLink(shown: visibleRows).padding(.top, -4)
            }
            footers
            if !agents.limits.isEmpty {
                Hairline().opacity(0.6)
                VStack(spacing: 7) {
                    ForEach(agents.limits, id: \.tool) { limits in
                        if let estimate = limits.headline { MeterLine(limits: limits, estimate: estimate, now: agents.now) }
                    }
                }
            }
        }
    }

    // C — Rings: two gauges and the counts; only what needs you or is working is listed.
    var ringsContent: some View {
        let active = agents.sessions.filter { $0.activity != .yourTurn }
        return VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 14) {
                ForEach(agents.limits, id: \.tool) { limits in
                    if let estimate = limits.headline {
                        VStack(spacing: 5) {
                            LimitRing(estimate: estimate, now: agents.now)
                            HStack(spacing: 4) {
                                ToolIcon(tool: limits.tool, size: 11)
                                Text(limits.tool.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink2)
                            }
                            Text("\(estimate.shortWindow)\(estimate.exact ? "" : " · est.")")
                                .font(.system(size: 10)).foregroundStyle(Color.ink3)
                        }
                        .help(AgentText.limitsHelp(limits, now: agents.now))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(limits.tool.name) limit")
                        .accessibilityValue("\(Int(estimate.percent.rounded())) percent, \(estimate.when(now: agents.now))")
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    CountLine(count: agents.needsYou.count, label: "need you", accent: true)
                    CountLine(count: agents.sessions.filter { $0.activity == .working }.count, label: "working")
                    CountLine(count: agents.sessions.filter { $0.activity == .yourTurn }.count, label: "done")
                }
                .padding(.top, 4)
            }
            if !active.isEmpty {
                rows(active.prefix(3))
                if active.count > 3 { moreLink(shown: 3).padding(.top, -6) }
            } else {
                emptyLine
            }
            footers
        }
    }

    // D — Avatars: sessions as icons like the Sound card, the name over the one under the pointer;
    // two small meters side by side.
    var avatarsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            emptyLine
            if !agents.sessions.isEmpty { AvatarStrip(agents: agents, placeholder: placeholder) }
            footers
            if !agents.limits.isEmpty {
                HStack(spacing: 8) {
                    ForEach(agents.limits, id: \.tool) { limits in
                        if let estimate = limits.headline { MiniMeter(limits: limits, estimate: estimate, now: agents.now) }
                    }
                }
            }
        }
    }
}

// MARK: - Option parts

/// A — an agent's limit as a small tile.
private struct LimitTile: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ToolIcon(tool: limits.tool, size: 13)
                Text(limits.tool.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 2)
                Text(estimate.shortWindow + (estimate.exact ? "" : " est."))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            PercentFigure(value: estimate.percent, size: 22, color: estimate.urgent ? .themeAccent : .ink)
            PaceBar(estimate: estimate, now: now, height: 4)
            Text(estimate.when(now: now))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(estimate.urgent ? Color.themeAccent : Color.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous).fill(Color.ink.opacity(0.055)))
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.tool.name) limit")
        .accessibilityValue("\(Int(estimate.percent.rounded())) percent of \(estimate.windowName.lowercased()), \(estimate.when(now: now))")
    }
}

/// B — one slim line per agent; under the pointer the figure gives way to when it resets.
private struct MeterLine: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ToolIcon(tool: limits.tool, size: 13)
            Text(limits.tool.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 42, alignment: .leading)
            PaceBar(estimate: estimate, now: now, height: 4)
            ZStack(alignment: .trailing) {
                Text(estimate.when(now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(estimate.urgent ? Color.themeAccent : Color.ink2)
                    .opacity(hovering ? 1 : 0)
                HStack(spacing: 4) {
                    Text(estimate.shortWindow + (estimate.exact ? "" : " est."))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ink3)
                    PercentFigure(value: estimate.percent, size: 14, color: estimate.urgent ? .themeAccent : .ink)
                }
                .opacity(hovering ? 0 : 1)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.micro) { hovering = inside } }
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.tool.name) limit")
        .accessibilityValue("\(Int(estimate.percent.rounded())) percent, \(estimate.when(now: now))")
    }
}

/// C — "2 working" with the number as a figure.
private struct CountLine: View {
    var count: Int
    var label: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(count)")
                .font(.figure(15, weight: .semibold))
                .foregroundStyle(accent && count > 0 ? Color.themeAccent : (count > 0 ? Color.ink : Color.ink3))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(accent && count > 0 ? Color.themeAccent : Color.ink3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// D — the sessions as icons; the one under the pointer says its name and state above it.
private struct AvatarStrip: View {
    var agents: AgentsModule
    var placeholder: Bool
    @State private var hovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pitch: CGFloat = 36
    private static let capacity = 7

    var body: some View {
        let shown = Array(agents.sessions.prefix(Self.capacity))
        HStack(spacing: 0) {
            ForEach(shown) { session in
                Button {
                    guard !placeholder else { return }
                    afterPanelCloses { agents.show(session) }
                } label: {
                    SessionAvatar(agents: agents, session: session, size: 28)
                        .frame(width: 32, height: 32)
                        .lensHover(cornerRadius: 9, x: 2, y: 2, swell: Motion.iconSwell, stageKey: session.id,
                                   hovering: { inside in
                                       if inside { hovered = session.id } else if hovered == session.id { hovered = nil }
                                   })
                }
                .buttonStyle(PressStyle())
                .frame(width: Self.pitch, alignment: .leading)
                .accessibilityLabel("\(session.name), \(AgentText.state(session.activity))")
                .accessibilityHint("Opens the session")
            }
            if agents.sessions.count > Self.capacity {
                QuietLink(title: "+\(agents.sessions.count - Self.capacity)", size: 12) { showInApp(.agents) }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topLeading) {
            let id = hovered ?? shown.first { LensStage.on($0.id) }?.id
            if let id, let index = shown.firstIndex(where: { $0.id == id }) {
                let session = shown[index]
                CenteredOver(center: CGFloat(index) * Self.pitch + 16) {
                    HStack(spacing: 5) {
                        Text(session.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink)
                        Text(state(session))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(session.activity.needsYou ? Color.themeAccent : Color.ink3)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .modifier(ToolLabelSurface())
                }
                .offset(y: -29)
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: id)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                .allowsHitTesting(false)
            }
        }
        .padding(.leading, -3)
        .zIndex(1)
        // Under the icons, the one that needs you, in words (it's the reason to look).
        .overlay(alignment: .bottomLeading) { EmptyView() }
        if let first = agents.needsYou.first {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.themeAccent)
                Text(first.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("waiting \(AgentText.age(since: first.since, now: agents.now))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.themeAccent)
            }
        }
    }

    private func state(_ session: AgentSession) -> String {
        let age = AgentText.age(since: session.since, now: agents.now)
        switch session.activity {
        case .needsYou: return "waiting \(age)"
        case .working: return "working \(age)"
        case .yourTurn: return "done \(age)"
        }
    }
}

/// D — a small meter: the agent, the figure, the bar, when it resets.
private struct MiniMeter: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ToolIcon(tool: limits.tool, size: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(limits.tool.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Spacer(minLength: 2)
                PercentFigure(value: estimate.percent, size: 15, color: estimate.urgent ? .themeAccent : .ink)
            }
            PaceBar(estimate: estimate, now: now, height: 4)
            Text("\(estimate.shortWindow)\(estimate.exact ? "" : " · est.") · \(estimate.when(now: now))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(estimate.urgent ? Color.themeAccent : Color.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.tool.name) limit")
        .accessibilityValue("\(Int(estimate.percent.rounded())) percent, \(estimate.when(now: now))")
    }
}
