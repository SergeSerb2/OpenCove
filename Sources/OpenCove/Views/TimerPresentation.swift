// SPDX-License-Identifier: MIT
import AppKit
import QuartzCore
import SwiftUI

/// Only mounted labels schedule whole-second display updates. The activity
/// service owns the completion deadline, not these presentation reads.
@MainActor
struct CoveTimerText: View {
    var timer: CoveTimerState

    var body: some View {
        TimelineView(CoveTimerSchedule(paused: !timer.running)) { _ in
            let label = CoveNotchStyle.duration(timer.remaining(at: Date()))
            Text(label).accessibilityLabel("\(label) remaining")
        }
    }
}

private struct CoveTimerSchedule: TimelineSchedule {
    var paused: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        if paused { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1)
            .entries(from: startDate, mode: mode))
    }
}

@MainActor
struct CoveTimerRing: View {
    var timer: CoveTimerState
    var clockRevision: UInt64
    var reduceMotion: Bool
    var color: Color

    var body: some View {
        // Normal progress runs in the render server. Reduced motion retains
        // functional whole-second progress without a continuous animation.
        TimelineView(CoveTimerSchedule(paused: !timer.running || !reduceMotion)) { _ in
            CoveNativeTimerRing(timer: timer, clockRevision: clockRevision, reduceMotion: reduceMotion, color: color)
        }
    }
}

@MainActor
private struct CoveNativeTimerRing: NSViewRepresentable {
    var timer: CoveTimerState
    var clockRevision: UInt64
    var reduceMotion: Bool
    var color: Color

    func makeNSView(context: Context) -> CoveTimerProgressView {
        CoveTimerProgressView(frame: .zero)
    }

    func updateNSView(_ view: CoveTimerProgressView, context: Context) {
        view.configure(timer: timer, clockRevision: clockRevision, reduceMotion: reduceMotion, color: NSColor(color))
    }

    static func dismantleNSView(_ view: CoveTimerProgressView, coordinator: ()) {
        view.retire()
    }
}

@MainActor
final class CoveTimerProgressView: NSView {
    private let arc = CAShapeLayer()
    private var timer = CoveTimerState()
    private var clockRevision: UInt64 = 0
    private var reduceMotion = false
    private var color = NSColor.white
    private var retired = false
    private var windowObservation: NSObjectProtocol?
    private static let animationKey = "timerDeadline"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 5
        arc.lineCap = .round
        layer?.addSublayer(arc)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); reconcile() }
    override func viewDidHide() { super.viewDidHide(); reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcile() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        if let window, !retired {
            windowObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        reconcile()
    }

    func configure(timer: CoveTimerState, clockRevision: UInt64, reduceMotion: Bool, color: NSColor) {
        if self.timer != timer || self.clockRevision != clockRevision { arc.removeAnimation(forKey: Self.animationKey) }
        self.timer = timer
        self.clockRevision = clockRevision
        self.reduceMotion = reduceMotion
        self.color = color
        reconcile()
    }

    private var isPresented: Bool {
        !retired && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
    }

    private func reconcile() {
        let remaining = timer.remaining(at: Date())
        let fraction = CoveNotchStyle.fraction(remaining / max(1, timer.duration))
        let animate = timer.running && remaining > 0 && !reduceMotion && isPresented
            && bounds.width > 0 && bounds.height > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: min(bounds.width, bounds.height) / 2,
                    startAngle: .pi / 2, endAngle: -.pi * 1.5, clockwise: true)
        arc.path = path
        arc.strokeColor = color.cgColor
        arc.strokeEnd = animate ? 0 : fraction
        if !animate {
            arc.removeAnimation(forKey: Self.animationKey)
        } else if arc.animation(forKey: Self.animationKey) == nil {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = fraction
            animation.toValue = 0
            animation.duration = remaining
            // A backwards clock change can put the deadline more than one
            // duration ahead. Match the model's full-progress clamp first.
            let delay = max(0, (timer.endsAt?.timeIntervalSinceNow ?? remaining) - remaining)
            if delay > 0 {
                animation.beginTime = arc.convertTime(CACurrentMediaTime(), from: nil) + delay
                animation.fillMode = .backwards
            }
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    func retire() {
        retired = true
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        arc.removeAnimation(forKey: Self.animationKey)
    }

    /// On-demand reads of the actual native layer; no diagnostic ticker.
    private var motionSnapshot: [String: Any] {
        ["visible": isPresented, "running": timer.running, "reduceMotion": reduceMotion,
         "animationCount": arc.animation(forKey: Self.animationKey) == nil ? 0 : 1,
         "fraction": arc.presentation()?.strokeEnd ?? arc.strokeEnd,
         "remaining": timer.remaining(at: Date())]
    }

    static func motionSnapshots(in view: NSView) -> [[String: Any]] {
        if let progress = view as? CoveTimerProgressView { return [progress.motionSnapshot] }
        return view.subviews.flatMap { motionSnapshots(in: $0) }
    }

    /// AppKit's caching renderer reads model layers. Freeze their actual
    /// presentation values only during this synchronous native capture; the
    /// transaction restores the models without removing or restarting motion.
    static func withCurrentPresentation(in view: NSView, draw: () -> Void) {
        func collect(_ view: NSView) -> [CoveTimerProgressView] {
            if let progress = view as? CoveTimerProgressView { return [progress] }
            return view.subviews.flatMap { collect($0) }
        }
        let progress = collect(view)
        let models = progress.map { $0.arc.strokeEnd }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in progress where ring.arc.animation(forKey: animationKey) != nil {
            ring.arc.strokeEnd = ring.arc.presentation()?.strokeEnd
                ?? CGFloat(CoveNotchStyle.fraction(ring.timer.remaining(at: Date()) / max(1, ring.timer.duration)))
        }
        draw()
        for (ring, model) in zip(progress, models) { ring.arc.strokeEnd = model }
        CATransaction.commit()
    }
}
