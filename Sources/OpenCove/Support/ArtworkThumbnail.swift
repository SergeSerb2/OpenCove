// SPDX-License-Identifier: MIT
import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Immutable decoded pixels can cross to the main actor. AppKit images are
/// created only by the view, after the ImageIO work has finished off-main.
struct CoveArtworkThumbnail: @unchecked Sendable {
    let image: CGImage
    let red: Double
    let green: Double
    let blue: Double
    var tint: Color { Color(red: red, green: green, blue: blue) }
}

actor CoveArtworkCache {
    static let shared = CoveArtworkCache()
    private var entries: [(key: SHA256.Digest, value: CoveArtworkThumbnail)] = []

    func thumbnail(_ data: Data) -> CoveArtworkThumbnail? {
        guard !data.isEmpty, data.count <= 12 * 1024 * 1024 else { return nil }
        let key = SHA256.hash(data: data)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.value
        }
        // 256px covers exceed the resolution needed by the 54/56pt widgets,
        // including Retina. Normalize HDR/wide-color images to eight-bit RGBA
        // so eight cached entries retain at most 2 MiB of decoded pixels.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), decoded.width > 0, decoded.width <= 256,
              decoded.height > 0, decoded.height <= 256,
              let rgba = CGContext(data: nil, width: decoded.width, height: decoded.height,
                                   bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        rgba.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = rgba.makeImage() else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let color = CGColorSpaceCreateDeviceRGB()
        let sampled = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: color,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        let lift: (Int) -> Double = { sampled ? 0.35 + 0.65 * Double(pixel[$0]) / 255 : 1 }
        let value = CoveArtworkThumbnail(image: image, red: lift(0), green: lift(1), blue: lift(2))
        entries.append((key, value))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        return value
    }
}
