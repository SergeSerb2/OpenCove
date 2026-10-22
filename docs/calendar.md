# Calendar

OpenCove reads real macOS EventKit events. It does not create, change, or delete calendars, events, or reminders. It does not read another calendar app's private database. The UI and behavior are independently authored from the public feature brief. The default lead time below is an OpenCove choice, not a claim about Alcove's current settings.

## Store and view integration

The notch uses these native calendar layouts:

```swift
CoveCalendarView(activities: activities)                  // approximately 400 × 165
CoveCalendarView(activities: activities, condensed: true) // approximately 180–200 × 165, for Duo
```

The full view places the selected-day schedule on the left and a month grid on the right. The condensed view keeps the month and opens the full selected-day schedule in a popover. Both use the controller's selection, so a surface switch preserves the selected day. Previous/next month buttons, Today, native buttons and menus, source toggles, refresh, and app-opening actions are available without a gesture. The grid follows the system first weekday and uses 42 civil days. Today has a red ring; selection has a filled light circle. Source colors mark real events. Accessible labels include event counts and source names, so color is not the only signal.

The store sets the calendar switch and app preference at startup and after saved preference changes:

```swift
activities.setCalendarEnabled(preferences.enableCalendar)
activities.preferredCalendarApp = preferences.preferredCalendarApp
```

The store supplies session and lock privacy before presenting calendar content:

```swift
activities.setCalendarPrivacy(
    isLocked: !sessionActive || system.state.isLocked,
    hideSensitiveDetails: !sessionActive || !preferences.showLockScreenPrivateContent
)
```

Call this before presenting any lock-screen calendar UI. The service does not detect lock state. When hidden, the published `events`, `events(on:)`, `nextUpcomingEvent`, `currentEvent`, `startingSoonEvent`, and `eventActivity` use a generic title/source and omit location and meeting links. The view displays a privacy state. Opening event details and joining meetings are blocked while hidden. Event times remain available for activity timing. Published source names and account names are redacted while details are hidden. The store clears existing calendar and travel HUDs when the privacy gate closes.

`setCalendarEnabled(_ enabled: Bool)` gates only calendar work. False cancels queued refresh work, clears published events/sources/activity and the selected-month cache, reports `Disabled`, and blocks calendar reads, access requests, and event HUD delivery. An EventKit call already executing cannot be interrupted, but cancellation stops subsequent processing/queries and revision checks discard its result. The selected date itself remains available. Filters, the saved alert opt-in, and the configured lead are unchanged. True refreshes only with existing full access and never requests permission. Tray, timer, and notification services keep running.

## Permission and date reads

Only the explicit `requestCalendarAccess()` action requests full EventKit access. Startup, date selection, refresh, and countdown work never request permission. The packaged app needs `NSCalendarsFullAccessUsageDescription`. Denied, restricted, write-only, and unavailable states cannot fetch events. The view provides an Allow action and a Calendar privacy settings action where appropriate.

```swift
activities.loadSelectedDate(date)
let events = activities.events(on: date)
```

`loadSelectedDate` selects the day and starts an asynchronous EventKit read on a cache miss. Observe the controller and `isRefreshingCalendar` for completion. `events(on:)` is a cache-only UI API: it returns all real events intersecting that civil day after its grid has loaded, or an empty array before then. It includes earlier events on today, all-day events, events spanning midnight, and zero-duration events. It does not fabricate data for an unloaded date. It uses an exclusive day end, so an event ending at midnight does not appear on the following day.

`refreshCalendar()` and its alias `refreshSchedule()` refresh the selected 42-day grid and the existing seven-day upcoming feed. A dedicated serial worker owns its own EventKit store and converts results to value models before returning to the main actor. Reads wait 120 ms to combine rapid selections/store-change bursts; revision checks discard stale results. Distant months use separate bounded grid/upcoming queries rather than reading every intervening month. No EventKit objects leave the worker. No event data is saved to disk.

Canceled events and events declined by the current user are omitted. Other overlapping events remain separate. A recurring occurrence ID includes its calendar, EventKit identifier, and start instant. Source color, source title, location, supported meeting URL, all-day state, and original time-zone identifier come from EventKit. Displayed times use the current system time zone; the row help includes the event's source time zone.

The service refreshes on EventKit changes, app activation, system clock/time-zone changes, wake, and every minute while started. A separate one-second activity clock updates a visible event countdown without querying EventKit. Future events schedule an absolute phase boundary; empty, disabled, or unauthorized calendars have no second ticker. At midnight the selected day follows today only if the user had selected today. Other selections remain selected. Civil-day/month arithmetic handles daylight-saving transitions; it does not assume each day lasts 86,400 seconds.

## Sources and persistent options

`calendarSources` lists available EventKit event calendars, with `id`, `title`, `account`, `colorHex`, and `isExcluded`. EventKit is the source of truth; accounts available only inside another app are not imported.

```swift
activities.setCalendarExcluded(source.id, excluded: true)
activities.setExcludedCalendarIdentifiers(selectedExcludedIDs) // Set<String>
activities.setCalendarPreEventLeadMinutes(15) // 0…1440; 0 disables pre-event alerts
activities.setCalendarAlertsEnabled(true)
```

