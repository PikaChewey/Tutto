//
//  PreviewViewController.swift
//  TuttoQuickLook
//
//  Quick Look for archives in Finder: select an archive and press space to see what's inside
//  (its folders and files, their sizes, how many and how big in all) without opening anything.
//  Read only and sandboxed; the archive is read with the libarchive built into macOS, headers
//  only for zip, RAR, 7z and the like.
//

import AppKit
import Quartz
import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let extractor = ArchiveExtractor(url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            let listing: Result<ArchiveTree, Error> = Result { ArchiveTree(entries: try extractor.listEntries()) }
            DispatchQueue.main.async {
                let host = NSHostingView(rootView: ArchiveQuickLookView(name: url.lastPathComponent, listing: listing))
                host.frame = self.view.bounds
                host.autoresizingMask = [.width, .height]
                self.view.addSubview(host)
                handler(nil)
            }
        }
    }
}

/// One line of the listing: a folder or file, indented by its depth.
private struct Line: Identifiable {
    var node: ArchiveNode
    var depth: Int
    var id: String { node.path }
}

private struct ArchiveQuickLookView: View {
    var name: String
    var listing: Result<ArchiveTree, Error>

    /// Enough to see what's there; past this the count says how much more.
    private static let maxLines = 1500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch listing {
            case .success(let tree):
                let lines = Self.lines(tree)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line) }
                        let total = tree.root.fileCount
                        if lines.count >= Self.maxLines {
                            Text("…and more (\(total) files in all)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 6)
                }
            case .failure(let error):
                Text(message(error))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .archive))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if case .success(let tree) = listing {
                    Text("\(tree.root.fileCount) file\(tree.root.fileCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: tree.root.size, countStyle: .file)) unpacked")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: line.node.isDirectory ? NSWorkspace.shared.icon(for: .folder)
                  : NSWorkspace.shared.icon(for: UTType(filenameExtension: line.node.fileExtension) ?? .data))
                .resizable()
                .frame(width: 16, height: 16)
            Text(line.node.name).lineLimit(1).truncationMode(.middle)
            if line.node.isEncrypted {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(line.node.isDirectory && line.node.fileCount > 0
                 ? "\(line.node.fileCount) item\(line.node.fileCount == 1 ? "" : "s")"
                 : ByteCountFormatter.string(fromByteCount: line.node.size, countStyle: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 16 + CGFloat(line.depth) * 18)
        .padding(.trailing, 16)
        .frame(height: 24)
    }

    /// The whole tree, folders open, depth first.
    private static func lines(_ tree: ArchiveTree) -> [Line] {
        var lines: [Line] = []
        func add(_ folder: String, depth: Int) {
            for node in tree.children(of: folder) {
                guard lines.count < maxLines else { return }
                lines.append(Line(node: node, depth: depth))
                if node.isDirectory { add(node.path, depth: depth + 1) }
            }
        }
        add("", depth: 0)
        return lines
    }

    private func message(_ error: Error) -> String {
        switch error as? ArchiveError {
        case .passwordRequired?, .wrongPassword?, .unsupportedEncryption?: return "This archive is locked with a password."
        case .notAnArchive?: return "This doesn't look like an archive."
        default: return "Its contents couldn't be read."
        }
    }
}
