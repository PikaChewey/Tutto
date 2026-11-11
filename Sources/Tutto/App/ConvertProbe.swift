//
//  ConvertProbe.swift
//  Tutto
//
//  Debug builds only: `Tutto --convert-probe DIR` makes test files (photos with location data, a
//  screenshot-like PNG, a PDF of photos, a two-second video with sound, a WAV, Markdown, a Word
//  file, subtitles), runs every Convert and Compress path on them and writes DIR/report.txt with
//  each result's size and what macOS reads back from it. Nothing on screen.
//

#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import TuttoKit
import UniformTypeIdentifiers

@MainActor
enum ConvertProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--convert-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        var done = false
        Task { @MainActor in
            await run(dir, say: say)
            done = true
        }
        let started = Date()
        while !done, Date().timeIntervalSince(started) < 240 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !done { say("TIMED OUT") }
        return true
    }

    private static func run(_ dir: URL, say: @escaping (String) -> Void) async {
        let fixtures = dir.appendingPathComponent("in", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let photo = fixtures.appendingPathComponent("photo.jpg")
        let rotated = fixtures.appendingPathComponent("sideways.jpg")
        let screenshot = fixtures.appendingPathComponent("screenshot.png")
        let pdf = fixtures.appendingPathComponent("photos.pdf")
        let video = fixtures.appendingPathComponent("clip.mov")
        let wav = fixtures.appendingPathComponent("tone.wav")
        let markdown = fixtures.appendingPathComponent("notes.md")
        let word = fixtures.appendingPathComponent("letter.docx")
        let srt = fixtures.appendingPathComponent("talk.srt")
        do {
            try makePhoto(photo, orientation: 1, gps: true)
            try makePhoto(rotated, orientation: 6, gps: false)
            try makeScreenshot(screenshot)
            try makePDF(pdf, photo: photo)
            try makeTone(wav)
            try await makeVideo(video, tone: wav)
            try "# Notes\n\nSome **bold** and *italic*.\n\n- one\n- two\n".write(to: markdown, atomically: true, encoding: .utf8)
            let letter = NSAttributedString(string: "Dear reader,\n\nThis letter was written by the probe.\n",
                                            attributes: [.font: NSFont.systemFont(ofSize: 14)])
            try letter.data(from: NSRange(location: 0, length: letter.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                .write(to: word)
            try "1\n00:00:01,000 --> 00:00:02,500\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nBye.\n".write(to: srt, atomically: true, encoding: .utf8)
        } catch {
            say("FIXTURES FAILED: \(error.localizedDescription)")
            return
        }
        say("fixtures ready")

        var compress = CompressionSettings()
        func attempt(_ label: String, _ action: ConvertAction, _ sources: [URL], settings: CompressionSettings? = nil) async {
            let started = Date()
            do {
                let outputs = try await ConvertEngine.run(action, on: sources, settings: settings ?? compress) { _ in }
                for output in outputs {
                    let before = sources.reduce(0) { $0 + ConvertEngine.size($1) }
                    say(String(format: "OK   %-34@ %@ %@ → %@ (%.2f s) %@", label as NSString, sources.map(\.lastPathComponent).joined(separator: "+"),
                               bytes(before), bytes(ConvertEngine.size(output)), Date().timeIntervalSince(started), await describe(output)))
                }
            } catch {
                say("FAIL \(label): \(error.localizedDescription)")
            }
        }

        for format in ConvertPlanner.targets(for: .image) { await attempt("photo → \(format.title)", .convert(format), [photo]) }
        await attempt("sideways → PNG (upright?)", .convert(.png), [rotated])
        await attempt("compress photo q0.6 1280 strip", .compress, [photo], settings: {
            var s = compress; s.imageQuality = 0.6; s.imageMaxSide = 1280; s.removeImageDetails = true; return s
        }())
        await attempt("compress photo to 80 KB", .compress, [photo], settings: {
            var s = compress; s.imageTargetBytes = 80_000; return s
        }())
        await attempt("compress screenshot PNG (palette)", .compress, [screenshot])
        await attempt("photos into one PDF", .convert(.pdf), [photo, rotated, screenshot])
        for format in ConvertPlanner.targets(for: .pdf) { await attempt("pdf → \(format.title)", .convert(format), [pdf]) }
        compress.pdfLevel = .light
        await attempt("compress PDF light", .compress, [pdf])
        compress.pdfLevel = .strong
        await attempt("compress PDF strong", .compress, [pdf])
        for format in ConvertPlanner.targets(for: .video) { await attempt("video → \(format.title)", .convert(format), [video]) }
        compress.videoQuality = .small
        compress.videoMaxHeight = 480
        await attempt("compress video small 480p", .compress, [video])
        for format in ConvertPlanner.targets(for: .audio) { await attempt("wav → \(format.title)", .convert(format), [wav]) }
        await attempt("compress wav (AAC 96)", .compress, [wav], settings: { var s = compress; s.audioKbps = 96; return s }())
        for format in ConvertPlanner.targets(for: .document) { await attempt("md → \(format.title)", .convert(format), [markdown]) }
        await attempt("docx → PDF", .convert(.pdf), [word])
        await attempt("docx → RTF", .convert(.rtf), [word])
        await attempt("srt → VTT", .convert(.vtt), [srt])
        await attempt("srt → Text", .convert(.txt), [srt])
        say("done")
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// What macOS reads back: picture size, orientation and whether location survived; video
    /// size, codec and length; sound format; PDF pages; text length.
    private static func describe(_ url: URL) async -> String {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return "[folder of \(files.count): \(files.sorted().prefix(3).joined(separator: ", "))…]"
        }
        switch FileKind.of(url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return "[unreadable]" }
            let gps = p[kCGImagePropertyGPSDictionary] != nil
            let frames = CGImageSourceGetCount(source)
            let colorModel = p[kCGImagePropertyColorModel] as? String ?? "?"
            return "[\(p[kCGImagePropertyPixelWidth] ?? "?")×\(p[kCGImagePropertyPixelHeight] ?? "?") orient=\(p[kCGImagePropertyOrientation] ?? 1) gps=\(gps) frames=\(frames) model=\(colorModel)]"
        case .pdf:
            return "[\(PDFDocument(url: url)?.pageCount ?? -1) pages]"
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            var parts: [String] = []
            if let duration = try? await asset.load(.duration).seconds { parts.append(String(format: "%.2fs", duration)) }
            for track in (try? await asset.load(.tracks)) ?? [] {
                let codes = ((try? await track.load(.formatDescriptions)) ?? []).map { d -> String in
                    let c = CMFormatDescriptionGetMediaSubType(d)
                    return String(bytes: [UInt8(c >> 24 & 255), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)], encoding: .ascii) ?? "?"
                }
                if track.mediaType == .video, let size = try? await track.load(.naturalSize) {
                    parts.append("\(Int(size.width))×\(Int(size.height)) \(codes.joined())")
                } else {
                    parts.append(codes.joined())
                }
            }
            return "[\(parts.joined(separator: " "))]"
        default:
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let data = (try? Data(contentsOf: url)) ?? Data()
            return "[\(data.count) bytes\(text.isEmpty ? "" : ", begins \"\(text.prefix(28).replacingOccurrences(of: "\n", with: "⏎"))\"")]"
        }
    }

    // MARK: Fixtures

    private static func gradient(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let noise = Double((x * 7919 + y * 104_729) % 97) / 400
                context.setFillColor(CGColor(red: Double(x) / Double(width), green: Double(y) / Double(height), blue: 0.5 + noise, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return context.makeImage()!
    }

    private static func makePhoto(_ url: URL, orientation: Int, gps: Bool) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95,
                                           kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Probe lens"]]
        if gps { properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 43.47, kCGImagePropertyGPSLatitudeRef: "N",
                                                              kCGImagePropertyGPSLongitude: 80.54, kCGImagePropertyGPSLongitudeRef: "W"] }
        CGImageDestinationAddImage(destination, gradient(width: 3000, height: 2000), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError("photo fixture") }
    }

    /// Flat colours and text, like a screenshot (a good palette PNG).
    private static func makeScreenshot(_ url: URL) throws {
        let width = 1600, height = 1000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for row in 0..<30 {
            NSColor(calibratedHue: CGFloat(row % 6) / 6, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: 40, y: 40 + row * 30, width: 18, height: 18).fill()
            ("Row \(row): the quick brown fox jumps over the lazy dog" as NSString)
                .draw(at: NSPoint(x: 70, y: 38 + row * 30), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError("screenshot fixture") }
    }

    private static func makePDF(_ url: URL, photo: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let picture = gradient(width: 2400, height: 3200)
        for page in 0..<2 {
            context.beginPDFPage(nil)
            context.draw(picture, in: box.insetBy(dx: 36, dy: 80))
            let ns = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            ("Page \(page + 1) of the probe PDF" as NSString).draw(at: NSPoint(x: 72, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Two seconds of 1280 × 720 at 30 fps, then the probe's tone added as its sound (written
    /// separately and joined by a composition: one writer with both waits on itself).
    private static func makeVideo(_ url: URL, tone: URL) async throws {
        let silent = url.deletingLastPathComponent().appendingPathComponent("frames.mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280,
                                                                          AVVideoHeightKey: 720,
                                                                          AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
            for y in 0..<720 {
                let row = UInt32(y % 256) << 8
                for x in 0..<1280 { base[y * stride + x] = 0xFF00_0000 | UInt32((x * y + frame) % 256) << 16 | row | UInt32((x + frame * 8) % 256) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ConvertError("video fixture: \(writer.error?.localizedDescription ?? "?")") }

        let composition = AVMutableComposition()
        let pictures = AVURLAsset(url: silent), sound = AVURLAsset(url: tone)
        let length = CMTime(seconds: 2, preferredTimescale: 600)
        if let track = try await pictures.loadTracks(withMediaType: .video).first,
           let into = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try into.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        }
        if let track = try await sound.loadTracks(withMediaType: .audio).first,
           let into = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try into.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConvertError("video fixture export")
        }
        try await export.export(to: url, as: .mov)
        try? FileManager.default.removeItem(at: silent)
    }

    private static func makeTone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300)!
        pcm.frameLength = 132_300
        for i in 0..<132_300 {
            let value = Float(sin(2 * Double.pi * 330 * Double(i) / 44_100) * 0.3)
            pcm.floatChannelData![0][i] = value
            pcm.floatChannelData![1][i] = value
        }
        try file.write(from: pcm)
    }
}
#endif
