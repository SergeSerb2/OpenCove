// SPDX-License-Identifier: MIT
import SwiftUI

@MainActor
struct WeatherView: View {
    @ObservedObject var controller: WeatherController
    var style: CoveWeatherStyle = .conditions
    var motion: Animation? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var editingLocation = false
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var inputError: String?

    private var busy: Bool { controller.isLoading || controller.isRequestingLocation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Weather", systemImage: style.symbol)
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
        .animation(systemReduceMotion ? nil : motion, value: style)
        .onAppear { loadLocationFields() }
    }

    private var conditions: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 9) {
                CoveWeatherSummary(state: controller.state,
                                   data: WeatherWidgetData(state: controller.state, style: style, at: context.date))
                HStack(spacing: 16) {
                    if let value = controller.state.apparentTemperature {
                        metric("Feels like", value: Self.degrees(value), symbol: "thermometer.medium")
                    }
                    if let value = controller.state.humidity {
                        metric("Humidity", value: value.formatted(.number.precision(.fractionLength(0))) + "%", symbol: "humidity")
                    }
                    if let value = controller.state.windSpeed {
                        metric("Wind", value: value.formatted(.number.precision(.fractionLength(0))) + " km/h", symbol: "wind")
                    }
                }
                if !controller.state.hourly.isEmpty || !controller.state.daily.isEmpty {
                    CoveWeatherForecast(state: controller.state, now: context.date)
                }
                if let notice = controller.state.forecastNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if let date = controller.state.updatedAt {
                    Text(Self.updateDescription(date, at: context.date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                CoveWeatherAttribution()
            }
        }
    }

    private static func updateDescription(_ date: Date, at now: Date) -> String {
        let age = now.timeIntervalSince(date)
        guard age.isFinite, age >= 0 else { return "Update time unavailable" }
        if age < 60 { return "Updated just now" }
        if age < 3_600 { return "Updated \(Int(age / 60)) min ago" }
        if age < 7 * 86_400 { return "Saved weather · updated \(Int(age / 3_600)) hr ago" }
        return "Saved weather · over a week old"
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func degrees(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + "°"
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
            Text("Model weather summarized; values rounded.")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }
}

/// A small, static forecast: at most 24 cells and 7 rows. Only visible time
/// labels advance each minute; the weather service keeps its 15-minute cadence.
@MainActor
struct CoveWeatherForecast: View {
    let state: WeatherState
    let now: Date

    var body: some View {
        let hours = Array(state.hourly.filter { $0.date.addingTimeInterval(3_600) > now }.prefix(24))
        let days = Array(state.daily.filter { $0.date >= startOfDay(now) }.prefix(7))
        VStack(alignment: .leading, spacing: 12) {
            if !hours.isEmpty {
                heading("Next 24 hours")
                Text("Precipitation chances cover the hour ending at each time.")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(hours) { hour in hourlyCell(hour) }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.hidden)
            }
            if !days.isEmpty {
                Divider()
                heading("7-day forecast")
                VStack(spacing: 10) {
                    ForEach(days) { day in
                        CoveWeatherDayRow(day: day, days: days, today: isToday(day.date, now: now))
                    }
                }
            }
        }
        .environment(\.timeZone, state.timeZone)
    }

    private func heading(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            Text(state.timeZone.abbreviation() ?? state.timeZoneIdentifier)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func hourlyCell(_ hour: WeatherHour) -> some View {
        VStack(spacing: 6) {
            Text(hour.date, format: .dateTime.hour())
                .font(.caption2).foregroundStyle(.secondary)
            Image(systemName: hour.symbol).symbolRenderingMode(.multicolor)
                .font(.system(size: 17)).frame(height: 22).accessibilityHidden(true)
            Text(WeatherView.degrees(hour.temperature)).font(.caption.weight(.medium)).monospacedDigit()
            Text(hour.precipitationProbability.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(width: 44)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hour.condition + ". Precipitation chance is shown below the temperature.")
    }

    private func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.timeZone
        return calendar.startOfDay(for: date)
    }

    private func isToday(_ date: Date, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.timeZone
        return calendar.isDate(date, inSameDayAs: now)
    }
}

@MainActor
private struct CoveWeatherDayRow: View {
    let day: WeatherDay
    let days: [WeatherDay]
    let today: Bool

    private var lower: Double { days.compactMap(\.minimum).min() ?? 0 }
    private var upper: Double { days.compactMap(\.maximum).max() ?? 1 }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if today { Text("Today") }
                else { Text(day.date, format: .dateTime.weekday(.abbreviated)) }
            }
            .frame(width: 42, alignment: .leading)
            Image(systemName: day.symbol).symbolRenderingMode(.multicolor)
                .frame(width: 22).accessibilityHidden(true)
            Text(day.precipitationProbability.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            Text(WeatherView.degrees(day.minimum)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            GeometryReader { proxy in
                Capsule().fill(.quaternary)
                if let low = day.minimum, let high = day.maximum {
                    let range = max(1, upper - lower)
                    let start = min(1, max(0, (low - lower) / range))
                    let length = min(1 - start, max(0, (high - low) / range))
                    Capsule().fill(LinearGradient(colors: [.cyan, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: min(proxy.size.width, max(3, proxy.size.width * length)))
                        .offset(x: min(max(0, proxy.size.width - 3), proxy.size.width * start))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text(WeatherView.degrees(day.maximum)).frame(width: 34, alignment: .trailing)
        }
        .font(.caption.weight(.medium)).monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityHint(day.condition + ". Low and high temperature, with precipitation chance.")
    }
}
