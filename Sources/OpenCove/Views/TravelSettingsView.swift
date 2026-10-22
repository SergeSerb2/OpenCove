// SPDX-License-Identifier: MIT
import SwiftUI

/// Embed under Calendar in the owner's settings Form. No work starts on appearance.
@MainActor
struct TravelSettingsView: View {
    @ObservedObject var controller: TravelController
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Time-to-leave alerts", isOn: Binding(
                get: { controller.state.enabled },
                set: { configure(enabled: $0) }
            ))
            Text("Uses the next event with a physical location in the next 24 hours. Choose an origin before Apple Maps receives a route request.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.state.enabled {
                Picker("Travel mode", selection: Binding(
                    get: { controller.mode },
                    set: { configure(mode: $0) }
                )) {
                    ForEach(CoveTravelMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                }
                Stepper(value: Binding(
                    get: { controller.bufferMinutes },
                    set: { configure(buffer: $0) }
                ), in: 0...120, step: 1) {
                    LabeledContent("Arrival buffer", value: "\(Int(controller.bufferMinutes)) min")
                }
                originSettings
                if controller.isCalculating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the route…").font(.caption)
                    }
                }
                if controller.state.available, !controller.state.isStale, let leaveAt = controller.state.leaveAt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.state.eventTitle).fontWeight(.medium)
                        Text(controller.state.destination)
                        LabeledContent("Travel time", value: "\(Int(ceil(controller.state.travelSeconds / 60))) min")
                        LabeledContent("Leave at", value: leaveAt.formatted(date: .abbreviated, time: .shortened))
                        Text("Estimate by Apple Maps").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                }
            } else if controller.hasOrigin {
                HStack {
                    Text("An origin is saved on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Origin") { controller.clearOrigin(); loadOriginFields() }
                        .controlSize(.small)
                }
            }
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { loadOriginFields() }
        .onChange(of: controller.originLatitude) { _, _ in loadOriginFields() }
        .onChange(of: controller.originLongitude) { _, _ in loadOriginFields() }
    }

    private var originSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Origin").fontWeight(.medium)
                Spacer()
                if controller.hasOrigin {
                    Text(controller.originSource).font(.caption).foregroundStyle(.secondary)
                    Button("Forget Origin") { controller.clearOrigin(); loadOriginFields() }
                        .controlSize(.small)
                }
            }
            Text("The origin stays fixed until you replace it. Device location is requested once. Your origin and the event destination are sent to Apple Maps for travel estimates; calendar notes and meeting links are not sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latitude").font(.caption)
                    TextField("−90 to 90", text: $latitude).accessibilityLabel("Travel origin latitude")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Longitude").font(.caption)
                    TextField("−180 to 180", text: $longitude).accessibilityLabel("Travel origin longitude")
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { saveOrigin() }
            HStack {
                Button("Use Coordinates") { saveOrigin() }
                Button(controller.isRequestingLocation ? "Requesting Location…" : "Use Device Location Once") {
                    inputError = nil
                    controller.requestLocation()
                }
                .disabled(controller.isRequestingLocation)
            }
            .controlSize(.small)
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.orange) }
            Text("Origin coordinates are saved privately on this Mac. Disabling alerts stops requests; Forget Origin removes the saved coordinates. Route checks occur no more than once every 15 minutes. Alerts appear while OpenCove is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func configure(enabled: Bool? = nil, mode: String? = nil, buffer: Double? = nil) {
        controller.configure(enabled: enabled ?? controller.state.enabled,
                             mode: mode ?? controller.mode,
                             bufferMinutes: buffer ?? controller.bufferMinutes)
    }

    private func loadOriginFields() {
        latitude = controller.originLatitude.map { String($0) } ?? ""
        longitude = controller.originLongitude.map { String($0) } ?? ""
        inputError = nil
    }

    private func saveOrigin() {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
            inputError = "Enter decimal coordinates: latitude −90 to 90, longitude −180 to 180."
            return
        }
        inputError = nil
        controller.setOrigin(latitude: lat, longitude: lon)
    }
}
