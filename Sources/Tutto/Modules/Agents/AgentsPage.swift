//
//  AgentsPage.swift
//  Tutto
//
//  Agents in the app: the page's header, then AgentsDashboard (limits, sessions by what they need,
//  what agents left running, the alerts).
//

import AppKit
import SwiftUI
import TuttoKit

struct AgentsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Agents",
                       subtitle: "Claude Code and Codex on this Mac: which need you, what each costs, what they left running, and how close you are to your limits.",
                       module: .agents)
            if let agents = model.agents {
                AgentsDashboard(agents: agents)
            } else {
                ModuleOffView(module: .agents, model: model)
            }
        }
    }
}
