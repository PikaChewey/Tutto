//
//  PasswordPrompt.swift
//  Tutto
//
//  Asks for an archive's password. It's a panel that takes keyboard focus on its own:
//  extraction usually starts from Finder, and macOS won't always hand activation to
//  Tutto, so a regular alert could leave your typing going to Finder.
//

import AppKit
import SwiftUI

@MainActor
final class PasswordPrompt {
    private static var current: PasswordPrompt?

    private var panel: FloatingPanel?
    private var completion: ((String?) -> Void)?

    static func ask(archiveName: String, wrong: Bool, completion: @escaping (String?) -> Void) {
        current?.finish(nil)
        let prompt = PasswordPrompt()
        current = prompt
        prompt.show(archiveName: archiveName, wrong: wrong, completion: completion)
    }

    private func show(archiveName: String, wrong: Bool, completion: @escaping (String?) -> Void) {
        self.completion = completion
        let panel = FloatingPanel(size: NSSize(width: 360, height: 210))
        panel.level = .modalPanel
        let view = PasswordPromptView(archiveName: archiveName, wrong: wrong,
                                      submit: { [weak self] password in self?.finish(password) },
                                      cancel: { [weak self] in self?.finish(nil) })
        panel.contentView = NSHostingView(rootView: view)
        panel.positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.focusSearchField()
        self.panel = panel
    }

    private func finish(_ password: String?) {
        guard let completion else { return }
        self.completion = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        Self.current = nil
        completion(password?.isEmpty == true ? nil : password)
    }
}

private struct PasswordPromptView: View {
    var archiveName: String
    var wrong: Bool
    var submit: (String) -> Void
    var cancel: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wrong ? "That password didn't work." : "“\(archiveName)” is protected.")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("Enter the archive's password to extract it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ink3)
                }
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit(password) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Extract") { submit(password) }
                    .buttonStyle(InkButtonStyle(compact: true))
                    .disabled(password.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: Radius.of(14), style: .continuous).strokeBorder(Color.hairline))
    }
}
