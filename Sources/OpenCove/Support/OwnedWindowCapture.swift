import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One-shot compositor capture for explicitly enabled development controls.
/// Never enumerates desktop content, asks for permission, or keeps a screenshot.
@MainActor
final class OwnedWindowCapture {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Weak references must not keep a retired panel or its content root alive
    // while ScreenCaptureKit finishes a non-cancellable screenshot request.
    private weak var window: NSWindow?
    private weak var content: NSView?
    private let windowID: CGWindowID
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let frame: CGRect
    private let bounds: CGRect
    private let scale: CGFloat
    private static let maximumDimension = 4_096
    private static let maximumPixels = 4_194_304
    private static let maximumBytes = 16_777_216

    init(window: NSWindow) throws {
        guard let content = window.contentView,
              window.windowNumber > 0, let id = CGWindowID(exactly: window.windowNumber) else {
            throw Failure(message: "The owned native notch window is unavailable.")
        }
        self.window = window
        self.content = content
        windowID = id
        frame = window.frame
        bounds = content.bounds
        scale = window.backingScaleFactor
        try validateWindow()
    }

    func png(validateSource: () throws -> Void) async throws -> Data {
        try validate(validateSource)
        let owned = try await shareableWindow()
        try validate(validateSource)
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let pixelScale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        guard filter.style == .window, pixelScale.isFinite, (1...4).contains(pixelScale),
              abs(pixelScale - scale) < 0.001,
              size.width.isFinite, size.height.isFinite,
              abs(size.width - frame.width) <= 1 / scale,
              abs(size.height - frame.height) <= 1 / scale else {
            throw Failure(message: "The owned window's compositor size or scale changed. Retry after layout settles.")
        }
        let width = ceil(size.width * pixelScale), height = ceil(size.height * pixelScale)
        guard width > 0, height > 0,
              width <= CGFloat(Self.maximumDimension), height <= CGFloat(Self.maximumDimension),
              width * height <= CGFloat(Self.maximumPixels) else {
            throw Failure(message: "Owned-window capture exceeds the 4096-pixel edge or 4-megapixel limit.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.captureDynamicRange = .SDR

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            try validate(validateSource)
            throw Failure(message: "ScreenCaptureKit could not capture the owned notch window. No permission request or fallback was used.")
        }
        // The system request has no cancellation handle. Discard late results;
        // the caller keeps its render-busy guard until this operation finishes.
        try validate(validateSource)
        _ = try await shareableWindow()
        try validate(validateSource)
        guard image.width == configuration.width, image.height == configuration.height,
              image.bitsPerPixel == 32, image.bytesPerRow > 0,
              image.bytesPerRow <= Self.maximumBytes / image.height else {
            throw Failure(message: "ScreenCaptureKit returned unexpected or oversized owned-window pixels.")
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              !png.isEmpty, png.count <= Self.maximumBytes else {
            throw Failure(message: "Owned-window PNG encoding failed or exceeded the 16 MiB limit.")
        }
        try validate(validateSource)
        return png
    }

    private func validate(_ source: () throws -> Void) throws {
        try Task.checkCancellation()
        try source()
        try validateWindow()
    }

    private func validateWindow() throws {
        guard let window, let content,
              NSApp.windows.contains(where: { $0 === window }), !NSApp.isHidden,
              window.windowNumber == Int(windowID), window.contentView === content,
              content.window === window, !content.isHiddenOrHasHiddenAncestor,
              window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
              window.occlusionState.contains(.visible), window.alphaValue > 0,
              NotchPanelController.contentIsHidden(in: window) == false,
              window.screen != nil, window.frame == frame, content.bounds == bounds,
              window.backingScaleFactor == scale,
              scale.isFinite, (1...4).contains(scale),
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              frame.width <= 2_048, frame.height <= 2_048,
              bounds.width == frame.width, bounds.height == frame.height,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            throw Failure(message: "The owned notch window is hidden, retired, resized, or outside the active session. Read fresh state and retry.")
        }
    }

    private func shareableWindow() async throws -> SCWindow {
        let current: SCShareableContent
        do {
            // SDK contract (macOS 14.4+): current-process content is available
            // without TCC consent. Do not substitute the broader current API.
            current = try await SCShareableContent.currentProcess
        } catch {
            try Task.checkCancellation()
            throw Failure(message: "ScreenCaptureKit current-process content is unavailable. No permission request or fallback was used.")
        }
        try Task.checkCancellation()
        let matches = current.windows.filter {
            $0.windowID == windowID && $0.owningApplication?.processID == pid
        }
        guard matches.count == 1, let owned = matches.first, owned.isOnScreen,
              owned.frame.width.isFinite, owned.frame.height.isFinite,
              abs(owned.frame.width - frame.width) <= 1 / scale,
              abs(owned.frame.height - frame.height) <= 1 / scale else {
            throw Failure(message: "The owned notch window is absent or changed in current-process compositor content. No desktop fallback was used.")
        }
        return owned
    }
}
