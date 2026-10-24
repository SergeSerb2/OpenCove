import AppKit
import SwiftUI

/// Only the main notch mounts media regions. Lock widgets mount none.
struct CoveMediaSkipContext: Equatable {
    enum Kind: Equatable { case compact, peek, expanded, duo }
    let kind: Kind
    let item: CoveMediaSkipItem

    @MainActor static func current(in store: CoveStore) -> Self? {
        guard store.preferences.swipeToSkip, store.preferences.enableMedia,
              !store.system.state.isLocked, !store.hidesCompactWhenIdle,
              store.media.state.available, store.media.state.seekTarget != nil else { return nil }
        let kind: Kind
        if store.isExpanded {
            guard store.visibleTab == .media else { return nil }
            kind = store.showsExpandedDuo ? .duo : .expanded
        } else {
            guard store.hud == nil else { return nil }
            if store.showsMediaPeek { kind = .peek }
            else {
                guard store.compactActivity == .media else { return nil }
                kind = .compact
            }
        }
        return Self(kind: kind, item: CoveMediaSkipItem(store.media.state))
    }
}

/// These inputs can cancel an interaction, but never start or rearm one.
struct CoveMediaSkipItem: Equatable {
    let target: String?
    let source: String
    let item: String?
    let backend: String
    let available: Bool
    let playing: Bool
    let next: Bool
    let previous: Bool

    init(_ state: MediaState) {
        target = state.seekTarget
        source = state.sourceBundleIdentifier
        item = state.contentItemIdentifier
        backend = state.metadataBackend
        available = state.available
        playing = state.isPlaying
        next = state.supportsNext
        previous = state.supportsPrevious
    }
}

struct CoveMediaRegionSnapshot: Equatable {
    let id: UUID
    let revision: UInt
    let context: CoveMediaSkipContext
    let rect: NSRect
    let windowFrame: NSRect
    let layoutRevision: UInt
}

/// A non-interactive background marker: it cannot take input or accessibility
/// focus. Exclusion markers preserve sliders, controls and unrelated scrolling.
struct CoveMediaRegionMarker: NSViewRepresentable {
    var context: CoveMediaSkipContext? = nil
    var blocksInput = false

    func makeNSView(context: Context) -> CoveMediaRegionView { CoveMediaRegionView() }
    func updateNSView(_ view: CoveMediaRegionView, context: Context) {
        view.update(region: self.context, blocksInput: blocksInput)
    }
    static func dismantleNSView(_ view: CoveMediaRegionView, coordinator: ()) {
        view.update(region: nil, blocksInput: false)
        view.invalidateRegion()
    }
}

@MainActor
final class CoveMediaRegionView: NSView {
    static let didChange = Notification.Name("OpenCove.mediaRegionDidChange")
    private let regionID = UUID()
    private var revision: UInt = 0
    private(set) var region: CoveMediaSkipContext?
    private(set) var blocksInput = false
    private var geometryObservers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(region: CoveMediaSkipContext?, blocksInput: Bool) {
        guard self.region != region || self.blocksInput != blocksInput else { return }
        self.region = region
        self.blocksInput = blocksInput
        invalidateRegion()
    }

