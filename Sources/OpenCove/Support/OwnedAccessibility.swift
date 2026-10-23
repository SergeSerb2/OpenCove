// SPDX-License-Identifier: MIT
import AppKit

/// An on-demand read of the real owned compact control. Never creates an AX
/// application, performs an action, or walks another application's elements.
@MainActor
enum OwnedAccessibility {
    static let compactIdentifier = "org.opencove.compact-activity"

    enum Failure: LocalizedError {
        case unavailable, incomplete
        var errorDescription: String? {
            switch self {
            case .unavailable: return "No visible compact control is available. Collapse the panel and read fresh state."
            case .incomplete: return "The owned accessibility read exceeded its bounds. No absence was established."
            }
        }
    }

    static func compact(in window: NSWindow) throws -> [String: Any] {
        guard window.isVisible, window.isOnActiveSpace, !window.isMiniaturized,
              NotchPanelController.contentIsHidden(in: window) == false,
              let content = window.contentView else { throw Failure.unavailable }
        var pending: [(AnyObject, Int)] = [(content, 0)]
        var visited = Set<ObjectIdentifier>()
        var matches: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        while let (object, depth) = pending.popLast() {
            guard visited.count < 128, depth <= 12,
                  ProcessInfo.processInfo.systemUptime - started < 0.05 else { throw Failure.incomplete }
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard let element = object as? NSAccessibilityProtocol else { continue }
            if element.accessibilityIdentifier() == compactIdentifier {
                let frame = element.accessibilityFrame()
                guard frame.width > 0, frame.height > 0, element.isAccessibilityElement() else { continue }
                func bounded(_ value: String?) -> Any {
                    guard let value else { return NSNull() }
                    return String(value.prefix(512))
                }
                let value = element.accessibilityValue()
                matches.append([
                    "identifier": compactIdentifier,
                    "role": bounded(element.accessibilityRole()?.rawValue),
                    "label": bounded(element.accessibilityLabel()),
                    "value": bounded(value as? String),
                    "enabled": element.isAccessibilityEnabled(),
                    "width": frame.width, "height": frame.height
                ])
                guard matches.count <= 4 else { throw Failure.incomplete }
                // The requested control is the semantic boundary. Its children
                // can contain media text; no unrelated labels are returned.
                continue
            }
            let children = element.accessibilityChildren() ?? []
            guard children.count <= 32, pending.count + children.count <= 128 else { throw Failure.incomplete }
            pending.append(contentsOf: children.reversed().map { ($0 as AnyObject, depth + 1) })
        }
        guard !matches.isEmpty else { throw Failure.unavailable }
        return ["elements": matches, "visitedNodes": visited.count, "complete": true]
    }
}
