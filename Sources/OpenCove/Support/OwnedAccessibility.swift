// SPDX-License-Identifier: MIT
import AppKit
import CoreFoundation
import CoreGraphics

/// An on-demand read of the mounted owned compact control. Never creates an AX
/// application, performs an action, or walks another application's elements.
@MainActor
enum OwnedAccessibility {
    static let compactIdentifier = "org.opencove.compact-activity"
    private static let readPath = "NSAccessibilityProtocol"
    private static let maximumSearchVisits = 128
    private static let maximumSearchDepth = 12
    private static let maximumPending = 128
    private static let maximumChildren = 32
    private static let maximumElements = 16
    private static let maximumDescendantDepth = 3
    private static let maximumStringBytes = 512
    private static let softTimeBudget: TimeInterval = 0.05

    struct Failure: LocalizedError {
        enum Kind: String {
            case unavailable, ambiguousPanel, missingTarget, duplicateIdentifier
            case unsupported, incomplete, invalidTarget
        }

        let kind: Kind
        let reason: String
        var searchComplete = false

        init(_ kind: Kind, _ reason: String, searchComplete: Bool = false) {
            self.kind = kind
            self.reason = reason
            self.searchComplete = searchComplete
        }

        var errorDescription: String? {
            switch kind {
            case .unavailable: return "A mounted compact panel in an active unlocked session is required. Read fresh state."
            case .ambiguousPanel: return "More than one owned panel is eligible. No panel was selected."
            case .missingTarget: return "The complete mounted-hosting search found no compact identifier."
            case .duplicateIdentifier: return "The compact identifier occurs on more than one object. No target was selected."
            case .unsupported: return "The public protocol or scalar value is unsupported. The read is inconclusive."
            case .incomplete: return "The owned accessibility read is incomplete. No absence was established."
            case .invalidTarget: return "The compact identifier does not expose a visible accessibility button."
            }
        }

        @MainActor var response: [String: Any] {
            ["error": localizedDescription, "status": kind.rawValue, "reason": reason,
             "readPath": OwnedAccessibility.readPath, "complete": false,
             "searchComplete": searchComplete, "absenceEstablished": kind == .missingTarget]
        }
    }

