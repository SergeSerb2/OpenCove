// SPDX-License-Identifier: MIT
import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI owns the two retained covers and decode-gap policy. This leaf only
/// interpolates the top slot's opacity and reports one revision-checked phase.
@MainActor
struct CoveArtworkTransition: NSViewRepresentable {
    var first: CGImage?
    var second: CGImage?
    var inputIdentity: ObjectIdentifier?
    var showsSecond: Bool
    var sourceIdentifier: String?
    var revision: UInt64
    var fading: Bool
    var size: Double
    var completion: (UInt64) -> Void

    func makeNSView(context: Context) -> CoveArtworkTransitionView {
        CoveArtworkTransitionView(frame: .zero)
    }

    func updateNSView(_ view: CoveArtworkTransitionView, context: Context) {
        view.configure(first: first, second: second, inputIdentity: inputIdentity, showsSecond: showsSecond,
                       sourceIdentifier: sourceIdentifier, revision: revision,
                       fading: fading, completion: completion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoveArtworkTransitionView,
                     context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func dismantleNSView(_ view: CoveArtworkTransitionView, coordinator: ()) {
        view.retire()
    }
}

@MainActor
final class CoveArtworkTransitionView: NSView {
    // Slot order is independent of image/source identity. Only the top layer
    // fades, so an opaque cover always backs the blend, including reversals.
    private let lower = CALayer()
    private let upper = CALayer()
    private var firstImage: ObjectIdentifier?
    private var secondImage: ObjectIdentifier?
    private var sourceIdentifier: String?
    private var revision: UInt64?
    private var pendingRevision: UInt64?
    private var generation: UInt64 = 0
    private var animationStartOpacity: Float = 0
    private var animationDeadline: CFTimeInterval?
    private var completion: ((UInt64) -> Void)?
    private var retired = false
    private static let animationKey = "artworkOpacity"
    private let recordsPhaseOrigin = CovePaths.isDevelopment
        && ProcessInfo.processInfo.arguments.contains("--control-port")
    // One scalar-only phase record in explicit verification launches. No image
    // identity, source text, extra image retention or recurring work is added.
    private var phaseOrigin: [String: Any]?
    // An image identity is a non-retaining scalar. Neither this observation nor
    // the native leaf keeps the third decoded image alive.
    private var distinctInputIdentity: ObjectIdentifier?
    private var distinctInput: [String: Any]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for slot in [lower, upper] {
            slot.contentsGravity = .resizeAspectFill
            slot.masksToBounds = true
            layer?.addSublayer(slot)
        }
        upper.opacity = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in [lower, upper] {
            slot.frame = bounds
            slot.contentsScale = window?.backingScaleFactor ?? 1
        }
        CATransaction.commit()
    }

    override func viewDidHide() { super.viewDidHide(); settleAnimation() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { settleAnimation() }
    }

    func configure(first: CGImage?, second: CGImage?, inputIdentity: ObjectIdentifier?, showsSecond: Bool,
                   sourceIdentifier: String?, revision: UInt64, fading: Bool,
                   completion: @escaping (UInt64) -> Void) {
        guard !retired else { return }
        self.completion = completion
        let changedSource = self.sourceIdentifier != sourceIdentifier
        let firstID = first.map { ObjectIdentifier($0) }
        let secondID = second.map { ObjectIdentifier($0) }
        if recordsPhaseOrigin {
            if changedSource || inputIdentity == nil || distinctInputIdentity != inputIdentity {
                distinctInput = nil
                distinctInputIdentity = nil
            }
            // Observe before the unchanged-slot guard. A ready third cover
            // must be visible to verification even while rendering is deferred.
            if let inputIdentity, let activeRevision = self.revision,
               !changedSource, firstImage != nil, secondImage != nil,
               inputIdentity != firstImage, inputIdentity != secondImage,
               upper.animation(forKey: Self.animationKey) != nil,
               distinctInput == nil {
                let now = CACurrentMediaTime()
                distinctInputIdentity = inputIdentity
                distinctInput = ["readyDuringRevision": activeRevision, "readyAt": now,
                    "animationCount": 1, "presentationOpacity": presentationOpacity,
                    "deadline": animationDeadline.map { $0 as Any } ?? NSNull(),
                    "incomingRevisionUnchanged": self.revision == revision,
                    "incomingFirstUnchanged": firstImage == firstID,
                    "incomingSecondUnchanged": secondImage == secondID,
                    "consumedByRevision": NSNull(), "consumedAt": NSNull()]
            }
            if let inputIdentity, distinctInputIdentity == inputIdentity, distinctInput != nil,
               distinctInput?["consumedByRevision"] is NSNull,
               inputIdentity == firstID || inputIdentity == secondID {
                distinctInput?["consumedByRevision"] = revision
                distinctInput?["consumedAt"] = CACurrentMediaTime()
                distinctInput?["consumedWhileAnimating"] = upper.animation(forKey: Self.animationKey) != nil
            }
        }
        // Completion releases the outgoing slot without changing the revision.
        guard self.revision != revision || changedSource
            || firstImage != firstID || secondImage != secondID else { return }
        let sampledAt = recordsPhaseOrigin ? CACurrentMediaTime() : 0
        let opacity = presentationOpacity
        let sampledUntil = recordsPhaseOrigin ? CACurrentMediaTime() : 0
        let origin: [String: Any]? = recordsPhaseOrigin ? [
            "phaseRevision": revision,
            "previousRevision": self.revision.map { $0 as Any } ?? NSNull(),
            "previousAnimationCount": upper.animation(forKey: Self.animationKey) == nil ? 0 : 1,
            "previousTargetOpacity": upper.opacity, "sampledPresentationOpacity": opacity,
            "sampledAt": sampledAt, "sampledUntil": sampledUntil,
            "previousDeadline": animationDeadline.map { $0 as Any } ?? NSNull(),
            "sourceUnchanged": !changedSource,
            "firstSlotUnchanged": firstImage == firstID, "secondSlotUnchanged": secondImage == secondID
        ] : nil
        if changedSource || self.revision != revision { phaseOrigin = nil }
        self.sourceIdentifier = sourceIdentifier
        self.revision = revision
        pendingRevision = fading ? revision : nil
        animationDeadline = nil
        generation &+= 1
        let completionGeneration = generation
        let animate = fading && !changedSource && !isHiddenOrHasHiddenAncestor
            && window?.isVisible == true && bounds.width > 0 && bounds.height > 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fading {
            CATransaction.setCompletionBlock { [weak self] in
                // A no-animation completion can occur during updateNSView.
                // Deliver every phase after that SwiftUI update has returned.
                Task { @MainActor [weak self] in
                    self?.finish(revision: revision, generation: completionGeneration)
                }
            }
        }
        upper.removeAnimation(forKey: Self.animationKey)
        if changedSource {
            lower.contents = nil
            upper.contents = nil
            firstImage = nil
            secondImage = nil
        }
        // The owner replaces a slot only after it stops contributing. Identity
        // checks also avoid resubmitting unchanged pixels on policy updates.
        if firstImage != firstID { lower.contents = first; firstImage = firstID }
        if secondImage != secondID { upper.contents = second; secondImage = secondID }
        lower.opacity = 1
        upper.opacity = showsSecond ? 1 : 0
        if animate {
            phaseOrigin = origin
            animationStartOpacity = opacity
            // Record before the transaction commits. This is a conservative
            // remaining-time budget even if the render server starts later.
            animationDeadline = CACurrentMediaTime() + CoveMotion.contentFadeDuration
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = opacity
            animation.toValue = upper.opacity
            animation.duration = CoveMotion.contentFadeDuration
            animation.timingFunction = CoveMotion.contentFadeTimingFunction
            upper.add(animation, forKey: Self.animationKey)
            if recordsPhaseOrigin {
                phaseOrigin?["installedFromOpacity"] = (upper.animation(forKey: Self.animationKey) as? CABasicAnimation)?
                    .fromValue as? NSNumber ?? NSNull()
            }
        }
        CATransaction.commit()
    }

    private var presentationOpacity: Float {
        // A reversal can arrive before the first animation transaction renders.
        // With no presentation tree yet, its start is the last visible value.
        upper.presentation()?.opacity
            ?? (upper.animation(forKey: Self.animationKey) == nil ? upper.opacity : animationStartOpacity)
    }

    private func finish(revision: UInt64, generation: UInt64) {
        guard !retired, self.generation == generation, pendingRevision == revision else { return }
        pendingRevision = nil
        animationDeadline = nil
        completion?(revision)
    }

    private func settleAnimation() {
        distinctInputIdentity = nil
        distinctInput = nil
        guard let revision = pendingRevision, upper.animation(forKey: Self.animationKey) != nil else { return }
        generation &+= 1
        let completionGeneration = generation
        animationDeadline = nil
        phaseOrigin = nil
        upper.removeAnimation(forKey: Self.animationKey)
        // The model already holds the target. A hidden or detached leaf never
        // resumes its previous fade when it becomes visible again.
        Task { @MainActor [weak self] in
            self?.finish(revision: revision, generation: completionGeneration)
        }
    }

    func retire() {
        retired = true
        generation &+= 1
        pendingRevision = nil
        animationDeadline = nil
        phaseOrigin = nil
        completion = nil
        distinctInputIdentity = nil
        distinctInput = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        upper.removeAnimation(forKey: Self.animationKey)
        lower.contents = nil
        upper.contents = nil
        firstImage = nil
        secondImage = nil
        CATransaction.commit()
    }

    /// On-demand native state only. No image identity, pixels, source metadata,
    /// observer, or periodic publication is needed to locate an active fade.
    private var motionSnapshot: [String: Any] {
        let animating = upper.animation(forKey: Self.animationKey) != nil
        let remaining = animating
            ? max(0, min(CoveMotion.contentFadeDuration, (animationDeadline ?? 0) - CACurrentMediaTime())) : 0
        return ["visible": !retired && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
                    && window?.occlusionState.contains(.visible) == true,
                "nativeBounds": ["x": bounds.minX, "y": bounds.minY,
                                 "width": bounds.width, "height": bounds.height],
                "animationCount": animating ? 1 : 0,
                "presentationOpacity": presentationOpacity, "targetOpacity": upper.opacity,
                "revision": revision.map { $0 as Any } ?? NSNull(), "remainingSeconds": remaining,
                "phaseOrigin": phaseOrigin.map { $0 as Any } ?? NSNull(),
                "distinctInput": distinctInput.map { $0 as Any } ?? NSNull()]
    }

    static func motionSnapshots(in view: NSView) -> [[String: Any]] {
        if let artwork = view as? CoveArtworkTransitionView { return [artwork.motionSnapshot] }
        return view.subviews.flatMap { motionSnapshots(in: $0) }
    }

    /// Like the native timer ring, AppKit cacheDisplay needs model values for
    /// its synchronous draw. Copy only presentation opacity, then restore the
    /// target without changing animations, completion generations, or images.
    static func withCurrentPresentation(in view: NSView, draw: () -> Void) {
        func collect(_ view: NSView) -> [CoveArtworkTransitionView] {
            if let artwork = view as? CoveArtworkTransitionView { return [artwork] }
            return view.subviews.flatMap { collect($0) }
        }
        let artwork = collect(view)
        let models = artwork.map { $0.upper.opacity }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cover in artwork where cover.upper.animation(forKey: animationKey) != nil {
            cover.upper.opacity = cover.presentationOpacity
        }
        draw()
        for (cover, model) in zip(artwork, models) { cover.upper.opacity = model }
        CATransaction.commit()
    }
}
