import AppKit
import Foundation

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasSuffix(".iconset") else {
    fputs("usage: swift script/make_icon.swift /path/to/OpenCove.iconset\n", stderr)
    exit(2)
}
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: target.path) else {
    fputs("Icon output already exists. Use a fresh .iconset directory.\n", stderr)
    exit(2)
}
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let rect = NSRect(x: 55, y: 55, width: 914, height: 914)
        let background = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.11, green: 0.19, blue: 0.16, alpha: 1), ending: NSColor(red: 0.025, green: 0.065, blue: 0.05, alpha: 1))!.draw(in: background, angle: -45)
        let cove = NSBezierPath()
        cove.move(to: NSPoint(x: 208, y: 725))
        cove.line(to: NSPoint(x: 816, y: 725))
        cove.curve(to: NSPoint(x: 770, y: 675), controlPoint1: NSPoint(x: 790, y: 725), controlPoint2: NSPoint(x: 770, y: 705))
        cove.line(to: NSPoint(x: 770, y: 450))
        cove.curve(to: NSPoint(x: 654, y: 334), controlPoint1: NSPoint(x: 770, y: 380), controlPoint2: NSPoint(x: 724, y: 334))
        cove.line(to: NSPoint(x: 370, y: 334))
        cove.curve(to: NSPoint(x: 254, y: 450), controlPoint1: NSPoint(x: 300, y: 334), controlPoint2: NSPoint(x: 254, y: 380))
        cove.line(to: NSPoint(x: 254, y: 675))
        cove.curve(to: NSPoint(x: 208, y: 725), controlPoint1: NSPoint(x: 254, y: 705), controlPoint2: NSPoint(x: 234, y: 725))
        cove.close()
        NSColor(red: 0.48, green: 0.91, blue: 0.72, alpha: 1).setFill(); cove.fill()
        NSColor(red: 0.06, green: 0.17, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 352, y: 590, width: 320, height: 50), xRadius: 25, yRadius: 25).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
