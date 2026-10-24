import AppKit
import SwiftUI

/// A selected-day schedule and a locale-aware, six-week month. The parent supplies
/// the same controller to the full view and Duo so date selection survives switching.
@MainActor
struct CoveCalendarView: View {
    @ObservedObject private var activities: ActivityController
    let condensed: Bool
    @State private var showsCondensedSchedule = false

    init(activities: ActivityController, condensed: Bool = false) {
        self.activities = activities
        self.condensed = condensed
    }

    private var calendar: Calendar { .current }
    private var selectedDate: Date { activities.selectedCalendarDate }
    private var dayEvents: [CoveEvent] {
        activities.events(on: selectedDate).sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
    private var gridDays: [Date] {
        let range = ActivityController.monthGridRange(containing: selectedDate, calendar: calendar)
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: range.start) }
    }
    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        Group {
            if condensed {
                VStack(spacing: 3) {
                    monthHeader
                    monthGrid
                    condensedSchedule
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        dayHeader
                        schedule
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                    VStack(spacing: 4) {
                        monthHeader
                        monthGrid
                        HStack {
                            if !calendar.isDateInToday(selectedDate) {
                                Button("Today") { activities.loadSelectedDate(.now) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            Spacer(minLength: 0)
                            calendarMenu
                        }
                        .frame(height: 15)
                    }
                    .frame(width: 168)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 165)
        .onAppear { activities.loadSelectedDate(selectedDate) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
    }

    private var dayHeader: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedDate, format: .dateTime.weekday(.wide))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            Text(selectedDate, format: .dateTime.day())
                .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Spacer(minLength: 0)
            iconButton("Open calendar app", symbol: "arrow.up.forward.app") {
                activities.openCalendar(at: selectedDate)
            }
        }
        .frame(height: 58)
    }

    private var monthHeader: some View {
        HStack(spacing: 2) {
            Text(selectedDate, format: .dateTime.month(.wide).year())
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            iconButton("Previous month", symbol: "chevron.left") { moveMonth(-1) }
            iconButton("Next month", symbol: "chevron.right") { moveMonth(1) }
            if condensed { calendarMenu }
        }
        .frame(height: 19)
    }

    private var monthGrid: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[index])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(CoveNotchStyle.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 11)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(gridDays, id: \.self) { date in dayCell(date) }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let today = calendar.isDate(date, inSameDayAs: activities.calendarToday)
        let inMonth = calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        let events = activities.events(on: date)
        let colors = Array(Set(events.map(\.colorHex))).sorted()
        return Button { activities.loadSelectedDate(date) } label: {
            VStack(spacing: 0) {
                Text(date, format: .dateTime.day())
                    .font(.system(size: 9, weight: selected || today ? .bold : .regular, design: .rounded))
                    .foregroundStyle(today || selected ? Color.black :
                        inMonth ? Color.white.opacity(0.9) : CoveNotchStyle.secondary)
                    .frame(width: 16, height: 14)
                    .background(today ? Color.red : selected ? .white : .clear, in: Circle())
                HStack(spacing: 1) {
                    ForEach(colors.prefix(3), id: \.self) { color in
                        Circle().fill(calendarColor(color)).frame(width: 2, height: 2)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: condensed ? 17 : 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(date.formatted(date: .complete, time: .omitted) + " · \(events.count) events" + (today ? " · Today" : ""))
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(events.count) events" + (today ? ", Today" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var schedule: some View {
        if !activities.calendarEnabled {
            emptySchedule("Calendar is off", symbol: "calendar", detail: "Enable Calendar in OpenCove Settings.")
        } else if activities.calendarDetailsHidden {
            emptySchedule("Calendar details hidden", symbol: "lock.fill", detail: "Unlock to see event details.")
        } else if activities.calendarAuthorization == "Saved calendar settings need review" {
            ScrollView {
                CoveCalendarSourceRecovery(activities: activities)
            }
        } else if activities.calendarAuthorization != "Authorized" {
            accessSchedule
        } else if activities.isRefreshingCalendar && dayEvents.isEmpty {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Loading events…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if dayEvents.isEmpty {
            emptySchedule("No events", symbol: "calendar", detail: activities.calendarSources.isEmpty ? "No calendars are available." : "Nothing scheduled for this day.")
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(dayEvents) { event in eventRow(event) }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var accessSchedule: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
            Text(activities.calendarAuthorization == "Not requested" ? "Allow access to show your events." : activities.calendarAuthorization)
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            HStack(spacing: 8) {
                Button("Allow access", action: activities.requestCalendarAccess)
                    .disabled(["Restricted", "Unavailable"].contains(activities.calendarAuthorization))
                if activities.calendarAuthorization != "Not requested" {
                    Button("Settings") { openPrivacySettings() }
                }
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func emptySchedule(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: CoveEvent) -> some View {
        CoveCalendarScheduleRow(
            event: event, timeText: timeDescription(event), sourceText: sourceDescription(event),
            color: calendarColor(event.colorHex),
            open: { activities.openEvent(event.id) }, join: { activities.joinMeeting(event.id) }
        )
    }

    private var condensedSchedule: some View {
        Button { showsCondensedSchedule = true } label: {
            HStack(spacing: 5) {
                Image(systemName: activities.calendarDetailsHidden ? "lock.fill" : "calendar")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                VStack(alignment: .leading, spacing: 1) {
                    Text(condensedTitle).font(.system(size: 9, weight: .medium)).lineLimit(1)
                    Text(condensedDetail).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if dayEvents.count > 1 { Text("+\(dayEvents.count - 1)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)) }
                Image(systemName: "chevron.right").font(.system(size: 7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: .infinity)
        .accessibilityLabel("Show selected day schedule, \(condensedTitle)")
        .popover(isPresented: $showsCondensedSchedule) {
            VStack(alignment: .leading, spacing: 8) { dayHeader; schedule }
                .padding(12).frame(width: 280, height: 230)
                .background(Color.black).foregroundStyle(.white)
        }
    }

    private var condensedTitle: String {
        if !activities.calendarEnabled { return "Calendar is off" }
        if activities.calendarDetailsHidden { return "Details hidden" }
        if activities.calendarAuthorization == "Saved calendar settings need review" { return "Review calendar sources" }
        if activities.calendarAuthorization != "Authorized" { return "Connect calendar" }
        if activities.isRefreshingCalendar && dayEvents.isEmpty { return "Loading events…" }
        return dayEvents.first?.title ?? "No events"
    }

    private var condensedDetail: String {
        if !activities.calendarEnabled { return "Enable in Settings" }
        if activities.calendarDetailsHidden { return "Unlock to view" }
        if activities.calendarAuthorization == "Saved calendar settings need review" { return "Queries paused · choose sources" }
        if activities.calendarAuthorization != "Authorized" { return "Choose to allow access" }
        if let event = dayEvents.first { return timeDescription(event) }
        return selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var calendarMenu: some View {
        Menu {
            Button("Today") { activities.loadSelectedDate(.now) }
            Button("Refresh schedule", action: activities.refreshSchedule)
            Button("Open calendar app") { activities.openCalendar(at: selectedDate) }
            if !activities.calendarDetailsHidden && !activities.calendarSources.isEmpty {
                Divider()
                ForEach(activities.calendarSources) { source in
                    Toggle("\(source.title) · \(source.account)", isOn: Binding(
                        get: { !source.isExcluded },
                        set: { activities.setCalendarExcluded(source.id, excluded: !$0) }
                    ))
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Calendar sources and actions")
        .help("Calendar sources and actions")
    }

    private func moveMonth(_ delta: Int) {
        if let date = calendar.date(byAdding: .month, value: delta, to: selectedDate) {
            activities.loadSelectedDate(date)
        }
    }

    private func timeDescription(_ event: CoveEvent) -> String {
        if event.isAllDay {
            if let lastDay = calendar.date(byAdding: .day, value: -1, to: event.end),
               !calendar.isDate(event.start, inSameDayAs: lastDay) {
                return "All day · \(event.start.formatted(.dateTime.month(.abbreviated).day()))–\(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
            }
            return "All day"
        }
        let time = Date.FormatStyle.dateTime.hour().minute()
        if !calendar.isDate(event.start, inSameDayAs: event.end) {
            let format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
            return "\(event.start.formatted(format))–\(event.end.formatted(format))"
        }
        return "\(event.start.formatted(time))–\(event.end.formatted(time))"
    }

    private func sourceDescription(_ event: CoveEvent) -> String {
        event.location.isEmpty ? event.calendarName : "\(event.calendarName) · \(event.location)"
    }

    private func iconButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: 19, height: 19).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func calendarColor(_ hex: String) -> Color {
        guard let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return .gray }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

@MainActor
private struct CoveCalendarScheduleRow: View {
    let event: CoveEvent
    let timeText: String
    let sourceText: String
    let color: Color
    let open: () -> Void
    let join: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            Button(action: open) { details }
                .buttonStyle(.plain)
                .help(helpText)
                .accessibilityLabel("Open \(event.title), \(timeText), \(event.calendarName)")
            if event.meetingURL != nil {
                Button(action: join) {
                    Image(systemName: "video").font(.system(size: 10)).frame(width: 19, height: 19)
                }
                .buttonStyle(.plain)
                .help("Join \(event.title)").accessibilityLabel("Join \(event.title)")
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 5)
        .frame(height: 45)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: event.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Text(verbatim: timeText).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1)
            Text(verbatim: sourceText).font(.system(size: 8)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private var helpText: String {
        "\(event.title)\n\(timeText)\n\(event.calendarName) · \(event.timeZoneIdentifier)"
    }
}
