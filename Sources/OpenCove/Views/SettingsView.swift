// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var store: CoveStore
    private let updater: CoveUpdater?
    @ObservedObject private var keepAwakeStatus: LockScreenKeepAwakeStatus
    @ObservedObject private var activities: ActivityController
    @ObservedObject private var media: MediaController
    @ObservedObject private var notificationMirror: NotificationMirror
    @ObservedObject private var waveform: AudioWaveformController
    @ObservedObject private var system: SystemController
    @ObservedObject private var hardwareKeys: HardwareKeyController
    @ObservedObject private var settingsSync: CoveSettingsSyncController
    @StateObject private var permissions = CovePermissionAccess()
    @State private var selection: CoveSettingsPage? = .general
    @State private var showsResetConfirmation = false
    @State private var showsOnboarding = false
    @State private var selectedHUD: HUDKind = .volume
    @State private var hudPreviewMessage: String?

    init(store: CoveStore, initialPage: CoveSettingsPage = .general, updater: CoveUpdater? = nil,
         keepAwakeStatus: LockScreenKeepAwakeStatus? = nil) {
        self.store = store
        self.updater = updater
        self.keepAwakeStatus = keepAwakeStatus ?? LockScreenKeepAwakeStatus()
        self._selection = State(initialValue: initialPage)
        self.activities = store.activities
        self.media = store.media
        self.notificationMirror = store.notificationMirror
        self.waveform = store.waveform
        self.system = store.system
        self.hardwareKeys = store.hardwareKeys
        self.settingsSync = store.settingsSync
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.title2)
                        .foregroundStyle(CovePreferenceAccent.color(for: store.preferences.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenCove").font(.headline)
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)

                List(CoveSettingsPage.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .padding(.vertical, 3)
                        .tag(page)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 172, max: 190)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(currentPage.rawValue)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(currentPage.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 14)

                if let error = store.lastError {
                    CoveSettingsError(error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }
                if let error = activities.lastError {
                    CoveSettingsError(error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }
                if let notice = activities.lastNotice {
                    CoveSettingsNote(notice)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }

                Form {
                    switch currentPage {
                    case .general: generalSettings
                    case .appearance: appearanceSettings
                    case .media: mediaSettings
                    case .activities: activitySettings
                    case .weather: weatherSettings
                    case .permissions: permissionSettings
                    case .about: aboutSettings
                    }
                }
                .formStyle(.grouped)
                .id(currentPage)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity,
               minHeight: 500, idealHeight: 550, maxHeight: .infinity)
        .tint(CovePreferenceAccent.color(for: store.preferences.accent))
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .alert("Reset all settings?", isPresented: $showsResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Settings", role: .destructive) { store.resetPreferences() }
        } message: {
            Text("This restores the default settings. Your files and calendar events stay in place.")
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(store: store)
                .frame(width: 700, height: 550)
        }
    }

    private var currentPage: CoveSettingsPage { selection ?? .general }

    private var generalSettings: some View {
        Group {
            Section("Displays") {
                CoveDisplayPreference(store: store)
                Toggle("Hide when idle", isOn: preference(\.hideWhenIdle))
                Toggle("Hide in full-screen apps", isOn: preference(\.hideInFullscreen))
                Toggle("Hide in Mission Control", isOn: preference(\.hideInMissionControl))
                Toggle("Hide from screenshots and recordings", isOn: preference(\.hideFromScreenCapture))
                    .help("Some capture tools can still record the panel.")
                Toggle("Hide while the Now Playing app is active", isOn: preference(\.hideWhenMediaAppActive))
                CoveSettingsNote("Hides the panel while you use the music app itself. Alerts still appear.")
                Toggle("Hide for apps in the Games category", isOn: preference(\.hideForGamesCategory))
                CoveSettingsNote("Works with apps that macOS lists as games. Alerts still appear.")
            }

            Section("Lock-screen widgets") {
                Text("Keep Awake").font(.headline)
                CoveSettingsNote(keepAwakeStatus.projection.message)
                if let outcome = keepAwakeStatus.projection.lastOutcome {
                    LabeledContent("Last Keep Awake outcome", value: outcome.resultCode)
                }
                CoveSettingsNote("Keeps the display awake for 1–120 minutes (5 by default). Start it from the lock-screen card. Closing the lid or choosing Sleep still works.")
                Toggle("Show widgets on the lock screen", isOn: preference(\.showOnLockScreen))
                Toggle("Use the same widgets as activities", isOn: preference(\.lockWidgetsFollowActivities))
                CoveSettingsNote("These choices apply only to this Mac. Changing mode clears independent choices.")
                Toggle("Show event details while locked", isOn: preference(\.showLockScreenPrivateContent))
                    .disabled(!store.preferences.showOnLockScreen)
                CoveSettingsNote("Widgets appear while your Mac is locked and the display is on. macOS can limit what shows.")
                if !store.preferences.enablePrivateAPIs {
                    CoveSettingsNote("Turn on private macOS integrations in Permissions to use lock-screen widgets.")
                } else if !system.state.lockStateKnown {
                    CoveSettingsNote(system.state.capabilityMessages["lock"] ?? "Waiting for a confirmed session lock state.")
                }
                if !store.preferences.lockWidgetsFollowActivities {
                    CoveSettingsNote("Each widget reads its data even when the matching activity is off. Widgets never ask for new access.")
                    ForEach(CoveLockWidget.allCases) { widget in
                        Toggle("Enable \(widget.title) widget and reading", isOn: Binding(
                            get: { store.preferences[keyPath: widget.selectionKey] },
                            set: { store.setIndependentLockWidget(widget, enabled: $0) }))
                            .disabled(!store.preferences.showOnLockScreen || !store.preferences.enablePrivateAPIs)
                        CoveSettingsNote(widget.disclosure)
                    }
                    CoveSettingsNote("Turning an activity off also turns off its widget.")
                    CoveSettingsNote("If a change cannot be saved, it applies until OpenCove restarts.")
                }
            }

            Section("Interaction") {
                Picker("Compact activity", selection: preference(\.compactActivity)) {
                    Text("Automatic").tag("automatic")
                    Text("Now Playing").tag("media")
                    Text("Calendar").tag("calendar")
                    Text("Timer").tag("timer")
                }
                CoveSettingsNote("Shows this activity first when available. Automatic picks media, then timer, then calendar.")
                Picker("Expanded layout", selection: preference(\.expandedLayout)) {
                    Text("Automatic").tag("automatic")
                    Text("Now Playing").tag("media")
                    Text("Calendar").tag("calendar")
                    Text("Media & Calendar").tag("duo")
                }
                CoveSettingsNote("Automatic shows media and calendar side by side when music plays during or before an event.")
                Toggle("Swipe to skip media", isOn: preference(\.swipeToSkip))
                Toggle("Reverse skip swipe direction", isOn: preference(\.reverseSkipSwipe))
                    .disabled(!store.preferences.swipeToSkip)
                CoveSettingsNote("Swipe left on media for the next track and right for the previous one. Swipe at the top edge to change sections.")
                Picker("Open and close shortcut", selection: preference(\.toggleShortcut)) {
                    ForEach(CoveHotKeyChoice.allCases) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                if case .unavailable = store.hotKey.status {
                    CoveSettingsNote("Another app already uses this shortcut. Choose a different one.", symbol: "exclamationmark.triangle")
                }
                Toggle("Expand on hover", isOn: preference(\.expandOnHover))
                Toggle("Don't expand on hover when idle", isOn: preference(\.disableIdleHoverExpansion))
                    .disabled(!store.preferences.expandOnHover)
                CoveSettingsNote("When nothing is playing, hovering does not open the panel. Click it or use the menu instead.")
                CovePreferenceSlider(
                    title: "Hover delay", value: preference(\.hoverDelay),
                    range: 0...2, step: 0.05, format: "%.2f s"
                )
                .disabled(!store.preferences.expandOnHover)
                CovePreferenceSlider(
                    title: "Collapse delay", value: preference(\.collapseDelay),
                    range: 0.1...5, step: 0.1, format: "%.1f s"
                )
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: preference(\.launchAtLogin))
                    .disabled(CovePaths.isDevelopment)
                LabeledContent("Login item", value: store.loginItemStatus)
                CoveSettingsNote("macOS manages login access in System Settings → General → Login Items.")
                Toggle("Hide menu bar icon", isOn: preference(\.hideMenuBarIcon))
                if store.preferences.hideMenuBarIcon {
                    CoveSettingsNote("To return here, open OpenCove again from Finder or Spotlight, or use the panel's menu.")
                }
                HStack {
                    Text("Setup")
                    Spacer()
                    Text(store.preferences.completedOnboarding ? "Completed" : "Not completed")
                        .foregroundStyle(.secondary)
                    Button("Show Setup…") { showsOnboarding = true }
                }
            }

            Section("iCloud settings") {
                Toggle("Sync settings with iCloud on this Mac", isOn: preference(\.syncSettingsWithiCloud))
                LabeledContent("Status", value: settingsSync.status)
                CoveSettingsNote(settingsSync.detail)
                CoveSettingsNote("Syncs appearance and behavior across your Macs. Displays, permissions, files and calendar data stay on this Mac.")
                if settingsSync.canChooseLocal {
                    HStack {
                        if settingsSync.canChooseCloud {
                            Button("Use iCloud Settings") { settingsSync.useCloudSettings() }
                        }
                        Button("Use This Mac's Settings") { settingsSync.useThisMacSettings() }
                    }
                    CoveSettingsNote("Choose which copy to keep. Only appearance and behavior settings change.")
                }
                if settingsSync.canCheck {
                    Button("Check for Changes") { settingsSync.checkForChanges() }
                } else if settingsSync.canReconnect {
                    Button("Reconnect to iCloud") { settingsSync.reconnect() }
                }
            }

            Section {
                HStack {
                    Text("Restore default preferences")
                    Spacer()
                    Button("Reset Settings…", role: .destructive) { showsResetConfirmation = true }
                }
            }
        }
    }

    private var appearanceSettings: some View {
        Group {
            Section("Style") {
                Picker("Accent color", selection: preference(\.accent)) {
                    ForEach(CovePreferenceAccent.allCases) { accent in
                        Text(accent.rawValue.capitalized).tag(accent.rawValue)
                    }
                    if !CovePreferenceAccent.allCases.contains(where: { $0.rawValue == store.preferences.accent }) {
                        Text("Custom (\(store.preferences.accent))").tag(store.preferences.accent)
                    }
                }
                CoveSettingsNote("OpenCove follows your Mac’s light or dark appearance.")
            }

            Section("Panel shape") {
                Toggle("Show contrast outline", isOn: preference(\.showContrastOutline))
                if store.preferences.showContrastOutline {
                    Toggle("Use accent color for outline", isOn: preference(\.useAccentOutline))
                }
                CoveSettingsNote("Add a thin outline around the panel. Increase Contrast always uses opaque white.")
                Toggle("Simulate a notch", isOn: preference(\.simulateNotch))
                CoveSettingsNote("Draws a notch-shaped panel on displays without a notch. Width and Height set its size.")
            }

            Section("Compact size") {
                CovePreferenceSlider(
                    title: "Width", value: preference(\.notchWidth),
                    range: 120...400, step: 1, format: "%.0f pt"
                )
                CovePreferenceSlider(
                    title: "Height", value: preference(\.notchHeight),
                    range: 24...64, step: 1, format: "%.0f pt"
                )
                CovePreferenceSlider(
                    title: "Corner radius", value: preference(\.cornerRadius),
                    range: 8...40, step: 1, format: "%.0f pt"
                )
                CoveSettingsNote("The panel also adapts to the display’s camera housing.")
            }

            Section("Motion & feedback") {
                Toggle("Reduce motion", isOn: preference(\.reduceMotion))
                Picker("Default overlay animation", selection: preference(\.hudSpeed)) {
                    Text("Smooth").tag("smooth")
                    Text("Fast").tag("fast")
                    Text("Instant").tag("instant")
                }
                .pickerStyle(.segmented)
                CovePreferenceSlider(
                    title: "Animation speed", value: preference(\.animationSpeed),
                    range: 0.25...2, step: 0.05, format: "%.2f×"
                )
                .disabled(store.preferences.reduceMotion)
                Toggle("Haptic feedback", isOn: preference(\.enableHaptics))
                CoveSettingsNote("Haptic feedback requires a supported trackpad.")
            }
        }
    }

    private var mediaSettings: some View {
        Group {
            Section("Now Playing") {
                Toggle("Show media controls", isOn: preference(\.enableMedia))
                Picker("Preferred player", selection: preference(\.preferredMusicApp)) {
                    Text("System Now Playing").tag("system")
                    Text("Music").tag("music")
                    Text("Spotify").tag("spotify")
                }
                CoveSettingsNote("Show the current track and control playback from the panel. Availability depends on the player.")
                Toggle("Peek when the song changes", isOn: preference(\.peekOnSongChange))
                if store.preferences.peekOnSongChange {
                    CovePreferenceSlider(title: "Peek duration", value: preference(\.mediaPeekDuration),
                                         range: 1...10, step: 0.5, format: "%.1f sec")
                    CoveSettingsNote("Briefly shows the new track, then returns to the compact view.")
                }
                Toggle("Hide paused media from compact view", isOn: preference(\.hidePausedMedia))
                if store.preferences.hidePausedMedia {
                    CovePreferenceSlider(title: "Pause delay", value: preference(\.pausedMediaDelay),
                                         range: 1...300, step: 1, format: "%.0f sec")
                    CoveSettingsNote("Full playback controls stay available. Playing or changing the item restores the compact media view.")
                }
                HStack {
                    Text("System integration")
                    Spacer()
                    Text(store.preferences.enablePrivateAPIs ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                    Button("Review…") { selection = .permissions }
                }
                if let diagnostic = media.state.sourceDiagnostic {
                    CoveSettingsNote(diagnostic, symbol: "info.circle")
                }
                if let error = media.lastError {
                    CoveSettingsError(error)
                }
            }

            Section("Media appearance") {
                Picker("Lock widget surface", selection: preference(\.nowPlayingStyle)) {
                    Text("Glass").tag("glass")
                    Text("Clear").tag("clear")
                    Text("Frosted").tag("frosted")
                }
                .pickerStyle(.segmented)
                Toggle("Use artwork colors", isOn: preference(\.musicColorAccent))
                Toggle("Show total duration", isOn: preference(\.showMediaTotalDuration))
                Toggle("Progress line in compact view", isOn: preference(\.showCompactProgress))
                Toggle("Volume control on the lock screen", isOn: preference(\.showLockScreenVolume))
                Toggle("Artwork glow", isOn: preference(\.mediaArtworkGlow))
                    .help("Casts a soft light from the album artwork into the expanded panel.")
                Toggle("Hide title extras", isOn: preference(\.hideMediaTitleExtras))
                    .help("Hides tags such as Remastered, Bonus Track, feat. and Single Version. Remix, Live and Acoustic stay visible.")
                CoveSettingsNote("Shows the track length instead of the time remaining.")
                Picker("Playback indicator", selection: Binding(get: {
                    !store.preferences.showPlaybackIndicator ? "none" : store.preferences.showLiveWaveform ? "live" : "decorative"
                }, set: { mode in
                    store.updatePreferences {
                        $0.showPlaybackIndicator = mode != "none"
                        $0.showLiveWaveform = mode == "live"
                    }
                })) {
                    Text("None").tag("none")
                    Text("Decorative bars").tag("decorative")
                    Text("System audio levels").tag("live")
                }
                if store.preferences.usesLiveWaveform {
                    Text(waveform.status).font(.caption).foregroundStyle(.secondary)
                    Button("Allow System Audio Levels") { store.requestWaveformAccess() }
                }
                CoveSettingsNote("Optional system audio levels use Screen & System Audio Recording access. Audio stays in memory and is not saved.")
            }

            Section("Player fallback") {
                Toggle("Allow AppleScript player control", isOn: preference(\.allowAppleScript))
                CoveSettingsNote("Controls Music and Spotify after you allow Automation access. Other sources use the private media integration.")
                Button("Allow Player Automation") { store.media.requestAppleScriptAccess() }
                    .disabled(!store.preferences.allowAppleScript)
                Button("Open Automation Settings…") {
                    CovePermissionAccess.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
            }

            Section {
                CoveSettingsNote("OpenCove does not need microphone access to show or control media.", symbol: "mic.slash")
            }
        }
    }

    private var activitySettings: some View {
        Group {
            Section("System overlays") {
                Toggle("Replace hardware-key HUDs", isOn: preference(\.replaceSystemHUDs))
                    .disabled(!store.preferences.enablePrivateAPIs)
                if store.preferences.replaceSystemHUDs {
                    Text(hardwareKeys.status).font(.caption).foregroundStyle(.secondary)
                    Button("Allow Hardware-Key Access") { hardwareKeys.requestAccessAndStart() }
                        .disabled(!store.preferences.enablePrivateAPIs)
                }
                Toggle("Volume", isOn: preference(\.enableVolumeHUD))
                Toggle("Display brightness", isOn: preference(\.enableBrightnessHUD))
                Toggle("Show BetterDisplay brightness feedback", isOn: Binding(
                    get: { store.preferences.enableBetterDisplayFeedback },
                    set: { store.setBetterDisplayFeedback(enabled: $0) }))
                    .disabled(!store.preferences.enableBrightnessHUD && !store.preferences.enableBetterDisplayFeedback)
                CoveSettingsNote("Shows brightness changes that BetterDisplay reports for an external display you select. Needs overlay labels.")
                CoveSettingsNote("In BetterDisplay, turn on Integration → Dispatch OSD notifications. Turn off BetterDisplay's own overlay to avoid duplicates.")
                Text(store.betterDisplayFeedbackStatus).font(.caption).foregroundStyle(.secondary)
                Button("Preview BetterDisplay feedback") { hudPreviewMessage = store.previewBetterDisplayFeedback() }
                    .disabled(store.isExpanded || !store.preferences.enableBetterDisplayFeedback)
                CoveSettingsNote("The preview uses the last report from the past 5 seconds.")
                Picker("Level bar style", selection: preference(\.hudProgressStyle)) {
                    ForEach(CoveHUDBarStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                }
                Toggle("Brightness symbol glow", isOn: preference(\.brightnessHUDGlow))
                    .disabled(!store.preferences.enableBrightnessHUD)
                    .help("Add a soft glow to the sun symbol on display brightness overlays.")
                Toggle("Battery & charging", isOn: preference(\.enableBattery))
                Toggle("Low Power Mode changes", isOn: Binding(
                    get: { store.preferences.enableLowPowerModeAlerts },
                    set: { store.setLowPowerModeAlerts(enabled: $0) }))
                    .disabled(!store.preferences.enableBattery && !store.preferences.enableLowPowerModeAlerts)
                CoveSettingsNote("Shows an overlay when Low Power Mode turns on or off.")
                CoveSettingsNote("Needs Battery & charging. Turning that off also turns this off.")
                Text(store.lowPowerModeAlertsStatus).font(.caption).foregroundStyle(.secondary)
                Toggle("Bluetooth & audio devices", isOn: preference(\.enableBluetooth))
                Toggle("Focus status", isOn: preference(\.enableFocus))
                Toggle("Show overlay labels", isOn: preference(\.showHUDLabels))
                    .help("Show titles and subtitles on compact overlays.")
                Toggle("Show overlay percentage", isOn: preference(\.showHUDPercentage))
                    .help("Show a percentage when a compact overlay has a numeric reading.")
                CovePreferenceSlider(
                    title: "Default overlay duration", value: preference(\.hudDuration),
                    range: 0.5...10, step: 0.5, format: "%.1f s"
                )
            }

            Section("Battery") {
                Toggle("Show battery percentage", isOn: preference(\.showBatteryPercentage))
                    .disabled(!store.preferences.enableBattery)
                Toggle("Warn on low battery", isOn: preference(\.warnOnLowBattery))
                    .disabled(!store.preferences.enableBattery)
                CovePreferenceSlider(title: "Low battery level", value: preference(\.lowBatteryThreshold),
                                     range: 5...50, step: 5, format: "%.0f%%")
                    .disabled(!store.preferences.enableBattery || !store.preferences.warnOnLowBattery)
                CoveSettingsNote("A warning also appears at 5%. Warnings appear only on battery power.")
            }

            Section("Sounds") {
                soundToggle("Lock", .lock)
                soundToggle("Unlock", .unlock)
                soundToggle("Charger connected", .powerConnected)
                soundToggle("Low battery", .lowBattery)
                soundToggle("Calendar event starts", .eventStart)
                soundToggle("Hourly chime", .hourlyChime)
                CovePreferenceSlider(title: "Sound volume", value: preference(\.soundVolume),
                                     range: 0.05...1, step: 0.05, format: "%.0f%%", displayScale: 100)
                CoveSettingsNote("Uses built-in macOS sounds and follows your output volume.")
            }

            Section("Overlay timing") {
                Picker("Category", selection: $selectedHUD) {
                    ForEach(HUDKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .onChange(of: selectedHUD) { _, _ in hudPreviewMessage = nil }
                Toggle("Use default duration", isOn: Binding(
                    get: { store.preferences[keyPath: selectedHUD.durationKey] == 0 },
                    set: { useGlobal in
                        store.updatePreferences { $0[keyPath: selectedHUD.durationKey] = useGlobal ? 0 : $0.hudDuration }
                    }))
                CovePreferenceSlider(title: "Duration", value: Binding(
                    get: { store.preferences.duration(for: selectedHUD) },
                    set: { value in
                        store.updatePreferences { $0[keyPath: selectedHUD.durationKey] = value }
                    }), range: 0.5...10, step: 0.5, format: "%.1f s")
                    .disabled(store.preferences[keyPath: selectedHUD.durationKey] == 0)
                Picker("Appearance animation", selection: preference(selectedHUD.speedKey)) {
                    Text("Use default").tag("global")
                    Text("Smooth").tag("smooth")
                    Text("Fast").tag("fast")
                    Text("Instant").tag("instant")
                }
                .disabled(store.preferences.reduceMotion || systemReduceMotion)
                HStack {
                    Button("Preview overlay") { hudPreviewMessage = store.previewHUD(selectedHUD) }
                        .disabled(store.isExpanded)
                    Button("Reset category timing") {
                        store.updatePreferences {
                            $0[keyPath: selectedHUD.durationKey] = 0
                            $0[keyPath: selectedHUD.speedKey] = "global"
                        }
                    }
                }
                CoveSettingsNote(store.isExpanded ? "Collapse the panel to preview an overlay."
                    : "Preview uses available readings. It does not change volume or brightness, or post a system notification.")
                CoveSettingsNote("Duration changes apply to the next overlay. Repeated events restart its duration.")
                if let hudPreviewMessage { Text(hudPreviewMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Activities") {
                Toggle("Timer", isOn: preference(\.enableTimer))
                Toggle("File tray", isOn: preference(\.enableFileTray))
                CoveSettingsNote("The file tray holds files you add. It does not scan your folders.")
            }

            Section("Calendar & meetings") {
                Toggle("Show calendar events", isOn: preference(\.enableCalendar))
                Toggle("Show selected-day list", isOn: preference(\.showCalendarList))
                CoveSettingsNote("Keep the month grid when the list is hidden. Your selected day stays selected.")
                Toggle("Show event dots", isOn: preference(\.showCalendarEventIndicators))
                CoveSettingsNote("Month-grid dots only. Event counts stay in day help and accessibility information.")
                Toggle("Use source colors in Calendar view", isOn: preference(\.useCalendarViewSourceColors))
                CoveSettingsNote("Only month-grid event dots and selected-day list accents, including the condensed list popover.")
                Toggle("Show declined events", isOn: preference(\.showDeclinedCalendarEvents))
                CoveSettingsNote("Include events you declined. Canceled events and excluded calendars stay hidden.")
                Toggle("Exclude subscribed calendars", isOn: preference(\.excludeSubscribedCalendars))
                CoveSettingsNote("Hide events from subscribed calendars, including CalDAV subscriptions. Your individual calendar selections stay saved.")
                Picker("Calendar app", selection: preference(\.preferredCalendarApp)) {
                    Text("Calendar").tag("calendar")
                    Text("Fantastical").tag("fantastical")
                    Text("Notion Calendar").tag("notionCalendar")
                }
                LabeledContent("Calendar access", value: store.preferences.enableCalendar ? activities.calendarAuthorization : "Activity disabled")
                if activities.calendarAuthorization == "Saved calendar settings need review" {
                    CoveCalendarSourceRecovery(activities: activities)
                }
                Toggle("Event alerts", isOn: Binding(get: { activities.calendarAlertsEnabled }, set: { activities.setCalendarAlertsEnabled($0) }))
                Stepper("Alert \(activities.calendarPreEventLeadMinutes) minutes before", value: Binding(get: { activities.calendarPreEventLeadMinutes }, set: { activities.setCalendarPreEventLeadMinutes($0) }), in: 0...120)
                if store.preferences.enableCalendar {
                    ForEach(activities.calendarSources) { calendar in
                        Toggle(calendar.title, isOn: Binding(get: { !calendar.isExcluded }, set: { activities.setCalendarExcluded(calendar.id, excluded: !$0) }))
                    }
                }
            }

            Section("Connected devices") {
                AudioOutputPicker(system: system)
                LabeledContent("Bluetooth access", value: system.state.bluetoothAuthorization)
                Button("Allow Bluetooth Access") {
                    guard store.preferences.enableBluetooth else { return }
                    system.requestBluetoothAccess()
                }
                    .disabled(!store.preferences.enableBluetooth || system.isRequestingBluetoothAccess)
                LabeledContent("Focus access", value: system.state.focusAuthorization)
                Button("Allow Focus Status") {
                    guard store.preferences.enableFocus else { return }
                    system.requestFocusAccess()
                }
                    .disabled(!store.preferences.enableFocus || system.isRequestingFocusAccess)
                if let error = system.lastError { CoveSettingsError(error) }
            }

            Section("Time to leave") {
                TravelSettingsView(controller: store.travel)
            }

            Section("Notifications") {
                Toggle("Show OpenCove notification overlays", isOn: preference(\.enableNotifications))
                Toggle("Mirror system notification banners", isOn: preference(\.mirrorSystemNotifications))
                CoveSettingsNote("Shows new notification banners in the panel. Needs Accessibility access. Older notifications are not shown.")
                CoveSettingsNote(store.mirroringStatus, symbol: "info.circle")
                Button("Review Permissions…") { selection = .permissions }
            }

            Section("Weather") {
                Button("Weather settings…") { selection = .weather }
                CoveSettingsNote("Choose a weather widget style and location.")
            }
        }
    }

    private var weatherSettings: some View {
        Section("Weather widget") {
            Toggle("Enable weather", isOn: preference(\.enableWeather))
            Picker("Weather widget style", selection: preference(\.weatherStyle)) {
                ForEach(CoveWeatherStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
            }
            CoveSettingsNote("Choose a location before any weather request. Device location is optional.")
            if store.preferences.enableWeather {
                WeatherView(controller: store.weather,
                            style: CoveWeatherStyle(rawValue: store.preferences.weatherStyle) ?? .conditions,
                            motion: store.preferences.reduceMotion ? nil : CoveMotion.animation(preferences: store.preferences, hud: false))
            }
        }
    }

    private var permissionSettings: some View {
        Group {
            Section("Access") {
                CovePermissionRow(
                    title: "Calendar", symbol: "calendar",
                    detail: "Read upcoming events and meeting links.",
                    status: store.preferences.enableCalendar ? activities.calendarAuthorization : "Activity disabled"
                ) {
                    Button("Request Access") { activities.requestCalendarAccess() }
                        .disabled(!store.preferences.enableCalendar || ["Restricted", "Unavailable", "Disabled", "Saved calendar settings need review"].contains(activities.calendarAuthorization))
                    Button("System Settings…") {
                        CovePermissionAccess.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    }
                }
                if activities.calendarAuthorization == "Saved calendar settings need review" {
                    CoveCalendarSourceRecovery(activities: activities)
                }
                CovePermissionRow(
                    title: "Notifications", symbol: "bell.badge",
                    detail: "Show OpenCove alerts, including timer alerts.",
                    status: activities.notificationAuthorization
                ) {
                    if !activities.nativeNotificationsEnabled {
                        Button("Allow Notifications") { activities.requestNotificationAccess() }
                    } else {
                        Button("Stop System Alerts") { activities.setNativeNotificationsEnabled(false) }
                    }
                    Button("System Settings…") { permissions.openNotificationSettings() }
                }
                CovePermissionRow(
                    title: "Accessibility", symbol: "accessibility",
                    detail: "Required for optional notification banner mirroring.",
                    status: permissions.accessibilityGranted ? "Allowed" : "Not allowed"
                ) {
                    if !permissions.accessibilityGranted {
                        Button("Request Access") {
                            notificationMirror.requestAccess()
                            permissions.refresh()
                        }
                    }
                    Button("System Settings…") {
                        CovePermissionAccess.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                }
            }

            Section("System integrations") {
                Toggle("Enable private macOS integrations", isOn: preference(\.enablePrivateAPIs))
                CoveSettingsNote("Now Playing, brightness and Focus use private macOS interfaces. A macOS update can break them.", symbol: "info.circle")
                CoveSettingsNote("This switch does not bypass macOS permissions or lock-screen security.")
            }
        }
    }

    private var aboutSettings: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(CovePreferenceAccent.color(for: store.preferences.accent))
                        .frame(width: 62, height: 62)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenCove").font(.title2.bold())
                        Text(appVersion).font(.callout).foregroundStyle(.secondary)
                        Text("An independent native app for your Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Updates") {
                if let updater { CoveUpdaterSettings(updater: updater) }
                else { CoveSettingsNote("Updates are off in this verification view.") }
            }

            Section("Open source") {
                LabeledContent("License", value: "MIT")
                CoveSettingsNote("Independently authored. OpenCove is not affiliated with or endorsed by Alcove. It contains no Alcove code or artwork.")
            }

            Section("Feature availability") {
                CoveSettingsNote("Media, device status, calendar, timers, weather, and the optional file tray use live data. Hardware support and granted permissions affect availability.")
                CoveSettingsNote("Automatic audio mixing is controlled by your player. Notification mirroring is best effort. Lock-screen visibility depends on macOS.")
            }

            Section {
                Button("Review Setup…") { showsOnboarding = true }
            }
        }
    }

    private var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development build"
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    private func soundToggle(_ title: String, _ event: CoveSoundEvent) -> some View {
        HStack {
            Toggle(title, isOn: preference(event.writableKey))
            Button {
                store.sounds.play(event, volume: store.preferences.soundVolume)
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
            .help("Play the \(title.lowercased()) sound")
            .accessibilityLabel("Play \(title) sound")
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<CovePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in
                store.updatePreferences { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func refreshPermissions() {
        permissions.refresh()
        activities.refreshCalendar()
    }
}

enum CoveSettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case media = "Media"
    case activities = "Activities"
    case weather = "Weather"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .media: return "music.note"
        case .activities: return "square.stack.3d.up"
        case .weather: return "cloud.sun"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Make OpenCove fit the way you use your Mac."
        case .appearance: return "A small space, made yours."
        case .media: return "Keep playback within reach."
        case .activities: return "Choose what appears in your panel."
        case .weather: return "Weather for the location you choose."
        case .permissions: return "You choose which access to grant."
        case .about: return "A little more room for what matters."
        }
    }
}

enum CovePreferenceAccent: String, CaseIterable, Identifiable {
    case mint, blue, purple, pink, orange
    var id: String { rawValue }

    static func color(for value: String) -> Color {
        switch value {
        case "mint": return .mint
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        default: return .accentColor
        }
    }
}

struct CovePreferenceSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var displayScale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * displayScale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value * displayScale))
        }
        .padding(.vertical, 3)
    }
}

struct CoveSettingsNote: View {
    let text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .frame(width: 15)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Keep persistence and recovery errors visible on every settings page.
struct CoveSettingsError: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView {
            Label {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 100)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption)
        .foregroundStyle(.orange)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct CoveCalendarSourceRecovery: View {
    @ObservedObject var activities: ActivityController
    @State private var confirmsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved calendar sources could not be read. Event queries are paused. Resetting sources removes the saved exclusions and uses all calendars you allow OpenCove to read.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset Calendar Sources") { confirmsReset = true }
        }
        .alert("Use all calendars?", isPresented: $confirmsReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Calendar Sources") { activities.setExcludedCalendarIdentifiers([]) }
        } message: {
            Text("This removes the saved calendar exclusions. OpenCove will use all calendars it has permission to read. You can then exclude sources in Settings.")
        }
    }
}

struct CovePermissionRow<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    let status: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
                .padding(.leading, 33)
        }
        .padding(.vertical, 5)
    }
}

/// Reads permission state without requesting access. Prompts are button actions only.
@MainActor
final class CovePermissionAccess: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openNotificationSettings() {
        Self.openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    static func openSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
