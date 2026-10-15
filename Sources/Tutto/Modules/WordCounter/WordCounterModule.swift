//
//  WordCounterModule.swift
//  Tutto
//
//  ⌃⇧C: a small panel with the text cursor already in it. Paste (⌘V) or type and the
//  counts update as you go: words, characters with and without spaces, sentences,
//  paragraphs, reading and speaking time, and the same for a selection.
//
//  Costs nothing until opened: the shortcut is a registered hot key, the panel is built
//  when shown and released when closed. The last text is kept (and selected on reopen,
//  so ⌘V replaces it) only while the module is on.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class WordCounterModule: ModuleController {
    /// Words per minute used for reading time.
    var readingSpeed: Double { didSet { defaults.set(readingSpeed, forKey: Keys.readingSpeed) } }

    /// What was in the panel when it last closed.
    private(set) var lastText = ""

    @ObservationIgnored private var panel: WordCounterPanelController?
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let readingSpeeds: [(Double, String)] = [(180, "Relaxed"), (TextStats.averageReadingSpeed, "Average"), (300, "Fast")]

    init() {
        defaults.register(defaults: [Keys.readingSpeed: TextStats.averageReadingSpeed])
        readingSpeed = defaults.double(forKey: Keys.readingSpeed)
    }

    // MARK: ModuleController

    func start() {}

    func stop() {
        panel?.close()
        panel = nil
        lastText = ""
    }

    // MARK: Panel

    /// Opens the panel, or closes it if it's open (pressing the shortcut again).
    func togglePanel() {
        if let panel {
            panel.close()
            return
        }
        let controller = WordCounterPanelController(module: self)
        panel = controller
        controller.show(text: lastText)
    }

    func panelDidClose(text: String) {
        lastText = text
        panel = nil
    }

    private enum Keys {
        static let readingSpeed = "wordCounter.readingSpeed"
    }
}

// MARK: - Panel controller

@MainActor
@Observable
final class WordCounterModel {
    var stats = TextStats.empty
    var selection: TextStats?
    /// A very large paste is being counted in the background.
    var isCounting = false
    var isEmpty = true
}

