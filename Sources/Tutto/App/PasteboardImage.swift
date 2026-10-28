//
//  PasteboardImage.swift
//  Tutto
//
//  Puts an image on the clipboard as PNG right away and promises TIFF, generating it
//  only if some app actually asks. A full-screen TIFF is ~24 MB and takes a while to
//  encode; most apps never request it.
//

import AppKit

enum PasteboardImage {
    /// The provider for the latest image must stay alive while the clipboard holds its promise.
    @MainActor private static var current: LazyTIFFProvider?

    @MainActor
    static func write(png: Data, to pasteboard: NSPasteboard = .general) {
        let provider = LazyTIFFProvider(png: png)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        current = provider
    }

    /// The clipboard moved on: the promise is void, so the PNG it held can go.
    @MainActor
    fileprivate static func finished(_ provider: LazyTIFFProvider) {
        if current === provider { current = nil }
    }
}

private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { PasteboardImage.finished(self) }
        }
    }
}
