// SPDX-License-Identifier: MIT
import SwiftUI

@MainActor
struct WeatherView: View {
    @ObservedObject var controller: WeatherController
    @State private var editingLocation = false
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var inputError: String?

    private var busy: Bool { controller.isLoading || controller.isRequestingLocation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Weather", systemImage: "cloud.sun")
                    .font(.headline)
                Spacer()
                if controller.hasLocation {
                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Refresh weather")
                    .accessibilityLabel("Refresh weather")

                    Button(editingLocation ? "Done" : "Location") {
                        if !editingLocation { loadLocationFields() }
                        editingLocation.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if controller.state.available {
                conditions
            } else if busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.isRequestingLocation ? "Finding your location…" : "Loading weather…")
                        if !controller.locationName.isEmpty {
                            Text(controller.locationName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.hasLocation ? "Weather is unavailable" : "Weather starts with your choice")
                        .font(.subheadline.weight(.medium))
                    Text(controller.hasLocation
                         ? "Refresh to get current conditions for \(controller.locationName)."
                         : "Enter coordinates or use your device location to show real weather.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if editingLocation || !controller.hasLocation {
                locationEditor
            }

            if controller.hasLocation {
                HStack {
                    if busy {
                        ProgressView().controlSize(.mini)
                        Text(controller.isRequestingLocation ? "Finding location…" : "Updating…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove location") {
                        controller.clearLocation()
                        name = ""
                        latitude = ""
                        longitude = ""
                        inputError = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .help("Stop weather and remove the saved coordinates")
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .onAppear { loadLocationFields() }
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Image(systemName: controller.state.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 38))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.state.locationName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(controller.state.condition)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(controller.state.temperatureText)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let date = controller.state.updatedAt {
                    HStack(spacing: 4) {
                        Text(context.date.timeIntervalSince(date) > 3600 ? "Older conditions ·" : "Conditions ·")
                        Text(date, style: .relative)
                        Text("ago")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            CoveWeatherAttribution()
        }
    }

    private var locationEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weather location").font(.subheadline.weight(.medium))
            TextField("Location name (optional)", text: $name)
                .accessibilityLabel("Weather location name")
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latitude").font(.caption).foregroundStyle(.secondary)
                    TextField("−90 to 90", text: $latitude)
                        .accessibilityLabel("Latitude")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Longitude").font(.caption).foregroundStyle(.secondary)
                    TextField("−180 to 180", text: $longitude)
                        .accessibilityLabel("Longitude")
                }
            }
            .onSubmit { saveManualLocation() }
            if let error = inputError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Choosing a location sends its coordinates to Open-Meteo for weather. Device location is requested once and rounded to about 1 km. Your choice is saved on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use coordinates") { saveManualLocation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(latitude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || longitude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    inputError = nil
                    controller.requestLocation()
                } label: {
                    Label("Use device location", systemImage: "location")
                }
                .disabled(controller.isRequestingLocation)
            }
            Link("Open-Meteo privacy", destination: URL(string: "https://open-meteo.com/en/terms#privacy")!)
                .font(.caption2)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 3)
    }

    private func loadLocationFields() {
        name = controller.locationName
        latitude = controller.latitude.map { String($0) } ?? ""
        longitude = controller.longitude.map { String($0) } ?? ""
    }

    private func saveManualLocation() {
        let latitudeText = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let longitudeText = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latitudeValue = Double(latitudeText), let longitudeValue = Double(longitudeText),
              latitudeValue.isFinite, longitudeValue.isFinite,
              (-90...90).contains(latitudeValue), (-180...180).contains(longitudeValue) else {
            inputError = "Enter decimal coordinates: latitude −90 to 90, longitude −180 to 180."
            return
        }
        inputError = nil
        controller.setLocation(latitude: latitudeValue, longitude: longitudeValue, name: name)
        editingLocation = false
    }
}

/// Attribution stays beside Open-Meteo data on every weather surface.
struct CoveWeatherAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Link("Weather data by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                Text("·").foregroundStyle(.secondary)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            Text("Model conditions summarized; temperature rounded.")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }
}
