//
//  MappedImage.swift
//  TuttoKit
//
//  Pictures whose pixels live in memory of their own, handed straight back to macOS when the
//  picture goes. A picture drawn into an ordinary bitmap lives in the allocator's heap, and on
//  this macOS about half of a freed 432 KB picture stays counted against the app (the
//  allocator keeps it for reuse, and asking for it back returns nothing). Tutto takes many
//  window pictures, so its footprint stayed high long after it had let them go.
//

import CoreGraphics
import Darwin

public enum MappedImage {
    /// A `width × height` picture (8 bits per channel, premultiplied BGRA) drawn by `draw`, whose
    /// pixels are unmapped the moment the last reference to it goes; nil if it can't be made.
    public static func make(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                            draw: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let length = bytesPerRow * height
        guard let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), memory != MAP_FAILED else {
            return nil
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: memory, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: bitmapInfo) else {
            munmap(memory, length)
            return nil
        }
        draw(context)
        // The picture owns the pixels from here on: no copy, and nothing left in the allocator.
        guard let provider = CGDataProvider(dataInfo: nil, data: memory, size: length, releaseData: { _, data, size in
            munmap(UnsafeMutableRawPointer(mutating: data), size)
        }) else {
            munmap(memory, length)
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