    /// The caller checks compact/unlocked app state before and after the
    /// synchronous read. These guards never supply accessibility semantics.
    static func compact(validateSource: () throws -> Void) throws -> [String: Any] {
        try validateSource()
        let (window, root) = try selectedHostingRoot()
        var read = Read()
        var pending: [(AnyObject, Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var exposedChildren: [ObjectIdentifier: [AnyObject]] = [:]
        var target: AnyObject?

        // Search reads only identifiers and exposed children, including children
        // of containers whose isAccessibilityElement is false. Complete this
        // search even after a match so a second identifier cannot be hidden.
        while let (object, depth) = pending.popLast() {
            try read.checkBudget()
            guard visited.count < maximumSearchVisits else { throw read.failure(.incomplete, "searchVisits") }
            guard visited.insert(ObjectIdentifier(object)).inserted else { throw read.failure(.incomplete, "cycleOrSharedChild") }
            guard let element = object as? NSAccessibilityProtocol else { throw read.failure(.unsupported, "protocol") }
            let identifier = try read.string { element.accessibilityIdentifier() }
            if identifier == compactIdentifier {
                guard target == nil else { throw read.failure(.duplicateIdentifier, "identifier") }
                target = object
            }
            let children = try read.children(of: element)
            guard children.isEmpty || depth < maximumSearchDepth else { throw read.failure(.incomplete, "searchDepth") }
            guard pending.count + children.count <= maximumPending else { throw read.failure(.incomplete, "pending") }
            let objects = children.map { $0 as AnyObject }
            exposedChildren[ObjectIdentifier(object)] = objects
            pending.append(contentsOf: objects.reversed().map { ($0, depth + 1) })
        }
        read.searchComplete = true
        try validateSource()
        try validateSelection(window: window, root: root)
        try read.checkBudget()
        guard let target else { throw read.failure(.missingTarget, "identifier") }

        // Only the matched button and its actual exposed descendants may supply
        // semantic fields. Nil values stay nil; inherited child values remain
        // separate nodes instead of being synthesized onto the button.
        pending = [(target, 0)]
        var descendants = Set<ObjectIdentifier>()
        var elements: [[String: Any]] = []
        while let (object, depth) = pending.popLast() {
            try read.checkBudget()
            guard elements.count < maximumElements else { throw read.failure(.incomplete, "responseCount") }
            guard descendants.insert(ObjectIdentifier(object)).inserted else { throw read.failure(.incomplete, "cycleOrSharedChild") }
            guard let element = object as? NSAccessibilityProtocol else { throw read.failure(.unsupported, "protocol") }
            let identifier = try read.string { element.accessibilityIdentifier() }
            guard depth == 0 || identifier != compactIdentifier else {
                throw read.failure(.duplicateIdentifier, "identifierChanged")
            }
            let role = try read.string { element.accessibilityRole()?.rawValue }
            let label = try read.string { element.accessibilityLabel() }
            let title = try read.string { element.accessibilityTitle() }
            let value = try read.scalar { element.accessibilityValue() }
            let enabled = try read.get { element.isAccessibilityEnabled() }
            let isElement = try read.get { element.isAccessibilityElement() }
            var node: [String: Any] = [
                "identifier": identifier.map { $0 as Any } ?? NSNull(),
                "role": role.map { $0 as Any } ?? NSNull(),
                "label": label.map { $0 as Any } ?? NSNull(),
                "title": title.map { $0 as Any } ?? NSNull(),
                "value": value.value, "valueType": value.type,
                "enabled": enabled, "isAccessibilityElement": isElement, "depth": depth
            ]
            if depth == 0 {
                let frame = try read.get { element.accessibilityFrame() }
                guard identifier == compactIdentifier, role == NSAccessibility.Role.button.rawValue, isElement,
                      frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
                    throw read.failure(.invalidTarget, "button")
                }
                node["width"] = frame.width
                node["height"] = frame.height
            }
            elements.append(node)
            // Retain and use the exact child edges observed by the complete
            // identifier search; do not splice a second tree read into it.
            guard let children = exposedChildren[ObjectIdentifier(object)] else {
                throw read.failure(.incomplete, "childrenChanged")
            }
            guard children.isEmpty || depth < maximumDescendantDepth else { throw read.failure(.incomplete, "descendantDepth") }
            guard elements.count + pending.count + children.count <= maximumElements else { throw read.failure(.incomplete, "responseCount") }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        try validateSource()
        try validateSelection(window: window, root: root)
        try read.checkBudget()
        return ["elements": elements, "visitedNodes": visited.count,
                "returnedNodes": elements.count, "readPath": readPath,
                "complete": true, "searchComplete": true, "status": "complete"]
    }

    private static func selectedHostingRoot() throws -> (NSWindow, NSView) {
        guard !NSApp.isHidden,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            throw Failure(.unavailable, "activeSession")
        }
        // As in SystemController, this dictionary field is undocumented. An
        // absent field is unknown, not fresh evidence of an unlocked session.
        guard session["CGSSessionScreenIsLocked"] as? Bool == false else {
            throw Failure(.unavailable, "unlockedSession")
        }
        var selected: (NSWindow, NSView)?
        for window in NSApp.windows {
            guard window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
                  window.occlusionState.contains(.visible), window.alphaValue.isFinite, window.alphaValue > 0,
                  window.windowNumber > 0, window.screen != nil,
                  let root = NotchPanelController.mountedHostingView(in: window),
                  !root.isHiddenOrHasHiddenAncestor,
                  root.bounds.width.isFinite, root.bounds.height.isFinite,
                  root.bounds.width > 0, root.bounds.height > 0 else { continue }
            guard selected == nil else { throw Failure(.ambiguousPanel, "panelCount") }
            selected = (window, root)
        }
        guard let selected else { throw Failure(.unavailable, "mountedHostingRoot") }
        return selected
    }

    private static func validateSelection(window: NSWindow, root: NSView) throws {
        let (currentWindow, currentRoot) = try selectedHostingRoot()
        guard currentWindow === window, currentRoot === root else { throw Failure(.unavailable, "selectionChanged") }
    }

    @MainActor private struct Read {
        let started = ProcessInfo.processInfo.systemUptime
        var searchComplete = false

        func failure(_ kind: Failure.Kind, _ reason: String) -> Failure {
            Failure(kind, reason, searchComplete: searchComplete)
        }

        func checkBudget() throws {
            guard ProcessInfo.processInfo.systemUptime - started < softTimeBudget else {
                throw failure(.incomplete, "softTimeBudget")
            }
        }

        // This is a soft budget checked between getters. It cannot interrupt a
        // getter or limit the time/memory AppKit or SwiftUI uses inside one.
        func get<T>(_ getter: () -> T) throws -> T {
            try checkBudget()
            let value = getter()
            try checkBudget()
            return value
        }

        func bounded(_ value: String) throws -> String {
            guard value.utf8.prefix(maximumStringBytes + 1).count <= maximumStringBytes else {
                throw failure(.incomplete, "stringUTF8Bytes")
            }
            return value
        }

        func string(_ getter: () -> String?) throws -> String? {
            guard let value = try get(getter) else { return nil }
            return try bounded(value)
        }

        func scalar(_ getter: () -> Any?) throws -> (value: Any, type: String) {
            guard let value = try get(getter) else { return (NSNull(), "nil") }
            if let string = value as? String { return (try bounded(string), "string") }
            if let number = value as? NSNumber, number.doubleValue.isFinite {
                return (number, CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number")
            }
            throw failure(.unsupported, "valueType")
        }

        func children(of element: NSAccessibilityProtocol) throws -> [Any] {
            let children = try get { element.accessibilityChildren() } ?? []
            guard children.count <= maximumChildren else { throw failure(.incomplete, "childrenCount") }
            return children
        }
    }
}
