// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics

struct CoveDisplayInfo: Codable, Equatable, Identifiable {
    var id: UInt32
    var uuid: String?
    var name: String
    var isBuiltIn: Bool
    var isMain: Bool
    var canSelect: Bool
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var scale: Double
}

struct CoveDisplaySelection: Codable, Equatable {
    var available: [CoveDisplayInfo] = []
    var selectedDisplayIDs: [UInt32] = []
    var mode = "builtIn"
    var requestedUUID = ""
    var isFallback = false
    var status = "Waiting for display information."
}

enum CoveDisplayError: LocalizedError {
    case invalidChoice, unavailable, saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidChoice: return "Choose a display mode or an available display."
        case .unavailable: return "The selected display is no longer available. Choose an available display or a display mode."
        case .saveFailed(let message): return message
        }
    }
}

/// Shared policy for ordinary panels and optional widgets. Called by existing
/// layout/lifecycle events, never by a timer or a SwiftUI body.
@MainActor
enum CoveDisplays {
    struct Entry {
        var id: CGDirectDisplayID
        var screen: NSScreen
        var uuid: String?
    }

    static func resolve(_ preferences: CovePreferences) -> (screens: [Entry], state: CoveDisplaySelection) {
        var seen = Set<CGDirectDisplayID>()
        let screens: [Entry] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            // Closed-lid, sleeping and inactive displays must not take the panel.
            guard CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                  seen.insert(id).inserted else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            }
            return Entry(id: id, screen: screen, uuid: uuid)
        }
        let uuidCounts = Dictionary(grouping: screens.compactMap(\.uuid), by: { $0 }).mapValues(\.count)
        let mainID = CGMainDisplayID()
        var state = CoveDisplaySelection()
        state.available = screens.map { entry in
            let frame = entry.screen.frame
            return CoveDisplayInfo(id: entry.id, uuid: entry.uuid,
                name: String(entry.screen.localizedName.prefix(128)),
                isBuiltIn: CGDisplayIsBuiltin(entry.id) != 0, isMain: entry.id == mainID,
                canSelect: entry.uuid.map { uuidCounts[$0] == 1 } ?? false,
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                scale: entry.screen.backingScaleFactor)
        }
        state.requestedUUID = UUID(uuidString: preferences.selectedDisplayUUID)?.uuidString ?? ""
        state.mode = preferences.showOnAllDisplays ? "all" : !state.requestedUUID.isEmpty ? "selected"
            : preferences.preferBuiltInDisplay ? "builtIn" : "main"
        guard !screens.isEmpty else {
            state.isFallback = state.mode == "selected"
            state.status = "No active display is available. Your display choice is kept."
            return ([], state)
        }
        func finish(_ chosen: [Entry], _ status: String, fallback: Bool = false) -> ([Entry], CoveDisplaySelection) {
            state.selectedDisplayIDs = chosen.map(\.id)
            state.status = status
            state.isFallback = fallback
            return (chosen, state)
        }
        if state.mode == "all" {
            return finish(screens, screens.count == 1 ? "Showing on the available display." : "Showing on all \(screens.count) available displays.")
        }
        // CGMainDisplayID is the system primary display. NSScreen.main follows
        // key-window focus and can move when Settings opens on another screen.
        let main = screens.first { $0.id == mainID } ?? screens[0]
        func name(_ entry: Entry) -> String { state.available.first { $0.id == entry.id }?.name ?? "the available display" }
        if state.mode == "selected" {
            let matches = screens.filter { $0.uuid == state.requestedUUID }
            if matches.count == 1, let selected = matches.first {
                return finish([selected], "Using \(name(selected)).")
            }
            let reason = matches.isEmpty ? "The saved display is unavailable." : "The saved display cannot be identified uniquely."
            return finish([main], "\(reason) Using \(name(main)) temporarily. The saved choice will resume when it is available.", fallback: true)
        }
        if state.mode == "builtIn" {
            if let builtIn = screens.first(where: { CGDisplayIsBuiltin($0.id) != 0 }) {
                return finish([builtIn], "Using the built-in display.")
            }
            return finish([main], "No built-in display is available. Using \(name(main)).", fallback: true)
        }
        if main.id != mainID {
            return finish([main], "The main display is unavailable. Using \(name(main)).", fallback: true)
        }
        return finish([main], "Using the main display.")
    }
}