    func invalidateRegion() {
        revision &+= 1
        NotificationCenter.default.post(name: Self.didChange, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeGeometry()
        invalidateRegion()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeGeometry()
        invalidateRegion()
    }

    private func observeGeometry() {
        for token in geometryObservers { NotificationCenter.default.removeObserver(token) }
        geometryObservers.removeAll()
        // Watch ancestors too: moving a SwiftUI container need not resize this
        // marker. Revisions catch A -> B -> A even between scroll events.
        guard window != nil else { return }
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                geometryObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.invalidateRegion() }
                    })
            }
            ancestor = view.superview
        }
    }

    deinit {
        for token in geometryObservers { NotificationCenter.default.removeObserver(token) }
    }

    private func rect(in window: NSWindow) -> NSRect? {
        guard self.window === window, !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              !visibleRect.isEmpty else { return nil }
        let rect = convert(visibleRect.intersection(bounds), to: nil)
        guard !rect.isEmpty else { return nil }
        return rect
    }

    static func containsInputExclusion(at point: NSPoint, in root: NSView, window: NSWindow) -> Bool {
        if let marker = root as? CoveMediaRegionView, marker.blocksInput,
           let rect = marker.rect(in: window), rect.contains(point) { return true }
        return root.subviews.contains { containsInputExclusion(at: point, in: $0, window: window) }
    }

    static func region(at point: NSPoint, in root: NSView, window: NSWindow,
                       context: CoveMediaSkipContext, layoutRevision: UInt) -> CoveMediaRegionSnapshot? {
        var candidates: [CoveMediaRegionSnapshot] = []
        var blocked = false
        func visit(_ view: NSView) {
            if let marker = view as? CoveMediaRegionView, let rect = marker.rect(in: window), rect.contains(point) {
                if marker.blocksInput { blocked = true }
                if marker.region == context {
                    candidates.append(CoveMediaRegionSnapshot(id: marker.regionID, revision: marker.revision,
                        context: context, rect: rect, windowFrame: window.frame, layoutRevision: layoutRevision))
                }
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        // Ambiguous retained surfaces fail closed; never guess a Duo half.
        guard !blocked, candidates.count == 1 else { return nil }
        return candidates.first
    }
}

/// No timeout rearm. Only a real non-momentum .began selects a fresh route.
struct CoveMediaSkipScroll {
    enum Route: Equatable { case unstarted, navigation, media, passthrough }
    enum Action { case skip(forward: Bool, target: String), expand, collapse }
    private(set) var route = Route.unstarted
    private var origin: CoveMediaRegionSnapshot?
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var finished = true
    private var inverted = false
    private var reversed = false

    var ownsMediaGesture: Bool { route == .media }
    var suppressesNavigation: Bool { route == .navigation && finished }

    mutating func begin(route: Route, region: CoveMediaRegionSnapshot?, event: NSEvent, reverse: Bool) {
        self.route = route
        origin = region
        x = 0
        y = 0
        finished = false
        inverted = event.isDirectionInvertedFromDevice
        reversed = reverse
    }

    mutating func cancel() {
        origin = nil
        finished = true
        // Retain route, including after completion, metadata/layout updates,
        // an end event, or a long pause. Only begin() can release ownership.
    }

    static func accepts(_ event: NSEvent) -> Bool {
        event.hasPreciseScrollingDeltas && !event.phase.isEmpty && event.momentumPhase.isEmpty
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            && event.scrollingDeltaX.isFinite && event.scrollingDeltaY.isFinite
    }

    mutating func consume(_ event: NSEvent, region: CoveMediaRegionSnapshot?, reverse: Bool) -> Action? {
        guard !finished else { return nil }
        guard Self.accepts(event), !event.phase.contains(.cancelled), !event.phase.contains(.ended),
              region != nil, region == origin, reverse == reversed,
              event.isDirectionInvertedFromDevice == inverted else { cancel(); return nil }
        x += event.scrollingDeltaX
        y += event.scrollingDeltaY
        if abs(x) >= 28 && abs(x) > abs(y) * 1.25 {
            let item = origin?.context.item
            // Normalize natural scrolling only for skipping. Navigation keeps
            // the original event deltas, including its vertical direction.
            let forward = (x * (inverted ? -1 : 1) < 0) != reversed
            cancel()
            guard let item, let target = item.target, forward ? item.next : item.previous else { return nil }
            return .skip(forward: forward, target: target)
        }
        if abs(y) >= 20 && abs(y) > abs(x) * 1.25 {
            let expand = y < 0
            cancel()
            return expand ? .expand : .collapse
        }
        return nil
    }
}