Filters apply to selected-day schedules, grid markers, the upcoming feed, live activity, and alerts. Excluding every source returns no events; an empty source array never becomes an unfiltered EventKit query. A disconnected/deleted calendar disappears after refresh. Its exclusion ID is kept so it stays excluded if the same source returns. Replacing the filter with an empty set includes all current sources.

Options are stored separately in `calendar-settings.json`. Alert deduplication IDs and expiry instants use `calendar-alert-receipts.json`. Both live in the controller's `dataDirectory`: an explicit initializer URL, then `OPENCOVE_DATA_DIR`, then Application Support/OpenCove. They use the existing atomic private-file persistence. Existing timer, tray, notification settings, and notification token files are unchanged. Alert receipts contain opaque source/event IDs and times, but no titles, locations, notes, or meeting URLs.

## Live activity and alerts

- `nextUpcomingEvent`: earliest future timed event within the seven-day feed.
- `currentEvent`: earliest-starting timed event that has started and has not ended.
- `startingSoonEvent`: next timed event within the configured lead window.
- `eventActivity`: current event first, otherwise starting-soon event; includes `.current` or `.startingSoon` and `remainingSeconds`. For a current event this counts down to its end; otherwise it counts down to its start.

All-day events remain in the calendar UI and upcoming feed, but do not become meeting countdowns or start/pre-event alerts. With overlaps, current activity takes priority over a later upcoming event. The notch uses this activity only while calendar presentation is enabled.

The independent default lead is 15 minutes. While the controller is started and calendar alerts are enabled, a real timed event can emit one pre-event HUD and one start HUD through `onHUD` (`.notification`, `origin: "calendar"`, with a calendar symbol). No system notification permission is requested. These HUDs do not enter the existing notification history or schedule native notifications. The store gates delivery through the calendar origin and its feature preference. The existing `enqueueNotification` also sets the calendar origin when its source is `Calendar`.

Pre-event alerts fire when a future event enters the chosen window, including the first authorized refresh inside that window. Start alerts fire at the start crossing or within a 60-second catch-up period. The clock does not replay meetings from hours ago after a long sleep. Receipts prevent duplicates across repeated refreshes, backward clock changes, filter toggles, and app restarts. Moving an event's start instant creates a new occurrence ID and can alert again at its new time. A pending refresh suspends alerts from the old snapshot; removed, declined, canceled, excluded, or permission-revoked events leave the activity after refresh. Receipts expire two days after the occurrence end, so removing and restoring the same near-term event does not replay its HUD. Event changes must first arrive through EventKit or the next refresh; the service cannot know about changes that macOS has not delivered yet.

## Calendar app routes

Only an installed URL handler with the expected bundle identifier is used. Missing preferred apps fall back to Apple Calendar. No event-creation route is called.

- `calendar`: use `calshow:<seconds since 2001-01-01>` only when Apple Calendar actually registers it. Otherwise use its registered `ical://` scheme to open Calendar. The `ical://` fallback opens the app; it does not promise date navigation.
- `fantastical`: expected bundle `com.flexibits.fantastical2.mac`; documented `x-fantastical://date/yyyy-MM-dd`, with `x-fantastical3://show?date=yyyy-MM-dd` for versions that register the older handler. [Flexibits integration documentation](https://flexibits.com/fantastical/help/integration), [Flexibits URL handler reference](https://flexibits.com/support/kb/51).
- `notionCalendar`: expected bundle `com.cron.electron`; use its real `cron://` scheme to open the installed calendar app. Notion's documented event-navigation API requires an account email and iCal UID. The existing `CoveEvent` does not supply those reliably, so this route makes no date/event-navigation claim and does not invent them. [Notion Calendar API](https://www.notion.com/help/notion-calendar-connections), [package bundle identifier evidence](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/n/notion-calendar.rb).

Fantastical and Notion Calendar routing needs verification with each installed app version. Calendar opening and meeting joining occur only on an explicit user action. HTTPS/HTTP meeting URLs and the pre-existing meeting app scheme allowlist are preserved.

## Verification and limits

Use the checked-in bundle and CLI workflow in [building](building.md) and [quality](quality.md). `opencovectl state` reports the real EventKit status; selecting the Calendar tab through the API does not grant access. The isolated default smoke run disables calendar reads and does not request permission. It therefore cannot prove populated schedules, source filters, alerts, or third-party app routing.

With existing calendar access and explicit authorization, compare a distant month/day with Calendar. Cover source exclusion/restoration, a six-week month, overlapping/all-day/multi-day events, countdowns, pre-event/start alerts, calendar removal, a moved start, midnight/time-zone changes, and each installed app route. Observe real privacy transitions manually. Keep private event data out of public evidence. Empty or denied access does not establish populated-data behavior.

Time-to-leave is a separate optional [travel service](travel-alerts.md). It needs a consented origin, physical destination, and real route. No duration or departure alert is fabricated.

Apple documents EventKit queries and filtering in [Retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).
