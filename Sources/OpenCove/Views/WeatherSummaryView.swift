// SPDX-License-Identifier: MIT
import SwiftUI

/// Shared weather content. The owner supplies one visible minute tick; this
/// view creates no schedule, service, permission request or network operation.
@MainActor
struct CoveWeatherSummary: View {
    let state: WeatherState
    let data: WeatherWidgetData
    var compact = false
    var showsLocation = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            switch data.style {
            case .conditions: conditions
            case .sun: sun
            case .precipitation: precipitation
            }
        }
        .environment(\.timeZone, state.timeZone)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack(spacing: compact ? 8 : 16) {
                Image(systemName: state.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: compact ? 23 : 38))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if showsLocation { location }
                    Text(state.condition).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(state.temperatureText)
                    .font(.system(size: compact ? 19 : 34, weight: .light, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
            }
            if let today = data.today {
                Text("H \(WeatherView.degrees(today.maximum)) · L \(WeatherView.degrees(today.minimum))")
                    .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
            }
            if compact { hours(precipitation: false) }
        }
    }

    private var sun: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(spacing: compact ? 10 : 16) {
                Image(systemName: continuousSun ? (data.sunCondition == .continuousDaylight ? "sun.max.fill" : "moon.stars.fill")
                      : data.nextSunEvent?.kind.symbol ?? "sun.max")
                    .font(.system(size: compact ? 25 : 38)).foregroundStyle(sunColor)
                    .accessibilityHidden(true)
                if continuousSun {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(data.sunCondition == .continuousDaylight ? "Daylight all day" : "Sun down all day")
                            .font(.system(size: compact ? 16 : 28, weight: .light, design: .rounded)).lineLimit(2)
                        Text("No sunrise or sunset today").font(.system(size: compact ? 9 : 12)).foregroundStyle(.secondary)
                    }
                } else if let event = data.nextSunEvent {
                    VStack(alignment: .leading, spacing: 2) {
                        if compact {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(event.kind.title).font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(event.date, format: .dateTime.hour().minute())
                                    .font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
                            }
                        } else {
                            Text(event.kind.title).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(event.date, format: .dateTime.hour().minute())
                                .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                        }
                        HStack(spacing: 4) {
                            eventDay(event.date)
                            Text("· " + (state.timeZone.abbreviation(for: event.date) ?? "Location time"))
                        }
                        .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Sun times unavailable").font(.system(size: compact ? 11 : 14))
                }
                Spacer(minLength: 0)
            }
            if let progress = data.daylightProgress {
                CoveDaylightArc(progress: progress, showsPosition: data.isDaylight == true)
                    .frame(height: compact ? 20 : 38).padding(.horizontal, 7).padding(.top, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Daylight progress")
                    .accessibilityValue(data.isDaylight == true
                        ? (progress * 100).formatted(.number.precision(.fractionLength(0))) + "% of today's daylight elapsed"
                        : "Outside today's daylight hours")
            }
            if !continuousSun {
                HStack {
                    sunTime("Sunrise", date: data.today?.sunrise)
                    Spacer(minLength: 8)
                    sunTime("Sunset", date: data.today?.sunset)
                }
            } else if let event = data.nextSunEvent {
                HStack(spacing: 4) {
                    Text("Next " + event.kind.title.lowercased() + ":")
                    Text(event.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
                .font(.system(size: compact ? 9 : 12)).foregroundStyle(.secondary)
            }
            if showsLocation { location }
        }
    }

    private var continuousSun: Bool { data.sunCondition == .continuousDaylight || data.sunCondition == .continuousNight }
    private var sunColor: Color { data.sunCondition == .continuousNight ? .indigo : .orange }

    private var precipitation: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(spacing: compact ? 10 : 16) {
                Image(systemName: "umbrella.fill")
                    .font(.system(size: compact ? 25 : 38)).foregroundStyle(.cyan).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(percent(data.precipitationProbability))
                        .font(.system(size: compact ? 24 : 36, weight: .light, design: .rounded)).monospacedDigit()
                    Text(data.precipitationPeriod == "hour" ? "Chance this hour"
                         : data.precipitationPeriod == "day" ? "Today's highest chance" : "Chance unavailable")
                        .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let value = data.precipitationProbability, value.isFinite {
                GeometryReader { proxy in
                    Capsule().fill(.quaternary)
                    Capsule().fill(.cyan).frame(width: proxy.size.width * min(1, max(0, value / 100)))
                }
                .frame(height: 4).accessibilityHidden(true)
            }
            if data.precipitationPeriod == "hour", let today = data.today?.precipitationProbability {
                Text("Today's high: " + percent(today)).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
            }
            hours(precipitation: true)
            if showsLocation { location }
        }
    }

    private var location: some View {
        Text(state.locationName).font(.system(size: compact ? 10 : 14, weight: .medium)).lineLimit(compact ? 1 : 2)
    }

    @ViewBuilder private func eventDay(_ date: Date) -> some View {
        let calendar = locationCalendar
        if calendar.isDate(date, inSameDayAs: data.asOf) { Text("Today") }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: data.asOf), calendar.isDate(date, inSameDayAs: tomorrow) {
            Text("Tomorrow")
        } else { Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    }

    private var locationCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.timeZone
        return calendar
    }

    private func sunTime(_ title: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            if let date { Text(date, format: .dateTime.hour().minute()).monospacedDigit() }
            else { Text("—") }
        }
        .font(.system(size: compact ? 9 : 11))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func hours(precipitation: Bool) -> some View {
        let values = precipitation ? data.precipitationHours : data.hours
        if !values.isEmpty {
            HStack(spacing: compact ? 12 : 24) {
                ForEach(values) { hour in
                    VStack(spacing: 3) {
                        Text(precipitation ? hour.date.addingTimeInterval(-3_600) : hour.date,
                             format: .dateTime.hour()).foregroundStyle(.secondary)
                        if precipitation {
                            Text(percent(hour.precipitationProbability)).foregroundStyle(.cyan)
                        } else {
                            Image(systemName: hour.symbol).accessibilityHidden(true)
                            Text(WeatherView.degrees(hour.temperature))
                        }
                    }
                    .font(.system(size: compact ? 9 : 12)).monospacedDigit()
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(precipitation ? "Precipitation chance for the hour beginning at the time shown" : hour.condition)
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

private struct CoveDaylightArc: View {
    let progress: Double
    let showsPosition: Bool

    var body: some View {
        GeometryReader { proxy in
            let path = Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height))
                path.addQuadCurve(to: CGPoint(x: proxy.size.width, y: proxy.size.height),
                                  control: CGPoint(x: proxy.size.width / 2, y: -proxy.size.height))
            }
            let completed = path.trimmedPath(from: 0, to: min(1, max(0, progress)))
            path.stroke(.orange.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            completed.stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if showsPosition {
                Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(.orange)
                    .position(completed.currentPoint ?? CGPoint(x: 0, y: proxy.size.height))
            }
        }
    }
}
