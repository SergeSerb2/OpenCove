// SPDX-License-Identifier: MIT
import AppKit
import QuartzCore
import SwiftUI

/// Keep readable overflow motion on a native layer, outside the SwiftUI model's
/// update path. SwiftUI owns the text, styling, and reduced-motion preference.
@MainActor
struct CoveScrollingMediaText: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    var color = NSColor.white
    var reduceMotion = false
    var helpText: String?

    func makeNSView(context: Context) -> CoveScrollingMediaTextView {
        CoveScrollingMediaTextView(frame: .zero)
    }

    func updateNSView(_ view: CoveScrollingMediaTextView, context: Context) {
        view.configure(text: text, font: .systemFont(ofSize: size, weight: weight),
                       color: color, animate: !reduceMotion, help: helpText ?? text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoveScrollingMediaTextView,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.naturalSize.width,
               height: nsView.naturalSize.height)
    }

    static func dismantleNSView(_ view: CoveScrollingMediaTextView, coordinator: ()) {
        view.retire()
    }
}

@MainActor
final class CoveScrollingMediaTextView: NSView {
    private let label = CoveAccessibleMediaLabel(labelWithString: "")
    private var allowsAnimation = false
    private var displayWasTruncated = false
    private var windowObservation: NSObjectProtocol?
    private var animatedDistance: CGFloat?
    private var leftInset: CGFloat = 0
    private var rightInset: CGFloat = 0
    private(set) var naturalSize = NSSize.zero
    private static let animationKey = "readOverflow"
    private static let maximumTextUnits = 1_024
    private static let maximumAnimatedPixelWidth: CGFloat = 4_096

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        label.wantsLayer = true
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: naturalSize.height)
    }

    func configure(text: String, font: NSFont, color: NSColor, animate: Bool, help: String) {
        let contentChanged = label.sourceText != text || label.font != font
        if contentChanged {
            stopScrolling()
            label.sourceText = text
            let display = Self.bounded(text)
            label.stringValue = display.text
            displayWasTruncated = display.truncated
            label.font = font
            label.lineBreakMode = .byClipping
            // Measure without ever assigning a potentially huge backing frame.
            naturalSize = label.cell?.cellSize ?? .zero
            // Map the cell's actual text area onto the SwiftUI layout edge.
            // Native text-field insets must not add an extra header gutter.
            let measuredBounds = NSRect(origin: .zero, size: naturalSize)
            if let rect = label.cell?.titleRect(forBounds: measuredBounds),
               rect.width > 0, rect.width.isFinite,
               rect.minX >= 0, rect.maxX <= measuredBounds.maxX {
                leftInset = rect.minX
                rightInset = measuredBounds.maxX - rect.maxX
                naturalSize.width = rect.width
            } else {
                leftInset = 0
                rightInset = 0
            }
            invalidateIntrinsicContentSize()
        }
        let tooltip = Self.bounded(help).text
        if toolTip != tooltip { toolTip = tooltip }
        if label.textColor != color { label.textColor = color }
        if allowsAnimation != animate {
            allowsAnimation = animate
            stopScrolling()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        reconcileScrolling()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        if let window {
            windowObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileScrolling() }
            }
        }
        reconcileScrolling()
    }

    override func viewDidHide() { super.viewDidHide(); reconcileScrolling() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcileScrolling() }

    private var isPresented: Bool {
        !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
    }

    private var mayScroll: Bool { allowsAnimation && isPresented }

    private var backingScale: CGFloat { max(1, window?.backingScaleFactor ?? 2) }

    private static func bounded(_ text: String) -> (text: String, truncated: Bool) {
        var units = Array(text.utf16.prefix(maximumTextUnits + 1))
        guard units.count > maximumTextUnits else { return (text, false) }
        units.removeLast()
        // Do not split a UTF-16 surrogate pair at the display boundary.
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return (String(decoding: units, as: UTF16.self) + "…", true)
    }

    private func reconcileScrolling() {
        guard bounds.width.isFinite, bounds.height.isFinite else { stopScrolling(); return }
        let distance = max(0, naturalSize.width - bounds.width)
        let withinPixelBudget = (naturalSize.width + leftInset + rightInset) * backingScale
            <= Self.maximumAnimatedPixelWidth
        let animate = mayScroll && !displayWasTruncated && withinPixelBudget
            && bounds.width > 1 && distance > 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = NSRect(x: -leftInset, y: max(0, (bounds.height - naturalSize.height) / 2),
                           width: (animate ? naturalSize.width : max(0, bounds.width)) + leftInset + rightInset,
                           height: naturalSize.height)
        if label.frame != frame { label.frame = frame }
        let lineBreak: NSLineBreakMode = animate ? .byClipping : .byTruncatingTail
        if label.lineBreakMode != lineBreak { label.lineBreakMode = lineBreak }
        CATransaction.commit()
        guard animate else { stopScrolling(); return }
        if let animatedDistance, abs(animatedDistance - distance) < 0.5,
           label.layer?.animation(forKey: Self.animationKey) != nil { return }
        stopScrolling()
        let travel = Double(distance) / CoveMotion.mediaTextPointsPerSecond
        let hold = CoveMotion.mediaTextPause
        let duration = 2 * (hold + travel)
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -Double(distance), -Double(distance), 0]
        animation.keyTimes = [0, NSNumber(value: hold / duration),
                              NSNumber(value: (hold + travel) / duration),
                              NSNumber(value: (2 * hold + travel) / duration), 1]
        animation.duration = duration
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        label.layer?.add(animation, forKey: Self.animationKey)
        animatedDistance = distance
    }

    func stopScrolling() {
        label.layer?.removeAnimation(forKey: Self.animationKey)
        animatedDistance = nil
    }

    func retire() {
        allowsAnimation = false
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        stopScrolling()
        label.sourceText = ""
        label.stringValue = ""
        toolTip = nil
    }

    /// Opt-in local control diagnostics, read from the real native view/layer.
    /// No title/artist bytes or text copies are added to this response.
    var motionSnapshot: [String: Any] {
        ["overflowPoints": max(0, naturalSize.width - bounds.width),
         "viewportWidth": bounds.width, "visible": isPresented,
         "allowed": allowsAnimation,
         "animating": label.layer?.animation(forKey: Self.animationKey) != nil,
         "displayUTF16Units": label.stringValue.utf16.count,
         "accessibilityUTF16Units": label.accessibilityValue()?.utf16.count ?? 0,
         "layerPixelWidth": label.bounds.width * backingScale,
         "offsetPoints": label.layer?.presentation()?.transform.m41 ?? 0]
    }

    static func motionSnapshots(in view: NSView) -> [[String: Any]] {
        if let label = view as? CoveScrollingMediaTextView { return [label.motionSnapshot] }
        return view.subviews.flatMap { motionSnapshots(in: $0) }
    }
}

/// The visible string is bounded; assistive clients still receive the source.
@MainActor
private final class CoveAccessibleMediaLabel: NSTextField {
    var sourceText = ""
    override func accessibilityValue() -> String? { sourceText }
}
