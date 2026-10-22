// SPDX-License-Identifier: MIT
import AppKit
import QuartzCore
import SwiftUI

/// Decorative playback state, not captured audio. Native layers keep its motion
/// independent of SwiftUI's display-link schedule and observable model updates.
@MainActor
struct CoveAudioBars: NSViewRepresentable {
    var isPlaying: Bool
    var reduceMotion: Bool
    var color: Color

    func makeNSView(context: Context) -> CovePlaybackIndicatorView {
        CovePlaybackIndicatorView(frame: .zero)
    }

    func updateNSView(_ view: CovePlaybackIndicatorView, context: Context) {
        view.configure(playing: isPlaying, reduceMotion: reduceMotion, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CovePlaybackIndicatorView,
                     context: Context) -> CGSize? {
        CGSize(width: 23, height: 20)
    }

    static func dismantleNSView(_ view: CovePlaybackIndicatorView, coordinator: ()) {
        view.retire()
    }
}

@MainActor
final class CovePlaybackIndicatorView: NSView {
    private let bars = (0..<5).map { _ in CALayer() }
    private var playing = false
    private var reduceMotion = false
    private var color = NSColor.white
    private var windowObservation: NSObjectProtocol?
    private static let animationKey = "playbackPulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for bar in bars {
            bar.cornerRadius = 1.25
            layer?.addSublayer(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 23, height: 20) }
    // This decoration must not intercept the compact surface's button target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(playing: Bool, reduceMotion: Bool, color: NSColor) {
        self.playing = playing
        self.reduceMotion = reduceMotion
        self.color = color
        setAccessibilityLabel(playing ? "Playing" : "Paused")
        reconcile()
    }

    override func layout() { super.layout(); reconcile() }
    override func viewDidHide() { super.viewDidHide(); reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcile() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        if let window {
            windowObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        reconcile()
    }

    private var isPresented: Bool {
        !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
    }

    private func reconcile() {
        let animate = playing && !reduceMotion && isPresented && bounds.width > 0 && bounds.height > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fill = color.withAlphaComponent(playing ? 0.95 : 0.5).cgColor
        for (index, bar) in bars.enumerated() {
            let height = playing ? CoveMotion.audioBarRestHeights[index] : 3
            bar.bounds = CGRect(x: 0, y: 0, width: 2.5, height: height)
            bar.position = CGPoint(x: (bounds.width - 22.5) / 2 + 1.25 + Double(index) * 5,
                                   y: bounds.height / 2)
            bar.backgroundColor = fill
            guard animate else { bar.removeAnimation(forKey: Self.animationKey); continue }
            // Preserve phase through color/layout updates. Only lifecycle or
            // playback changes remove the render-server animation.
            guard bar.animation(forKey: Self.animationKey) == nil else { continue }
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let heights: [Double] = (0...32).map { sample -> Double in
                let phase = Double(sample) / 32.0 * 2.0 * Double.pi + Double(index) * 1.6
                return 4.0 + (sin(phase) + 1.0) * 7.0
            }
            animation.values = heights
            animation.duration = CoveMotion.audioBarPeriod(index: index)
            animation.calculationMode = .linear
            animation.repeatCount = .infinity
            bar.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    func retire() {
        playing = false
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        for bar in bars { bar.removeAnimation(forKey: Self.animationKey) }
    }

    /// Read-only diagnostics from real native layers; no metadata or per-frame
    /// publication is added to the app's normal state path.
    private var motionSnapshot: [String: Any] {
        var value: [String: Any] = ["visible": isPresented, "playing": playing, "reduceMotion": reduceMotion,
         "animationCount": bars.filter { $0.animation(forKey: Self.animationKey) != nil }.count,
         "heights": bars.map { $0.presentation()?.bounds.height ?? $0.bounds.height },
         "accessibilityLabel": accessibilityLabel() ?? ""]
        if let fill = bars.first?.backgroundColor,
           let color = NSColor(cgColor: fill)?.usingColorSpace(.sRGB) {
            value["rgba"] = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        return value
    }

    static func motionSnapshots(in view: NSView) -> [[String: Any]] {
        if let indicator = view as? CovePlaybackIndicatorView { return [indicator.motionSnapshot] }
        return view.subviews.flatMap { motionSnapshots(in: $0) }
    }
}
