# Calendar

OpenCove reads real macOS EventKit events. It does not create, change, or delete calendars, events, or reminders. It does not read another calendar app's private database. The UI and behavior are independently authored from the public feature brief. The default lead time below is an OpenCove choice, not a claim about Alcove's current settings.

## Store and view integration

The notch uses these native calendar layouts:

```swift
CoveCalendarView(activities: activities, showCalendarList: preferences.showCalendarList,
                 showCalendarEventIndicators: preferences.showCalendarEventIndicators)
CoveCalendarView(activities: activities, showCalendarList: preferences.showCalendarList,
                 showCalendarEventIndicators: preferences.showCalendarEventIndicators, condensed: true)
// Approximately 400 × 165 full; 180–200 × 165 condensed, for Duo.
```

By default, the full view places the selected-day schedule on the left and a month grid on the right. The condensed view keeps the month and opens the full selected-day schedule in a popover. Both use the controller's selection, so a surface switch preserves the selected day. Previous/next month buttons, Today, native buttons and menus, source toggles, refresh, and app-opening actions are available without a gesture. The grid follows the system first weekday and uses 42 civil days. Today has a red ring; selection has a filled light circle. Source colors mark real events. Accessible labels include event counts and source names, so color is not the only signal.

The native **Calendar & meetings → Show selected-day list** control saves the local Boolean `showCalendarList = true` through the existing preference binding. Turning it off hides the full selected-day heading, list and divider, and the Duo list-opening control. The full view keeps its right-hand 168-point month grid and uses the left area only for non-content status. Duo keeps its month grid and shows a separate **Calendar status** control only when access, disabled, source recovery, loading or privacy status needs attention. That control opens only status and the existing status actions. An authorized, loaded view with the list hidden has no list opener or selected-day empty-list message. Both layouts retain the 165-point view height and existing outer panel bounds. Grid markers, date selection, month navigation, Today, refresh, source actions and app opening keep their existing behavior.

The choice does not write the controller's selected date or load a different date. Re-enabling the list uses the current selection, including navigation done while the list was hidden. Changing the choice closes an open Duo list or status popover; each popover binding also requires its matching choice. The status popover closes when no non-content status remains. Actual native dismissal and focus behavior still need parent acceptance. No view identity reset or panel-size change is added.

This is an independent layout choice based on the retained `1.5.0 features[10]` declaration, “Added calendar list toggle”. The exact reference default, hidden geometry and Duo semantics remain **SPEC_UNKNOWN**. The default-on choice preserves OpenCove's prior appearance. This choice does not change Calendar enablement, filters, reader demand, alerts, event activity, routing or widget consent. It adds no reader, status request or permission action. The existing Allow access and recovery actions still require explicit user input.

The native **Calendar & meetings → Show event dots** control saves the separate local Boolean `showCalendarEventIndicators = true`. It stays editable while Calendar activity is off. This is the parent's explicitly selected visual-only OpenCove policy: hide only month-grid dot contents. The fixed indicator row and day-cell bounds stay in place. When on, dots keep the existing unique source-color grouping, sorted order, three-color cap and colors. When off, the row has no dot contents. Day help and accessibility values keep the complete event count; date labels, Today text, selected traits and date styling stay unchanged.

The observed store passes this value explicitly to both full and Duo callers. Its source path applies to the mounted view without a restart, date change, new event result or cache flush. It adds no identity reset, lifecycle callback, refresh, date query, timer, animation or reader demand. The dot choice does not change the selected date/month, `showCalendarList`, list content/opener or list/status popover state. The four list/dot combinations remain independent. Status, recovery, privacy, loading, compact countdowns, alerts, routing and widget consent keep their existing paths. This is a presentation choice, not Calendar enablement or a privacy switch.

Retained `1.7.3 features[2]`, “Added calendar event indicators”, maps to the existing dots; `1.7.5 fixes[5]`, “Fixed event indicators toggle not updating live”, maps to the live saved choice. The research did not promote exact reference semantics. The parent selected its conditional dot-only variant. Exact reference OFF-state count and surface behavior remain **SPEC_UNKNOWN**; this policy does not claim exact reference parity.

The store sets the calendar switch and app preference at startup and after saved preference changes:

```swift
activities.setCalendarConfiguration(
    enabled: preferences.enableCalendar,
    showDeclinedEvents: preferences.showDeclinedCalendarEvents,
    excludeSubscribedCalendars: preferences.excludeSubscribedCalendars
)
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

Canceled events are always omitted. By default, events declined by the current user are also omitted. Enabling **Show declined events** includes otherwise valid events even when an attendee marked as the current user has declined. Another attendee's decline does not hide an event. Other overlapping events remain separate. A recurring occurrence ID includes its calendar, EventKit identifier, and start instant. Source color, source title, location, supported meeting URL, all-day state, and original time-zone identifier come from EventKit. Displayed times use the current system time zone; the row help includes the event's source time zone.

The service refreshes on EventKit changes, app activation, system clock/time-zone changes, wake, and every minute while started. A separate one-second activity clock updates a visible event countdown without querying EventKit. Future events schedule an absolute phase boundary; empty, disabled, or unauthorized calendars have no second ticker. At midnight the selected day follows today only if the user had selected today. Other selections remain selected. Civil-day/month arithmetic handles daylight-saving transitions; it does not assume each day lasts 86,400 seconds.

## Sources and persistent options

`calendarSources` lists available EventKit event calendars, with `id`, `title`, `account`, `colorHex`, and `isExcluded`. EventKit is the source of truth; accounts available only inside another app are not imported.

```swift
activities.setCalendarExcluded(source.id, excluded: true)
activities.setExcludedCalendarIdentifiers(selectedExcludedIDs) // Set<String>
activities.setCalendarPreEventLeadMinutes(15) // 0…1440; 0 disables pre-event alerts
activities.setCalendarAlertsEnabled(true)
```

Filters apply to selected-day schedules, grid markers, the upcoming feed, live activity, alerts, and travel routing. Excluding every source returns no events; an empty source array never becomes an unfiltered EventKit query. A disconnected/deleted calendar disappears after refresh. Its exclusion ID is kept so it stays excluded if the same source returns. Replacing the ID filter with an empty set includes all current sources allowed by the subscribed-calendar choice.

Two global, typed Boolean preferences live in the local `preferences.json` document:

- `showDeclinedCalendarEvents = false`: omit current-user declined events unless enabled.
- `excludeSubscribedCalendars = false`: include subscribed calendars unless excluded by ID. When enabled, omit calendars whose public EventKit `isSubscribed` property is true, before creating either event predicate.

Both defaults preserve the prior filtering behavior. Missing legacy keys and invalid Boolean values recover to false through `CovePreferences.recover`; invalid values use the existing repaired-field notice and backup path. Saves use CoveStore's existing atomic persistence and session-only save-error behavior. Neither key belongs to the iCloud settings allowlist. These flags do not move or replace saved ID exclusions, alert choices, or alert receipts.

`showCalendarList` is also local and remains outside the explicit `CoveSyncedSettings` allowlist. A missing legacy key keeps its true default. Only JSON `true` and `false` are valid; numbers, strings, null, arrays and objects recover to false with the existing repaired-field notice. Whole-document damage uses the existing recovery defaults, with Calendar, media and private integrations off. The existing store preserves damaged settings in a private recovery backup before a successful replacement. If saving fails, the layout choice applies for the session and Settings shows the save error; the previous saved choice can return after restart. No new persistence or recovery mechanism is added.

`showCalendarEventIndicators` follows that same ordinary local persistence path and stays outside both consent fields and the cloud allowlist. A missing key keeps true; malformed numbers, strings, null, arrays or objects recover to false under the existing strict Boolean pass, repaired-field notice and exact private backup policy. Backup failure must still prevent replacement of the damaged file. Whole-document recovery keeps its existing reader-off defaults. A failed save applies the dot choice for the session, shows the existing store error, and can restore the older saved choice after restart. Only the Boolean is saved. Generic saves still run existing reconciliation; unchanged Calendar demand and filters add no Calendar refresh.

The native **Show declined events** and **Exclude subscribed calendars** controls use those global preferences. Source toggles still represent manual ID exclusions; a checked subscribed source remains omitted while **Exclude subscribed calendars** is enabled. Turning that option off restores only sources not manually excluded. EventKit's public [isSubscribed property](https://developer.apple.com/documentation/eventkit/ekcalendar/issubscribed) identifies subscriptions. The public [type documentation](https://developer.apple.com/documentation/eventkit/ekcalendar/type) also states that a CalDAV subscription has type `.calDAV` with `isSubscribed == true`, so testing only `.subscription` would miss that case. The installed SDK's `EKCalendar.h` declares the read-only `subscribed` property with getter `isSubscribed`.

CoveStore applies enablement and both flags together through `setCalendarConfiguration`. Each worker request captures immutable flag values, ID exclusions, and date ranges. A flag change clears the old event/grid/activity/routing snapshot, cancels queued work, and advances the existing read revision through `refreshCalendar`. A prior generation cannot publish after the change. Refresh still requires enabled Calendar, valid saved Calendar source settings, and existing full access; changing a flag never repairs damaged source settings or requests permission. Filtering adds no extra source enumeration or event query within a refresh. The existing 42-day grid/seven-day feed bounds, ordering, occurrence IDs, alert receipts, privacy redaction, and Duo state ownership remain in place.

Manual ID exclusions, alert enablement, and alert lead time are stored separately in `calendar-settings.json`. Alert deduplication IDs and expiry instants use `calendar-alert-receipts.json`. Both live in the controller's `dataDirectory`: an explicit initializer URL, then `OPENCOVE_DATA_DIR`, then Application Support/OpenCove. They use the existing atomic private-file persistence. Existing timer, tray, notification settings, and notification token files are unchanged. Alert receipts contain opaque source/event IDs and times, but no titles, locations, notes, or meeting URLs.

## Live activity and alerts

- `nextUpcomingEvent`: earliest future timed event within the seven-day feed.
- `currentEvent`: earliest-starting timed event that has started and has not ended.
- `startingSoonEvent`: next timed event within the configured lead window.
- `eventActivity`: current event first, otherwise starting-soon event; includes `.current` or `.startingSoon` and `remainingSeconds`. For a current event this counts down to its end; otherwise it counts down to its start.

All-day events remain in the calendar UI and upcoming feed, but do not become meeting countdowns or start/pre-event alerts. With overlaps, current activity takes priority over a later upcoming event. The notch uses this activity only while calendar presentation is enabled.

The independent default lead is 15 minutes. While the controller is started and calendar alerts are enabled, a real timed event can emit one pre-event HUD and one start HUD through `onHUD` (`.notification`, `origin: "calendar"`, with a calendar symbol). No system notification permission is requested. These HUDs do not enter the existing notification history or schedule native notifications. The store gates delivery through the calendar origin and its feature preference. The existing `enqueueNotification` also sets the calendar origin when its source is `Calendar`.

Pre-event alerts fire when a future event enters the chosen window, including the first authorized refresh inside that window. Start alerts fire at the start crossing or within a 60-second catch-up period. The clock does not replay meetings from hours ago after a long sleep. Receipts prevent duplicates across repeated refreshes, backward clock changes, filter toggles, and app restarts. Moving an event's start instant creates a new occurrence ID and can alert again at its new time. A pending refresh suspends alerts from the old snapshot; removed, canceled, excluded, permission-revoked, or current-user declined events hidden by the saved choice leave the activity after refresh. Receipts expire two days after the occurrence end, so removing and restoring the same near-term event does not replay its HUD. Event changes must first arrive through EventKit or the next refresh; the service cannot know about changes that macOS has not delivered yet.

## Calendar app routes

Only an installed URL handler with the expected bundle identifier is used. Missing preferred apps fall back to Apple Calendar. No event-creation route is called.

- `calendar`: use `calshow:<seconds since 2001-01-01>` only when Apple Calendar actually registers it. Otherwise use its registered `ical://` scheme to open Calendar. The `ical://` fallback opens the app; it does not promise date navigation.
- `fantastical`: expected bundle `com.flexibits.fantastical2.mac`; documented `x-fantastical://date/yyyy-MM-dd`, with `x-fantastical3://show?date=yyyy-MM-dd` for versions that register the older handler. [Flexibits integration documentation](https://flexibits.com/fantastical/help/integration), [Flexibits URL handler reference](https://flexibits.com/support/kb/51).
- `notionCalendar`: expected bundle `com.cron.electron`; use its real `cron://` scheme to open the installed calendar app. Notion's documented event-navigation API requires an account email and iCal UID. The existing `CoveEvent` does not supply those reliably, so this route makes no date/event-navigation claim and does not invent them. [Notion Calendar API](https://www.notion.com/help/notion-calendar-connections), [package bundle identifier evidence](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/n/notion-calendar.rb).

Fantastical and Notion Calendar routing needs verification with each installed app version. Calendar opening and meeting joining occur only on an explicit user action. HTTPS/HTTP meeting URLs and the pre-existing meeting app scheme allowlist are preserved.

## Verification and limits

Use the checked-in bundle and CLI workflow in [building](building.md) and [quality](quality.md). `opencovectl state` reports the real EventKit status; selecting the Calendar tab through the API does not grant access. The isolated default smoke run disables calendar reads and does not request permission. It therefore cannot prove populated schedules, source filters, alerts, or third-party app routing.

With existing calendar access and explicit authorization, compare a distant month/day with Calendar. Cover source exclusion/restoration, a six-week month, overlapping/all-day/multi-day events, countdowns, pre-event/start alerts, calendar removal, a moved start, midnight/time-zone changes, and each installed app route. Observe real privacy transitions manually. Keep private event data out of public evidence. Empty or denied access does not establish populated-data behavior.

The 2026-10-23 filter preparation is source only. Swift parsing and diff inspection cannot prove EventKit filtering, Boolean persistence/restart behavior, or runtime gate behavior. The retained Calendar/Duo handoff reports `.notDetermined` with no existing `.fullAccess`; this preparation does not recheck permission or execute EventKit. No real positive acceptance is claimed.

The 2026-10-24 list-choice preparation is also source only. Only Swift parsing and source/diff checks are authorized for this slice. No build, runtime, test, browser, native input, status probe or EventKit call was run. Parent acceptance must use the real settings caller for strict Boolean rejection, on/off persistence and restart, save failure, malformed-file repair and backup, and the disabled Calendar native form/list with no grant. Keep Calendar activity and independent Calendar widget reading off during that validation. Do not request access or fabricate event data. An already approved no-grant context is required for any later enabled-grid acceptance; this slice does not authorize it. Populated EventKit lists, authorized-empty/loading transitions, full/Duo native presentation, popover dismissal, keyboard/AX input and exact reference appearance remain **UNVERIFIED**. The media prerequisite remains **C-PID FAILED**; cloud **M1 remains DEFERRED**. A saved Boolean or source check closes none of those gates.

A later owner can verify local Boolean saves, legacy/invalid-false recovery, save failures, disabled-empty state, damaged-source recovery, and rapid flag changes through the real app under the existing authorization limits. Positive declined-event proof requires an otherwise valid real event whose current-user attendee has declined, plus the opposite flag state and unchanged handling of canceled events and other attendees. Positive subscribed-source proof requires an actual authorized subscribed calendar, including the interaction with manual ID exclusions; a mock or synthetic EventKit record cannot establish it. Run future positive checks through the real app with explicitly authorized, owned fixture data, without querying existing events. If that isolation cannot be established, keep the positive gate open. This preparation adds no fixtures, calendar selection contract, or source allowlist.

The 2026-10-24 event-dot implementation from parent `65dc8651a83595740a0e40792b5f74f4ea7ae017` permits only Swift parse, diff review and static hashes. No build, typecheck, runtime, helper, fixture, probe, test, mock, browser, native input, EventKit, power/permission query or network ran. The parent must keep Calendar activity and the independent Calendar widget reader OFF in no-data validation. Real preference true/false save/readback, restart, missing-key true, malformed-value false repair, whole-document recovery, exact backup and real save-failure/recovery checks can accept only the preference subset. Native control reachability/input needs separate proof. Preference/API proof does not accept live populated dots, and disabled/unloaded output does not prove an authorized empty calendar. No synthetic events, grant or permission workaround may fill that gap.

Full/Duo, retained populated selection/month, live ON/OFF/ON dots, grouping/cap, count/help/accessibility, all four list/dot combinations, popovers and native positives remain **UNVERIFIED** until separately authorized real-data acceptance. Exact reference OFF-state count/surface behavior remains **SPEC_UNKNOWN**. **C-PID FAILED; M1 USER-DEFERRED; Stage4 HOLD; Focus execution HOLD; full parity INCOMPLETE** remain unchanged. See the bounded parent plan in [quality](quality.md#local-calendar-event-dot-policy).

Time-to-leave is a separate optional [travel service](travel-alerts.md). It needs a consented origin, physical destination, and real route. No duration or departure alert is fabricated.

Apple documents EventKit queries and filtering in [Retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).
