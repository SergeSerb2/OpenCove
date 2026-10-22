// SPDX-License-Identifier: MIT
import SwiftUI

@MainActor
struct CoveDisplayPreference: View {
    @ObservedObject var store: CoveStore

    private var choices: [CoveDisplayInfo] { store.displaySelection.available.filter(\.canSelect) }
    private var savedUUID: String { UUID(uuidString: store.preferences.selectedDisplayUUID)?.uuidString ?? "" }

    private var selection: Binding<String> {
        Binding(get: {
            if store.preferences.showOnAllDisplays { return "all" }
            if !savedUUID.isEmpty { return savedUUID }
            return store.preferences.preferBuiltInDisplay ? "builtIn" : "main"
        }, set: { choice in
            store.chooseDisplay(choice)
        })
    }

    var body: some View {
        Picker("Show on display", selection: selection) {
            Text("Built-in display").tag("builtIn")
            Text("Main display").tag("main")
            Text("All displays").tag("all")
            ForEach(choices) { display in
                Label(title(for: display), systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                    .tag(display.uuid ?? "")
            }
            if !store.preferences.showOnAllDisplays, !savedUUID.isEmpty, !choices.contains(where: { $0.uuid == savedUUID }) {
                Text("Saved display (unavailable)").tag(savedUUID).disabled(true)
            }
        }
        CoveSettingsNote(store.displaySelection.status,
                         symbol: store.displaySelection.isFallback ? "exclamationmark.circle" : "display")
        if store.displaySelection.available.contains(where: { !$0.canSelect }) {
            CoveSettingsNote("Some displays do not have a unique saved identity. Main, Built-in and All displays remain available.")
        }
    }

    private func title(for display: CoveDisplayInfo) -> String {
        let duplicates = store.displaySelection.available.filter { $0.name == display.name }.count > 1
        guard duplicates, let index = store.displaySelection.available.firstIndex(where: { $0.id == display.id }) else { return display.name }
        return "\(display.name) (\(index + 1))"
    }
}
