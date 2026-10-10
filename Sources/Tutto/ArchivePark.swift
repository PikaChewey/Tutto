// TEMPORARY: lets the app build while the archive engine lands. Deleted after merge.
import AppKit
import SwiftUI
@MainActor @Observable final class ArchiveModule: ModuleController { init(model: AppModel) {}; func start() {}; func stop() {} }
@MainActor enum ArchiveRequests { static func handle(_ url: URL, model: AppModel) {}; static func open(_ urls: [URL], model: AppModel) {} }
struct ArchivesPage: View { var model: AppModel; var body: some View { Text("Archives") } }
