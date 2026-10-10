// Temporary stand-ins while the full modules are written. Removed module by module.
import AppKit
import Observation
import TuttoKit

@MainActor @Observable final class ArchiveModule: ModuleController {
    init(model: AppModel) {}
    func start() {}
    func stop() {}
}

import SwiftUI

struct ArchivesPage: View { var model: AppModel; var body: some View { PageHeader(title: "Archives", subtitle: "Coming up", module: .archives) } }

enum OnboardingStep { case welcome, cornerClick }
@MainActor final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    func show(step: OnboardingStep = .welcome) {}
}
@MainActor enum ArchiveRequests {
    static func handle(_ url: URL, model: AppModel) {}
    static func open(_ urls: [URL], model: AppModel) {}
}
