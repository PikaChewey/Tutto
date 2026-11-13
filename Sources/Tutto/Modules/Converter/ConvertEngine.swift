//
//  ConvertEngine.swift
//  Tutto
//
//  The work behind Convert and Compress, all on this Mac with macOS's own frameworks: ImageIO
//  for pictures (orientation applied, details removed when asked, a size target found by a
//  quality search, PNGs made into palette PNGs), AVFoundation for video (a reader-writer
//  transcode with its own bit rate, so Compress means something) and sound, PDFKit for PDFs,
//  and the text system for documents. Results go beside the originals; nothing is overwritten.
//

import AppKit
import AVFoundation
import CoreText
import ImageIO
import PDFKit
import TuttoKit
import UniformTypeIdentifiers
import Vision
import VideoToolbox

enum ConvertAction: Equatable, Hashable, Sendable {
    case convert(OutputFormat)
    case compress
    /// Fewer pixels (pictures, video).
    case resize(ResizeSpec)
    /// Cut to a shape (pictures, video, PDF pages), keeping what draws the eye.
    case crop(CropSpec)

    var title: String {
        switch self {
        case .convert(let format): "Convert to \(format.title)"
        case .compress: "Compress"
        case .resize(let spec): "Resize to \(spec.title)"
        case .crop(let spec): "Crop to \(spec.title)"
        }
    }

    /// "Compressing", "Converting to PNG", "Resizing", "Cropping".
    var working: String {
        switch self {
        case .convert(let format): "Converting to \(format.title)"
        case .compress: "Compressing"
        case .resize: "Resizing"
        case .crop: "Cropping"
        }
    }

    /// Whether every one of these kinds can take it.
    func applies(to kinds: [FileKind]) -> Bool {
        guard !kinds.isEmpty else { return false }
        switch self {
        case .convert(let format): return ConvertPlanner.targets(for: kinds).contains(format)
        case .compress: return kinds.allSatisfy(ConvertPlanner.canCompress)
        case .resize: return kinds.allSatisfy(ConvertPlanner.canResize)
        case .crop: return kinds.allSatisfy(ConvertPlanner.canCrop)
        }
    }
}

struct ConvertError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ConvertEngine {
    /// Runs one action on a selection; returns the files written. Several images (or PDFs)
    /// made into a PDF become one file; everything else is one result per file.
    /// `folder` puts the results there instead of beside the originals (the automatic compressor
    /// writes into a folder of its own, then swaps the result in).
    static func run(_ action: ConvertAction, on sources: [URL], settings: CompressionSettings, into folder: URL? = nil,
                    halve: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let kinds = sources.map(FileKind.of)
        if case .convert(let format) = action, ConvertPlanner.combines(kinds, into: format) {
            return [try await MainActor.run { try combinePDF(sources) }]
        }
        var outputs: [URL] = []
        for (index, source) in sources.enumerated() {
            let share = 1 / Double(sources.count)
            let base = Double(index) * share
            let report: @Sendable (Double) -> Void = { progress(base + $0 * share) }
            outputs += try await one(action, source: source, kind: kinds[index], settings: settings, folder: folder, halve: halve,
                                     progress: report)
            progress(base + share)
        }
        return outputs
    }