@MainActor
final class WordCounterPanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private weak var module: WordCounterModule?
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private let model = WordCounterModel()
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }

    /// Text up to this size is counted on the spot (well under a millisecond per keystroke);
    /// longer text is counted off the main thread, coalescing quick edits.
    private static let inlineLimit = 20_000
    private static let counter = DispatchQueue(label: "ca.bryanyao.Tutto.word-counter", qos: .userInitiated)
    private var generation = 0
    private var pending: DispatchWorkItem?

    init(module: WordCounterModule) {
        self.module = module
        super.init()
        configureTextView()
    }

    func show(text: String) {
        guard let module else { return }
        let panel = FloatingPanel(size: NSSize(width: 720, height: 440))
        panel.contentMinSize = NSSize(width: 560, height: 340)
        panel.delegate = self
        panel.onResignKey = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: WordCounterView(model: model, module: module, editor: scrollView))
        panel.positionOnActiveScreen()
        self.panel = panel

        textView.string = text
        recount()
        panel.makeKeyAndOrderFront(nil)
        installKeys()
        // Cursor in the text, everything selected: ⌘V replaces the last text in one go. Done a
        // run-loop turn later, once SwiftUI has put the text view in the window (before that,
        // making it first responder silently does nothing).
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            panel.makeFirstResponder(self.textView)
            self.textView.selectAll(nil)
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pending?.cancel()
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
        panel.contentView = nil
        module?.panelDidClose(text: textView.string)
    }

    func windowWillClose(_ notification: Notification) { close() }

    // MARK: Text

    private func configureTextView() {
        let textView = self.textView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        // Count exactly what was pasted: no smart quotes, dashes, replacements or spelling marks.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.setAccessibilityLabel("Text to count")
        textView.delegate = self
    }

    func textDidChange(_ notification: Notification) { recount() }

    func textViewDidChangeSelection(_ notification: Notification) { recountSelection() }

    private func recount() {
        let text = textView.string
        generation += 1
        pending?.cancel()
        model.isEmpty = text.isEmpty
        if (text as NSString).length <= Self.inlineLimit {
            model.stats = TextStats.measure(text)
            model.isCounting = false
            return
        }
        model.isCounting = true
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in
            let stats = TextStats.measure(text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.model.stats = stats
                    self.model.isCounting = false
                }
            }
        }
        pending = work
        Self.counter.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func recountSelection() {
        let range = textView.selectedRange()
        // Everything selected says nothing new; a huge selection isn't worth a stall.
        guard range.length > 0, range.length < (textView.string as NSString).length, range.length <= Self.inlineLimit else {
            model.selection = nil
            return
        }
        model.selection = TextStats.measure((textView.string as NSString).substring(with: range))
    }

    // MARK: Keys

    private func performEditingKey(_ keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        if panel?.firstResponder !== textView { panel?.makeFirstResponder(textView) }
        switch (keyCode, flags) {
        case (kVK_ANSI_V, [.command]): textView.paste(nil)
        case (kVK_ANSI_V, [.command, .shift]), (kVK_ANSI_V, [.command, .option, .shift]): textView.pasteAsPlainText(nil)
        case (kVK_ANSI_C, [.command]): textView.copy(nil)
        case (kVK_ANSI_X, [.command]): textView.cut(nil)
        case (kVK_ANSI_A, [.command]): textView.selectAll(nil)
        case (kVK_ANSI_Z, [.command]): textView.undoManager?.undo()
        case (kVK_ANSI_Z, [.command, .shift]): textView.undoManager?.redo()
        default: return false
        }
        return true
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.close()
                return nil
            case kVK_ANSI_K where flags == [.command]:
                self.textView.selectAll(nil)
                self.textView.insertText("", replacementRange: self.textView.selectedRange())  // undoable
                return nil
            default:
                // Editing keys go straight to the text: Tutto never becomes the active app, so its
                // Edit menu doesn't see them and ⌘V would do nothing.
                return self.performEditingKey(Int(event.keyCode), flags: flags) ? nil : event
            }
        }
    }
}

// MARK: - View

struct WordCounterView: View {
    var model: WordCounterModel
    var module: WordCounterModule
    var editor: NSScrollView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    HostedView(view: editor)
                    if model.isEmpty {
                        Text("Paste or type text")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.ink4)
                            .padding(.leading, 19)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline(vertical: true)
                stats
                    .frame(width: 230)
            }
            Hairline()
            footer
        }
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
    }

    private var stats: some View {
        let stats = model.stats
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Readout(caption: "Words", value: Self.number(stats.words), large: true)
                Readout(caption: "Characters", value: Self.number(stats.characters), large: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.number(stats.words)) words, \(Self.number(stats.characters)) characters")
            .padding(.bottom, 16)
            Hairline().opacity(0.6)
            row("Without spaces", Self.number(stats.charactersExcludingSpaces))
            row("Sentences", Self.number(stats.sentences))
            row("Paragraphs", Self.number(stats.paragraphs))
            row("Reading time", TextStats.format(duration: stats.readingTime(wordsPerMinute: module.readingSpeed)))
            row("Speaking time", TextStats.format(duration: stats.speakingTime()))
            Spacer(minLength: 0)
            if let selection = model.selection {
                VStack(alignment: .leading, spacing: 3) {
                    Caption("Selection")
                    Text("\(Self.number(selection.words)) words · \(Self.number(selection.characters)) characters")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.ink2)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(18)
        .opacity(model.isCounting ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Counts")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color.ink2)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.ink)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) { Hairline().opacity(0.6) }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("Paste", "⌘V")
            hint("Clear", "⌘K")
            if model.isCounting {
                Text("Counting…").font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            Spacer()
            hint("Close", "Esc")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1)
            Text(keys).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color.ink3)
        }
    }

    static func number(_ value: Int) -> String { value.formatted() }
}

/// Puts an AppKit view the controller owns into SwiftUI as is.
private struct HostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
