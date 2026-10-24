// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Displays measured RMS time bins only. Native presentation supplies a consumer
/// lease; the store owns opt-in and an explicit settings action owns consent.
/// An unavailable meter is a quiet, static row of equal bars.
@MainActor
struct LiveWaveformView: View {
    @ObservedObject var controller: AudioWaveformController
    var isPlaying: Bool
    var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<8) { index in
                Capsule()
                    .fill(color.opacity(controller.available ? 0.95 : 0.4))
                    .frame(width: 2, height: height(at: index))
            }
        }
        .frame(width: 28, height: 20)
        .background {
            WaveformConsumer(controller: controller)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // No timer, sine animation, or playback-derived amplitude is used.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.available ? "System audio levels" : (isPlaying ? "Playing" : "Paused"))
        .accessibilityValue(controller.status)
        .help(controller.lastError ?? controller.status)
    }

    private func height(at index: Int) -> CGFloat {
        guard controller.available, controller.levels.indices.contains(index) else { return 2 }
        let value = controller.levels[index]
        let level = value.isFinite ? min(1, max(0, value)) : 0
        return 2 + CGFloat(level) * 16
    }
}

/// SwiftUI appearance alone does not cover a mounted but hidden hosting view,
/// an ordered-out panel, or a clipped lock widget. Keep the lease on the native
/// view so a retained, presented outgoing transition remains a consumer too.
@MainActor
private struct WaveformConsumer: NSViewRepresentable {
    let controller: AudioWaveformController

    func makeNSView(context: Context) -> WaveformConsumerView {
        let view = WaveformConsumerView(frame: .zero)
        view.configure(controller: controller)
        return view
    }

    func updateNSView(_ view: WaveformConsumerView, context: Context) {
        view.configure(controller: controller)
    }

    static func dismantleNSView(_ view: WaveformConsumerView, coordinator: ()) {
        view.retire()
    }
}

@MainActor
private final class WaveformConsumerView: NSView {
    private let consumerID = UUID()
    private weak var controller: AudioWaveformController?
    private var requestedPresentation = false
    private var retired = false
    private var presentationTask: Task<Void, Never>?
    private var viewObservations: [NSKeyValueObservation] = []
    private var presentationObservations: [NSObjectProtocol] = []
    private var windowAlphaObservation: NSKeyValueObservation?

    deinit {
        presentationTask?.cancel()
        for token in presentationObservations { NotificationCenter.default.removeObserver(token) }
        let controller = controller, id = consumerID
        Task { @MainActor in controller?.setConsumerPresented(id, presented: false) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(controller: AudioWaveformController) {
        guard !retired, self.controller !== controller else { return }
        releaseController()
        self.controller = controller
        reconcilePresentation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observePresentation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observePresentation()
    }

    override func viewDidHide() { super.viewDidHide(); reconcilePresentation() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcilePresentation() }
    override func layout() { super.layout(); reconcilePresentation() }

    private var isPresented: Bool {
        guard !retired, let window, window.isVisible, !window.isMiniaturized,
              window.alphaValue > 0, window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return false }
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return false }
        var ancestor: NSView? = self
        while let view = ancestor {
            guard view.alphaValue > 0 else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func observePresentation() {
        viewObservations.removeAll()
        for token in presentationObservations { NotificationCenter.default.removeObserver(token) }
        presentationObservations.removeAll()
        windowAlphaObservation = nil
        guard !retired, window != nil else { reconcilePresentation(); return }

        // Observe only this view's native ancestry/window. No desktop inventory,
        // permission polling, timer, or input monitor is needed. Bounds changes
        // include scrolling a lock waveform out of its clip view.
        var ancestor: NSView? = self
        while let view = ancestor {
            viewObservations.append(view.observe(\.alphaValue) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcilePresentation() }
            })
            // Use AppKit's geometry notifications, including setters such as
            // scrollToPoint that need not go through a KVO-observed bounds setter.
            // As with CoveMediaRegionView, enable these on the local ancestry.
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                presentationObservations.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcilePresentation() }
                })
            }
            ancestor = view.superview
        }
        if let window {
            windowAlphaObservation = window.observe(\.alphaValue) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcilePresentation() }
            }
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                presentationObservations.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcilePresentation() }
                })
            }
        }
        reconcilePresentation()
    }

    private func reconcilePresentation() {
        let presented = isPresented
        guard presented != requestedPresentation else { return }
        requestedPresentation = presented
        presentationTask?.cancel()
        // Leave the SwiftUI/AppKit update before publishing controller changes.
        // Recheck native presentation so a queued appearance cannot acquire a
        // lease after hiding, detachment, or dismantle.
        presentationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !self.retired else { return }
            self.presentationTask = nil
            let presented = self.isPresented
            self.requestedPresentation = presented
            self.controller?.setConsumerPresented(self.consumerID, presented: presented)
        }
    }

    private func releaseController() {
        presentationTask?.cancel()
        presentationTask = nil
        requestedPresentation = false
        let controller = controller, id = consumerID
        self.controller = nil
        // This release survives native view destruction. The ID belongs to this
        // view only, so it cannot retire another panel or a replacement view.
        Task { @MainActor in controller?.setConsumerPresented(id, presented: false) }
    }

    func retire() {
        retired = true
        viewObservations.removeAll()
        for token in presentationObservations { NotificationCenter.default.removeObserver(token) }
        presentationObservations.removeAll()
        windowAlphaObservation = nil
        releaseController()
    }
}
