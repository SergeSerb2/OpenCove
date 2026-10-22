import SwiftUI

/// A native menu of actual CoreAudio output devices. Constructing or opening
/// the menu is read-only; only a device button can request a route change.
@MainActor
struct AudioOutputPicker: View {
    @ObservedObject var system: SystemController
    @State private var selectionError: String?

    var body: some View {
        Menu {
            if system.outputDevices.isEmpty {
                Text(system.state.capabilityMessages["audioOutputs"] ?? "No audio output is available")
            } else {
                ForEach(system.outputDevices) { device in
                    Button {
                        guard system.outputDevices.contains(where: { $0.id == device.id && $0.uid == device.uid }) else {
                            selectionError = "That output disconnected. Open the output menu and choose an available device."
                            return
                        }
                        selectionError = nil
                        system.selectOutputDevice(device.id)
                    } label: {
                        if system.state.outputDeviceID == device.id {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Label(device.name, systemImage: device.isBluetooth ? "headphones" : "speaker.wave.2")
                        }
                    }
                    .disabled(!system.state.canSelectOutputDevice)
                    .accessibilityLabel(device.name)
                    .accessibilityValue(system.state.outputDeviceID == device.id ? "Selected" : "")
                }
                if !system.state.canSelectOutputDevice {
                    Divider()
                    Text(system.state.capabilityMessages["audioOutputs"] ?? "Audio output selection is unavailable")
                }
            }
        } label: {
            Label(system.state.outputDevice.isEmpty ? "Sound output" : system.state.outputDevice,
                  systemImage: system.state.audioOutputIsBluetooth ? "headphones" : "speaker.wave.2.fill")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Choose an audio output")
        .accessibilityLabel("Sound output")
        .accessibilityValue(system.state.outputDevice.isEmpty ? "No output connected" : system.state.outputDevice)
        .alert("Audio output unavailable", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
            Button("OK") { selectionError = nil }
        } message: {
            Text(selectionError ?? "Choose an available output.")
        }
        .onAppear { system.refresh() }
    }
}
