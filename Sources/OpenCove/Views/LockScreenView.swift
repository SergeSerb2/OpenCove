// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Widget content only. macOS owns the clock and all authentication controls.
/// The controller decides whether this view may be mounted on a locked display;
/// the development renderer may also render it offscreen without changing lock state.
@MainActor
struct LockScreenView: View {
    @ObservedObject var store: CoveStore
    @ObservedObject var weather: WeatherController

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.preferences.enableMedia {
                    CoveLockMediaSection(controller: store.media)
                }
                if store.preferences.enableCalendar || store.preferences.enableWeather {
                    HStack(alignment: .top, spacing: 18) {
                        if store.preferences.enableCalendar {
                            CoveLockCalendarSection(controller: store.activities,
                                                    showPrivateContent: store.preferences.showLockScreenPrivateContent)
                        }
                        if store.preferences.enableWeather {
                            CoveLockWeatherSection(controller: weather,
                                style: CoveWeatherStyle(rawValue: store.preferences.weatherStyle) ?? .conditions,
                                motion: store.preferences.reduceMotion ? nil : CoveMotion.animation(preferences: store.preferences, hud: false))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if store.preferences.enableBattery || store.preferences.enableFocus || store.preferences.enableBluetooth {
                    CoveLockSystemSection(controller: store.system,
                                          showBattery: store.preferences.enableBattery,
                                          showFocus: store.preferences.enableFocus,
                                          showConnectivity: store.preferences.enableBluetooth)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        .modifier(CoveLockSurfaceStyle(style: store.preferences.nowPlayingStyle))
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
    }
}

private struct CoveLockSurfaceStyle: ViewModifier {
    let style: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), style != "frosted" {
            content.glassEffect((style == "clear" ? Glass.clear : Glass.regular).interactive(),
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
                .background(style == "frosted" ? .regularMaterial : .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

@MainActor
private struct CoveLockMediaSection: View {
    @ObservedObject var controller: MediaController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.state.available ? nonempty(controller.state.title, fallback: "Untitled") : "No media is playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(controller.state.available
                         ? nonempty(controller.state.artist, fallback: controller.state.source)
                         : "Start playback after unlocking.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if controller.state.available {
                    HStack(spacing: 4) {
                        transport("backward.end.fill", label: "Previous track", enabled: controller.state.supportsPrevious, action: controller.previous)
                        transport(controller.state.isPlaying ? "pause.fill" : "play.fill",
                                  label: controller.state.isPlaying ? "Pause" : "Play",
                                  enabled: controller.state.supportsPlayPause,
                                  action: controller.playPause)
                        transport("forward.end.fill", label: "Next track", enabled: controller.state.supportsNext, action: controller.next)
                    }
                }
            }
            if controller.state.available, controller.state.duration.isFinite,
               controller.state.duration > 0 {
                CovePlaybackTimeline(clock: controller.playback) { elapsed in
                    HStack(spacing: 9) {
                        Text(playbackTime(elapsed))
                        ProgressView(value: min(max(0, elapsed), controller.state.duration),
                                     total: controller.state.duration)
                            .tint(.primary)
                            .accessibilityLabel("Playback progress")
                        Text("−" + playbackTime(max(0, controller.state.duration - elapsed)))
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            if controller.lastError != nil {
                Text("Playback could not be updated.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func transport(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "play.fill" || symbol == "pause.fill" ? 19 : 13, weight: .semibold))
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private var artwork: some View {
        CoveArtwork(data: controller.state.available ? controller.state.artworkData : nil,
                    size: 56, radius: 12)
    }

    private func nonempty(_ text: String, fallback: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }

    private func playbackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "—" }
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600):" + String(format: "%02d:%02d", total / 60 % 60, total % 60) }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

@MainActor
private struct CoveLockCalendarSection: View {
    @ObservedObject var controller: ActivityController
    let showPrivateContent: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let authorized = controller.calendarAuthorization == "Authorized"
            let upcoming = authorized ? controller.events.filter { $0.end > context.date }.sorted { $0.start < $1.start } : []
            VStack(alignment: .leading, spacing: 4) {
                Label("Calendar", systemImage: "calendar")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if !authorized {
                    Text(controller.calendarAuthorization == "Saved calendar settings need review" ? "Review calendar sources after unlocking" : "Calendar access is off").font(.system(size: 11))
                } else if upcoming.isEmpty {
                    Text("No upcoming events").font(.system(size: 11))
                } else if showPrivateContent, let event = upcoming.first {
                    // No event title, time, location, calendar name, URL, help,
                    // or accessibility value is built in the hidden branch below.
                    Text(event.title.isEmpty ? "Untitled event" : event.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .privacySensitive()
                    Group {
                        if event.isAllDay {
                            Text("All day")
                        } else {
                            Text(event.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .environment(\.timeZone, event.timeZone)
                    .privacySensitive()
                } else {
                    Label("Event details hidden", systemImage: "lock.fill")
                        .font(.system(size: 11))
                    Text("\(upcoming.count) upcoming")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct CoveLockWeatherSection: View {
    @ObservedObject var controller: WeatherController
    let style: CoveWeatherStyle
    let motion: Animation?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            if controller.state.available {
                TimelineView(.periodic(from: .now, by: 60)) { context in content(at: context.date) }
            } else { content(at: Date()) }
        }
        .animation(systemReduceMotion ? nil : motion, value: style)
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(style.title, systemImage: style == .conditions && controller.state.available ? controller.state.symbol : style.symbol)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if controller.state.available {
                // A chosen location name can contain personal text. Keep it out
                // of this locked surface, including accessibility and help.
                CoveWeatherSummary(state: controller.state,
                    data: WeatherWidgetData(state: controller.state, style: style, at: now),
                    compact: true, showsLocation: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.isStale ? "Saved weather · Open-Meteo · CC BY 4.0" : "Open-Meteo · CC BY 4.0")
                    Text(verbatim: "https://open-meteo.com")
                    Text(verbatim: "https://creativecommons.org/licenses/by/4.0")
                    Text("Model forecast summarized; values rounded.")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                // Literal text keeps both URLs readable without activating a
                // browser or another app from this locked surface.
            } else {
                Text(controller.isLoading ? "Loading weather…" : "Weather unavailable")
                    .font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct CoveLockSystemSection: View {
    @ObservedObject var controller: SystemController
    let showBattery: Bool
    let showFocus: Bool
    let showConnectivity: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showBattery {
                item(batteryText, symbol: batterySymbol)
            }
            if showFocus {
                item(controller.state.focusAvailable ? (controller.state.focusEnabled ? "Focus on" : "Focus off") : "Focus unavailable",
                     symbol: controller.state.focusEnabled ? "moon.fill" : "moon")
            }
            if showConnectivity {
                item(connectivityText, symbol: "antenna.radiowaves.left.and.right")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func item(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryText: String {
        guard controller.state.batteryAvailable else { return "Battery unavailable" }
        guard controller.state.hasBattery else { return controller.state.isOnACPower ? "AC power" : "No battery" }
        return "\(min(100, max(0, controller.state.batteryPercent)))%\(controller.state.isCharging ? " charging" : "")"
    }

    private var batterySymbol: String {
        guard controller.state.batteryAvailable, controller.state.hasBattery else { return "bolt" }
        if controller.state.isCharging { return "battery.100percent.bolt" }
        let percent = min(100, max(0, controller.state.batteryPercent))
        let level = percent <= 10 ? 0 : percent <= 35 ? 25 : percent <= 60 ? 50 : percent <= 85 ? 75 : 100
        return "battery.\(level)percent"
    }

    private var connectivityText: String {
        if controller.state.bluetoothAvailable {
            let count = controller.state.bluetoothDevices.count
            return count == 0 ? "No Bluetooth devices" : "Bluetooth · \(count) connected"
        }
        return controller.state.audioOutputIsBluetooth ? "Bluetooth audio" : "Bluetooth unavailable"
    }
}
