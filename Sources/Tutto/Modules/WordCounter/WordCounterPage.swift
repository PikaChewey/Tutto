//
//  WordCounterPage.swift
//  Tutto
//
//  The Word Counter page in the main window: its shortcut, what it counts, reading speed.
//

import SwiftUI
import TuttoKit

struct WordCounterPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Word Counter",
                       subtitle: "Paste or type text and see its words, characters, sentences and reading time as you go.",
                       module: .wordCounter)
            if let counter = model.wordCounter {
                WordCounterSettings(counter: counter, model: model)
            } else {
                ModuleOffView(module: .wordCounter, model: model)
            }
        }
    }
}

private struct WordCounterSettings: View {
    @Bindable var counter: WordCounterModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup {
                LabeledRow("Open word counter", detail: "The cursor is ready: press ⌘V to paste and count. Press the shortcut again or Esc to close.") {
                    ShortcutRecorder(action: .wordCounter, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Reading speed", detail: "\(Int(counter.readingSpeed)) words a minute, for reading time.") {
                    InkSegmented(selection: $counter.readingSpeed, options: WordCounterModule.readingSpeeds)
                }
                Hairline().opacity(0.6)
                LabeledRow("Open it now", detail: "Also on the menu bar panel.") {
                    Button("Open") { counter.togglePanel() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
            InkGroup("What it counts") {
                note("Words", "Anything between spaces with a letter or number in it, as Word and Google Docs count: “well-known” and “don't” are one word each. Chinese, Japanese and Thai are split into words by macOS.")
                Hairline().opacity(0.6)
                note("Characters", "What you see as one character, so an emoji counts once. Also shown without spaces and line breaks.")
                Hairline().opacity(0.6)
                note("Sentences and paragraphs", "Sentences as macOS splits them; paragraphs are non-empty lines.")
                Hairline().opacity(0.6)
                note("Reading and speaking time", "At your reading speed above, and \(Int(TextStats.speakingSpeed)) words a minute spoken aloud.")
                Hairline().opacity(0.6)
                note("Selection", "Select part of the text to count just that.")
            }
        }
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(text).font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