    private static func one(_ action: ConvertAction, source: URL, kind: FileKind, settings: CompressionSettings, folder: URL?,
                            halve: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        switch (kind, action) {
        case (.image, .convert(let format)):
            return [try await Task.detached { try image(source, to: format, compress: false, settings: settings, folder: folder) }.value]
        case (.image, .compress):
            return [try await Task.detached {
                try image(source, to: nil, compress: true, settings: settings, folder: folder, halve: halve)
            }.value]
        case (.image, .resize), (.image, .crop):
            return [try await Task.detached { try image(source, to: nil, compress: false, edit: action, settings: settings, folder: folder) }.value]
        case (.pdf, .crop(let spec)):
            return [try await Task.detached { try cropPDF(source, spec: spec, folder: folder) }.value]
        case (.video, .resize), (.video, .crop):
            return [try await transcode(source, to: nil, compress: false, edit: action, settings: settings, folder: folder, progress: progress)]
        case (.pdf, .convert(.txt)):
            return [try pdfText(source)]
        case (.pdf, .convert(let format)):
            return try await Task.detached { try pdfPages(source, to: format) }.value
        case (.pdf, .compress):
            return [try await Task.detached { try compressPDF(source, level: settings.pdfLevel, folder: folder) }.value]
        case (.video, .convert(.gif)):
            return [try await gif(from: source, settings: settings, progress: progress)]
        case (.video, .convert(.m4a)):
            return [try await soundtrack(of: source)]
        case (.video, .convert(let format)):
            return [try await transcode(source, to: format, compress: false, settings: settings, progress: progress)]
        case (.video, .compress):
            return [try await transcode(source, to: nil, compress: true, settings: settings, folder: folder, progress: progress)]
        case (.audio, .convert(let format)):
            return [try await Task.detached { try audio(source, to: format, kbps: nil, progress: progress) }.value]
        case (.audio, .compress):
            return [try await Task.detached { try audio(source, to: .m4a, kbps: settings.audioKbps, compress: true, progress: progress) }.value]
        case (.document, .convert(let format)):
            return [try await MainActor.run { try document(source, to: format) }]
        case (.subtitles, .convert(let format)):
            return [try subtitles(source, to: format)]
        default:
            let verb = switch action {
            case .compress: "compressed"
            case .resize: "resized"
            case .crop: "cropped"
            case .convert: "converted that way"
            }
            throw ConvertError("\(source.lastPathComponent) can't be \(verb)")
        }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])).flatMap { $0.fileSize } ?? 0
    }

    // MARK: Pictures

    private static func imageType(_ format: OutputFormat) -> UTType? {
        switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif")
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        default: nil
        }
    }

    /// The format a picture is compressed into: its own when macOS can write it, else JPEG.
    private static func compressedFormat(of source: URL) -> OutputFormat {
        switch source.pathExtension.lowercased() {
        case "png": .png
        case "heic", "heif", "hif": .heic
        case "avif": .avif
        case "tif", "tiff": .tiff
        default: .jpeg
        }
    }

    /// Converts, compresses, resizes (`edit` .resize) or crops (`edit` .crop) a picture. `halve`
    /// brings a Retina screenshot to half its pixels while compressing it.
    private static func image(_ source: URL, to wanted: OutputFormat?, compress: Bool, edit: ConvertAction? = nil,
                              settings: CompressionSettings, folder: URL? = nil, halve: Bool = false) throws -> URL {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(input) > 0 else { throw ConvertError("\(source.lastPathComponent) isn't a picture macOS can read") }
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height, 1)
        let format = wanted ?? compressedFormat(of: source)
        let removeDetails = compress && settings.removeImageDetails
        var side = compress ? min(settings.imageMaxSide ?? longest, longest) : longest
        if compress, halve { side = min(side, max(longest / 2, 64)) }
        if case .resize(let spec)? = edit {
            let after = spec.size(width: width, height: height)
            side = max(after.width, after.height)
            guard side < longest else { throw ConvertError("\(source.lastPathComponent) is already \(width) × \(height)") }
        }

        func decode(_ maxSide: Int) throws -> CGImage {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,  // the picture the right way up
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
                throw ConvertError("Couldn't read \(source.lastPathComponent)")
            }
            return image
        }
        // The metadata to carry: none when removing details, else the original's, upright.
        var metadata: [CFString: Any] = [:]
        if !removeDetails {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let value = properties[key] { metadata[key] = value }
            }
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        metadata[kCGImagePropertyOrientation] = 1

        let output: URL = switch edit {
        case .resize?: OutputNames.edited(source, mark: "resized", ext: format.fileExtension, in: folder, exists: exists)
        case .crop?: OutputNames.edited(source, mark: "cropped", ext: format.fileExtension, in: folder, exists: exists)
        default: compress
            ? OutputNames.compressed(source, ext: format.fileExtension, in: folder, exists: exists)
            : OutputNames.converted(source, ext: format.fileExtension, in: folder, exists: exists)
        }

        if format == .pdf {
            let picture = try decode(side)
            try writePDF(pages: [(isPhoto(source) ? jpegBacked(picture) : picture, dpi(properties))], to: output)
            return output
        }
        guard let type = imageType(format) else { throw ConvertError("Can't write \(format.title)") }
        let lossy = [.jpeg, .heic, .avif].contains(format)
        var quality = compress ? settings.imageQuality : (edit == nil ? 0.92 : 0.9)

        func encode(_ picture: CGImage, _ quality: Double) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            var options = metadata
            if lossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
            if format == .tiff {
                // LZW, lossless: a TIFF a fraction of the uncompressed size.
                var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5
                options[kCGImagePropertyTIFFDictionary] = tiff
            }
            if format == .png, compress, let palette = paletteImage(picture) {
                CGImageDestinationAddImage(destination, palette, options as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, picture, options as CFDictionary)
            }
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }

        var picture = try decode(side)
        if case .crop(let spec)? = edit { picture = try cropped(picture, to: spec) }
        var data = encode(picture, quality)
        // A size to aim for: the best quality (down to a decent floor) that fits; if none does,
        // smaller dimensions, then the search again at the new size.
        if compress, let target = settings.imageTargetBytes, let current = data, current.count > target {
            var floor = lossy ? 0.4 : quality
            for attempt in 0..<6 {
                if lossy, let best = QualitySearch.best(target: target, low: floor, high: quality, steps: 7,
                                                        size: { encode(picture, $0)?.count ?? .max }) {
                    quality = best
                    data = encode(picture, quality)
                    break
                }
                let measured = encode(picture, floor)?.count ?? target * 2
                if !lossy, measured <= target { data = encode(picture, quality); break }
                side = max(Int(Double(side) * min((Double(target) / Double(measured)).squareRoot() * 0.97, 0.92)), 64)
                picture = try decode(side)
                if attempt >= 3 { floor = 0.15 }
                data = encode(picture, lossy ? floor : quality)
            }
        }
        guard let data else { throw ConvertError("Couldn't write \(output.lastPathComponent)") }
        try data.write(to: output, options: .withoutOverwriting)
        return output
    }

    /// The largest part of `spec`'s shape, placed over what draws the eye (Vision's attention
    /// map: faces, people, the subject), then brought down to `spec`'s size if it has one.
    private static func cropped(_ picture: CGImage, to spec: CropSpec) throws -> CGImage {
        let rect = CropMath.rect(width: picture.width, height: picture.height, ratio: spec.ratio, focus: focus(of: picture))
        guard rect.width < CGFloat(picture.width) || rect.height < CGFloat(picture.height) || { if case .size = spec { true } else { false } }() else {
            throw ConvertError("It's already \(spec.title)")
        }
        guard var result = picture.cropping(to: rect) else { throw ConvertError("Couldn't crop the picture") }
        let size = spec.outputSize(width: picture.width, height: picture.height)
        if size.width < result.width || size.height < result.height {
            guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: result.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return result }
            context.interpolationQuality = .high
            context.draw(result, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            if let scaled = context.makeImage() { result = scaled }
        }
        return result
    }

    /// Where a picture's subject is (0–1 from the top left), from Vision's attention map; the
    /// middle when Vision finds nothing.
    static func focus(of picture: CGImage) -> CGPoint {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: picture, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNSaliencyImageObservation else { return CGPoint(x: 0.5, y: 0.5) }
        let regions = (observation.salientObjects ?? []).map { box in
            // Vision measures from the bottom left.
            (rect: CGRect(x: box.boundingBox.minX, y: 1 - box.boundingBox.maxY, width: box.boundingBox.width, height: box.boundingBox.height),
             confidence: Double(box.confidence))
        }
        return CropMath.focus(of: regions)
    }

    /// A copied picture as a smaller PNG: a palette PNG when that looks the same (most screenshots),
    /// at half its pixels with `halve` when it's from a Retina screen. Its resolution is kept (or
    /// halved with it), so it pastes at the same size on the page. Nil when it can't be read.
    nonisolated static func smallerPNG(_ data: Data, halve: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var resolution = dpi(properties)
        var side = max(width, height, 1)
        if halve, resolution >= 140 {
            side = max(side / 2, 16)
            resolution /= 2
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, paletteImage(picture) ?? picture,
                                   [kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Camera pictures (kept as JPEG inside a PDF) as opposed to screenshots and graphics (kept lossless).
    private static func isPhoto(_ source: URL) -> Bool {
        !["png", "gif", "bmp", "tif", "tiff", "ico", "icns"].contains(source.pathExtension.lowercased())
    }

    /// The picture backed by JPEG data, so a PDF stores it as JPEG (a tenth of a lossless copy).
    private static func jpegBacked(_ picture: CGImage) -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return picture }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return picture }
        return jpeg
    }

    static func dpi(_ properties: [CFString: Any]) -> Double {
        (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 30 ? $0 : nil } ?? 144
    }

    /// A palette version of an opaque picture when it looks the same (most screenshots and
    /// graphics); nil for photos and pictures with transparency.
    static func paletteImage(_ picture: CGImage) -> CGImage? {
        let width = picture.width, height = picture.height
        guard width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        guard let result = PaletteQuantizer.quantize(rgba: pixels, width: width, height: height, bytesPerRow: width * 4),
              result.meanError <= 4.5 else { return nil }
        var table: [UInt8] = []
        for color in result.palette { table += [color.0, color.1, color.2] }
        guard let space = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: result.palette.count - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(result.indices) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// One page per picture, each the picture's size at its resolution (144 dpi when it has none).
    private static func writePDF(pages: [(CGImage, Double)], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConvertError("Couldn't create \(url.lastPathComponent)")
        }
        for (picture, dpi) in pages {
            var box = CGRect(x: 0, y: 0, width: Double(picture.width) * 72 / dpi, height: Double(picture.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(picture, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: PDFs

    /// Several pictures and PDFs into one PDF, in the order they were given.
    @MainActor
    private static func combinePDF(_ sources: [URL]) throws -> URL {
        let document = PDFDocument()
        for source in sources {
            if FileKind.of(source) == .pdf, let pdf = PDFDocument(url: source) {
                for index in 0..<pdf.pageCount {
                    if let page = pdf.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
                }
            } else if let picture = NSImage(contentsOf: source), let page = PDFPage(image: picture) {
                document.insert(page, at: document.pageCount)
            } else {
                throw ConvertError("\(source.lastPathComponent) can't go into a PDF")
            }
        }
        guard let output = OutputNames.combined(sources, ext: "pdf", exists: exists), document.write(to: output) else {
            throw ConvertError("Couldn't write the PDF")
        }
        return output
    }

    /// Every page as a picture at 300 dpi: beside the PDF for one page, in a folder for more.
    private static func pdfPages(_ source: URL, to format: OutputFormat) throws -> [URL] {
        guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0 else {
            throw ConvertError("\(source.lastPathComponent) isn't a PDF macOS can read")
        }
        guard let type = imageType(format) else { throw ConvertError("Can't write \(format.title)") }
        let count = document.numberOfPages
        var folder = source.deletingLastPathComponent()
        if count > 1 {
            folder = OutputNames.unique("\(source.deletingPathExtension().lastPathComponent) pages", ext: "", in: folder, exists: exists)
            if folder.pathExtension.isEmpty == false { folder = folder.deletingPathExtension() }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let scale = 300.0 / 72
        var outputs: [URL] = []
        for number in 1...count {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = CGSize(width: (rotated ? box.height : box.width) * scale, height: (rotated ? box.width : box.height) * scale)
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor.white)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: CGSize(width: size.width / scale, height: size.height / scale)),
                                                         rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let picture = context.makeImage() else { continue }
            let name = count == 1 ? source.deletingPathExtension().lastPathComponent : "\(source.deletingPathExtension().lastPathComponent) \(number)"
            let url = OutputNames.unique(name, ext: format.fileExtension, in: folder, exists: exists)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9,
                                                              kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
            if CGImageDestinationFinalize(destination) { outputs.append(url) }
        }
        guard !outputs.isEmpty else { throw ConvertError("No pages could be saved") }
        return count > 1 ? [folder] : outputs
    }

    private static func pdfText(_ source: URL) throws -> URL {
        guard let document = PDFDocument(url: source) else { throw ConvertError("\(source.lastPathComponent) isn't a PDF macOS can read") }
        let text = document.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConvertError("\(source.lastPathComponent) has no text in it (it's pictures of pages: try Copy Text in the screenshot editor)")
        }
        let output = OutputNames.converted(source, ext: "txt", exists: exists)
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Light: pictures inside stored as JPEG at their full resolution (prints as before).
    /// Strong: also brought down to screen resolution (for email and sharing).
    private static func compressPDF(_ source: URL, level: CompressionSettings.PDFLevel, folder: URL? = nil) throws -> URL {
        guard let document = PDFDocument(url: source) else { throw ConvertError("\(source.lastPathComponent) isn't a PDF macOS can read") }
        let output = OutputNames.compressed(source, in: folder, exists: exists)
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level == .strong { options[.optimizeImagesForScreenOption] = true }
        guard document.write(to: output, withOptions: options) else { throw ConvertError("Couldn't write \(output.lastPathComponent)") }
        // A PDF of text only can't get smaller this way; keep the original then.
        if size(output) >= size(source) {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError("\(source.lastPathComponent) is already as small as it gets (it has no large pictures)")
        }
        return output
    }

    /// Every page cut to `spec`'s shape (its crop box: nothing is lost, a PDF app can bring it back),
    /// centred, the way a page is read on a phone or a tablet.
    private static func cropPDF(_ source: URL, spec: CropSpec, folder: URL?) throws -> URL {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ConvertError("\(source.lastPathComponent) isn't a PDF macOS can read")
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            // A page turned on its side shows its box the other way round.
            let ratio = page.rotation % 180 == 0 ? spec.ratio : 1 / spec.ratio
            let rect = CropMath.rect(width: Int(box.width.rounded()), height: Int(box.height.rounded()), ratio: ratio)
            page.setBounds(CGRect(x: box.minX + rect.minX, y: box.maxY - rect.minY - rect.height, width: rect.width, height: rect.height),
                           for: .cropBox)
        }
        let output = OutputNames.edited(source, mark: "cropped", in: folder, exists: exists)
        guard document.write(to: output) else { throw ConvertError("Couldn't write \(output.lastPathComponent)") }
        return output
    }

    // MARK: Video

    /// Re-encodes with AVAssetReader and AVAssetWriter: H.264 or HEVC at a bit rate chosen from
    /// the picture size and quality, scaled down when asked, sound as AAC.
    /// `edit` .resize brings it to fewer pixels; .crop cuts every frame to a shape (through a Core
    /// Image composition, upright, centred on the subject of the middle frame).
    private static func transcode(_ source: URL, to wanted: OutputFormat?, compress: Bool, edit: ConvertAction? = nil,
                                  settings: CompressionSettings, folder: URL? = nil,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConvertError("\(source.lastPathComponent) has no video macOS can read")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let fps = Double(try await video.load(.nominalFrameRate))
        let sourceRate = Double(try await video.load(.estimatedDataRate))

        let format = wanted ?? (source.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let codec: CompressionSettings.VideoCodec = compress ? settings.videoCodec : (format == .mp4HEVC ? .hevc : .h264)
        var size = CompressionSettings.fitted(width: Int(abs(natural.width)), height: Int(abs(natural.height)),
                                              maxHeight: compress ? settings.videoMaxHeight : nil)
        // The frame as it's seen (a phone video is stored on its side and turned by its transform).
        let upright = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let uprightWidth = Int(upright.width.rounded()), uprightHeight = Int(upright.height.rounded())
        var cropRect: CGRect?
        switch edit {
        case .resize(let spec)?:
            guard spec.shrinks(width: Int(abs(natural.width)), height: Int(abs(natural.height))) else {
                throw ConvertError("\(source.lastPathComponent) is already \(uprightWidth) × \(uprightHeight)")
            }
            let after = spec.size(width: Int(abs(natural.width)), height: Int(abs(natural.height)), even: true)
            size = (after.width, after.height)
        case .crop(let spec)?:
            let focus = await videoFocus(asset, duration: duration)
            cropRect = CropMath.rect(width: uprightWidth, height: uprightHeight, ratio: spec.ratio, focus: focus, even: true)
            let after = spec.outputSize(width: uprightWidth, height: uprightHeight, even: true)
            size = (after.width, after.height)
        default:
            break
        }
        var bitrate = CompressionSettings.videoBitrate(width: size.width, height: size.height, fps: fps,
                                                       quality: compress ? settings.videoQuality : .high, codec: codec)
        // Converting (not compressing) keeps about the quality it had; it never adds bits it never had.
        if !compress, edit == nil, sourceRate > 0 { bitrate = Int(min(max(sourceRate, Double(bitrate) * 0.5), Double(bitrate) * 1.5)) }
        if compress || edit != nil, sourceRate > 0 { bitrate = min(bitrate, Int(sourceRate * (compress ? 0.9 : 1))) }

        let output: URL = switch edit {
        case .resize?: OutputNames.edited(source, mark: "resized", ext: format.fileExtension, in: folder, exists: exists)
        case .crop?: OutputNames.edited(source, mark: "cropped", ext: format.fileExtension, in: folder, exists: exists)
        default: compress
            ? OutputNames.compressed(source, ext: format.fileExtension, in: folder, exists: exists)
            : OutputNames.converted(source, ext: format.fileExtension, in: folder, exists: exists)
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: format == .mov ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixels: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let videoOut: AVAssetReaderOutput
        if let cropRect {
            // Core Image hands each frame upright (the track's transform applied), origin at the bottom left.
            let ciRect = CGRect(x: cropRect.minX, y: CGFloat(uprightHeight) - cropRect.maxY, width: cropRect.width, height: cropRect.height)
            let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                let frame = request.sourceImage.cropped(to: ciRect)
                    .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
                request.finish(with: frame, context: nil)
            }
            composition.renderSize = cropRect.size
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: pixels)
            out.videoComposition = composition
            out.alwaysCopiesSampleData = false
            videoOut = out
        } else {
            let out = AVAssetReaderTrackOutput(track: video, outputSettings: pixels)
            out.alwaysCopiesSampleData = false
            videoOut = out
        }
        reader.add(videoOut)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalDurationKey: 2]
        if fps > 0 { compression[AVVideoExpectedSourceFrameRateKey] = fps }
        compression[AVVideoProfileLevelKey] = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: cropRect == nil ? AVVideoScalingModeResizeAspect : AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ])
        // Cropped frames come out upright already.
        videoIn.transform = cropRect == nil ? transform : .identity
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if let audioTrack {
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOut)
            let descriptions = try await audioTrack.load(.formatDescriptions)
            let basic = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let rate = min(basic?.mSampleRate ?? 48_000, 48_000)
            let channels = min(Int(basic?.mChannelsPerFrame ?? 2), 2)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: max(channels, 1),
                AVEncoderBitRateKey: (compress ? settings.audioKbps : 192) * 1000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
            audioPair = (audioOut, audioIn)
        }

        guard reader.startReading() else { throw ConvertError(reader.error?.localizedDescription ?? "Couldn't read the video") }
        guard writer.startWriting() else { throw ConvertError(writer.error?.localizedDescription ?? "Couldn't write the video") }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration, 0.01)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoOut, into: videoIn, queue: "video") { time in progress(min(time / total, 0.99)) } }
            if let (audioOut, audioIn) = audioPair {
                group.addTask { await pump(audioOut, into: audioIn, queue: "audio") { _ in } }
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ConvertError(reader.error?.localizedDescription ?? "Reading the video failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConvertError(writer.error?.localizedDescription ?? "Writing the video failed")
        }
        return output
    }

    /// Where the subject is, from the frame halfway through (the middle of the picture if there's none).
    private static func videoFocus(_ asset: AVAsset, duration: Double) async -> CGPoint {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let frame = try? await generator.image(at: CMTime(seconds: max(duration / 2, 0), preferredTimescale: 600)).image else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return focus(of: frame)
    }

    /// Feeds one track from the reader into the writer until it runs out.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue label: String,
                             progress: @escaping @Sendable (Double) -> Void) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "ca.bryanyao.Tutto.convert.\(label)")
            nonisolated(unsafe) var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if let buffer = output.copyNextSampleBuffer() {
                        progress(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                        if !input.append(buffer) {
                            finished = true
                        }
                    } else {
                        finished = true
                    }
                }
                if finished {
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
    }

    /// An animated GIF of the first 30 seconds: 12 frames a second, 480 to 800 pixels wide by quality.
    private static func gif(from source: URL, settings: CompressionSettings, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let duration = min(try await asset.load(.duration).seconds, 30)
        guard duration > 0 else { throw ConvertError("\(source.lastPathComponent) has no frames") }
        let fps = 12.0
        let width: CGFloat = settings.videoQuality == .small ? 480 : settings.videoQuality == .balanced ? 640 : 800
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 2)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let count = max(Int(duration * fps), 1)
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        let output = OutputNames.converted(source, ext: "gif", exists: exists)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConvertError("Couldn't create \(output.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var done = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(destination, image, frame) }
            done += 1
            progress(Double(done) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConvertError("Couldn't write \(output.lastPathComponent)") }
        return output
    }

    /// The sound of a video as M4A, as it is (no re-encoding when it's already AAC).
    private static func soundtrack(of source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConvertError("\(source.lastPathComponent) has no sound")
        }
        let output = OutputNames.converted(source, ext: "m4a", exists: exists)
        try await session.export(to: output, as: .m4a)
        return output
    }

    // MARK: Sound

    private static func audioSettings(_ format: OutputFormat, rate: Double, channels: Int, kbps: Int?) -> [String: Any] {
        let channels = max(min(channels, 2), 1)
        switch format {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(rate, 48_000), AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: (kbps ?? 256) * 1000]
        case .m4aLossless:
            return [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
        case .flac:
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
        case .opus:
            return [AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: (kbps ?? 128) * 1000]
        case .aiff:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        default:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
    }

    private static func audio(_ source: URL, to format: OutputFormat, kbps: Int?, compress: Bool = false,
                              progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw ConvertError("\(source.lastPathComponent) isn't sound macOS can read") }
        let sourceFormat = input.processingFormat
        let output = compress
            ? OutputNames.compressed(source, ext: format.fileExtension, exists: exists)
            : OutputNames.converted(source, ext: format.fileExtension, exists: exists)
        let settings = audioSettings(format, rate: sourceFormat.sampleRate, channels: Int(sourceFormat.channelCount), kbps: kbps)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ConvertError("macOS can't write \(format.title) here (\(error.localizedDescription))")
        }
        let target = file.processingFormat
        let converter = sourceFormat == target ? nil : AVAudioConverter(from: sourceFormat, to: target)
        let chunk: AVAudioFrameCount = 32_768
        let total = max(Double(input.length), 1)
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunk) else { break }
            try input.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            if let converter {
                let ratio = target.sampleRate / sourceFormat.sampleRate
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { break }
                nonisolated(unsafe) var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if let error { throw ConvertError(error.localizedDescription) }
                try file.write(from: converted)
            } else {
                try file.write(from: buffer)
            }
            progress(Double(input.framePosition) / total)
        }
        return output
    }

    // MARK: Documents and subtitles

    @MainActor
    private static func document(_ source: URL, to format: OutputFormat) throws -> URL {
        let output = OutputNames.converted(source, ext: format.fileExtension, exists: exists)
        // Markdown to HTML directly: cleaner than going through the text system.
        if format == .html, ["md", "markdown"].contains(source.pathExtension.lowercased()) {
            let markdown = try String(contentsOf: source, encoding: .utf8)
            try MarkdownHTML.html(markdown, title: source.deletingPathExtension().lastPathComponent)
                .write(to: output, atomically: true, encoding: .utf8)
            return output
        }
        let text = try readDocument(source)
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .pdf:
            try writeDocumentPDF(text, to: output)
        case .txt:
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        default:
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .rtf: .rtf
            case .odt: .openDocument
            default: .html
            }
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: output, options: .withoutOverwriting)
        }
        return output
    }

    @MainActor
    private static func readDocument(_ source: URL) throws -> NSAttributedString {
        let ext = source.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let markdown = try String(contentsOf: source, encoding: .utf8)
            let html = MarkdownHTML.html(markdown, title: source.deletingPathExtension().lastPathComponent)
            guard let text = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                                documentAttributes: nil) else { throw ConvertError("Couldn't read \(source.lastPathComponent)") }
            return text
        }
        do {
            return try NSAttributedString(url: source, options: [:], documentAttributes: nil)
        } catch {
            throw ConvertError("\(source.lastPathComponent) isn't a document macOS can read")
        }
    }

    /// Letter-size pages with one-inch margins, text laid out by Core Text.
    private static func writeDocumentPDF(_ text: NSAttributedString, to url: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw ConvertError("Couldn't create \(url.lastPathComponent)")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: page.insetBy(dx: 72, dy: 72), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if visible.length == 0 { break }
            start += visible.length
        } while start < text.length
        context.closePDF()
    }

    private static func subtitles(_ source: URL, to format: OutputFormat) throws -> URL {
        guard let text = (try? String(contentsOf: source, encoding: .utf8)) ?? (try? String(contentsOf: source, encoding: .isoLatin1)) else {
            throw ConvertError("Couldn't read \(source.lastPathComponent)")
        }
        let cues = Subtitles.parse(text)
        guard !cues.isEmpty else { throw ConvertError("\(source.lastPathComponent) has no subtitles in it") }
        let output = OutputNames.converted(source, ext: format.fileExtension, exists: exists)
        let written = switch format {
        case .srt: Subtitles.srt(cues)
        case .vtt: Subtitles.vtt(cues)
        default: Subtitles.plainText(cues)
        }
        try written.write(to: output, atomically: true, encoding: .utf8)
        return output
    }
}
