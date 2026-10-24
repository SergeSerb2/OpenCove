# Calendar grid readability

## Scope and status

Source-only handoff from base `75fbec47915d0c32dc3d8f5985fdee5d762615db`.
Rendered contrast, clipping, and native control behavior remain pending with the
parent. This work ran no build, app, capture, permission request, Calendar read,
or EventKit operation.

Static validation passed: `/usr/bin/swiftc -frontend -parse
Sources/OpenCove/Views/CalendarView.swift` and `git diff --check`. Parsing checks
syntax only; it does not establish successful type checking or a build.

`Sources/OpenCove/Views/CalendarView.swift` now uses the existing
`CoveNotchStyle.secondary` for two types of text:

- The seven 8-point weekday headings, previously white at 0.45 opacity.
- The unselected, non-today 9-point dates outside the displayed month, previously
  white at 0.30 opacity. These dates are active buttons that select a day.

The shared secondary tone is currently white at 0.52 opacity, defined in
`Sources/OpenCove/Views/NotchComponents.swift`. This change uses that value locally.
It preserves the brighter 0.90 in-month dates, selected and today styling, fonts,
frames, layout, hit areas, date actions, accessible labels, and all other text.
It adds no state, data source, control, timer, or animation. It makes no claim
about Alcove's colors or exact visual parity.

## Primary guidance and source assessment

Apple's [Accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility#Color-and-effects)
calls for sufficient contrast between text and its background. Apple's
[Sufficient Contrast evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria/)
recommend checking actual foreground and background contrast, including
translucency, and give 4.5:1 as the usual text minimum. They cover both appearances
and checks with Increase Contrast, with Reduce Transparency off and on.
Apple's [Color guidance](https://developer.apple.com/design/human-interface-guidelines/color#Inclusive-color)
also warns that insufficient contrast can make information hard to perceive.

The 8- and 9-point labels need the small-text check. The out-of-month buttons
remain selectable, so their subdued tone must still be readable. Weekday headings
also convey information even though they are hidden from accessibility because
each date button supplies its complete date.

For source triage only, assume encoded-sRGB white blended over opaque black.
The nominal ratios are 4.41:1 at 0.45, 2.46:1 at 0.30, and 5.66:1 at 0.52.
These assumptions justify replacing the two lower tones with the existing
secondary tone. They do not describe captured pixels, text rasterization, the
actual backdrop, or accessibility-setting behavior. No rendered pass is claimed.

## Parent-owned mounted acceptance

Run the same cases against a parent-owned baseline bundle from the base commit
and a bundle with this change. Keep data, selected date, locale, time zone,
appearance, panel position, display scale, and capture method equal for each pair.
Use the real app and its existing authenticated control client. Keep evidence in
a private directory. Store only the state fields needed below; do not dump the
client descriptor, tokens, environment, or full app snapshot.

### Keep the empty recovery state

1. Use a fresh private data directory for each bundle. Follow the disabled
   integrations in `SAFE` in `script/runtime_e2e.py`, with Calendar enabled,
   `expandedLayout: "calendar"`, `hideWhenIdle: false`, `expandOnHover: false`,
   `hideInFullscreen: false`, and `reduceMotion: true`. Keep media and all its
   integrations disabled. Do not run the existing activities flow just for these
   captures; that flow also starts a timer and adds a tray file.
2. Before launch, write exactly
   `{"excludedCalendarIdentifiers":"damaged"}` to the isolated
   `calendar-settings.json`. This uses the real damaged-exclusion recovery path.
   Preserve those bytes throughout the run. Do not reset sources, request access,
   call `calendar.exclude`, or open a calendar app or event.
3. Require `calendarAuthorization == "Saved calendar settings need review"`,
   `events == []`, and absent or null `calendarActivity` before and after every
   date or layout change. The full schedule should show the real recovery notice. This
   case establishes an empty grid under paused queries; populated schedules and
   the authorized "No events" state need separate evidence.

The source gates are `refreshCalendar()` and `loadSelectedDate(_:)` in
`Sources/OpenCove/Services/ActivityController.swift`. The recovery notice is
`CoveCalendarSourceRecovery` in `Sources/OpenCove/Views/SettingsView.swift`.
If the recovery gate is absent, stop this case before any calendar operation.

### Establish the mounted grid

1. Through the existing control client, call `calendar.selectDate` with
   `date: "2026-10-15T12:00:00-07:00"`, then `selectTab` with `tab: "calendar"`
   and `expand`. Confirm the local selected day and October 2026 month heading.
   Use the system's existing first weekday; do not change the host locale or
   clock. A 42-day October grid contains 31 in-month dates and 11 spillover dates.
   Record the calendar identifier. This date/count assumes a Gregorian calendar;
   if the existing calendar differs, document an actual 31-day month in that
   calendar rather than changing the host's calendar setting.
2. Require `expanded == true`, `visibleTab == "calendar"`, and
   `expandedDuo == false`. Record the visible native window dimensions and the
   settled selected date immediately before and after each capture.
3. Obtain an unscaled PNG from `/render?surface=live-notch` for the mounted
   AppKit view. `/render?surface=notch` constructs a separate view and cannot
   establish this mounted result. If the parent's permitted environment supports
   `/render?surface=live-notch-compositor`, record it separately for compositor
   proof. Keep the method in each result; AppKit caching does not prove
   WindowServer composition or a desktop backdrop. If capture is unavailable,
   record the exact failure and leave the gate pending.
4. Repeat with `expandedLayout: "duo"` while keeping media disabled. Require
   `expandedDuo == true` and a visibly mounted condensed Calendar before accepting
   its PNG. Return to Calendar, collapse, and expand once; repeat the captures to
   check the same text after remount. Recheck the empty recovery gate each time.

### Measure contrast from the saved pixels

1. Decode the original PNG with its embedded color profile and convert it to
   sRGB for measurement. Record image dimensions, profile, native scale, and the
   grid crop rectangle in physical pixels. Do not resize, sharpen, recolor, or
   flatten the evidence onto an assumed black background.
   If the sample pixels retain transparency over an unresolved backdrop, leave
   final composited contrast pending until the parent can obtain that backdrop.
2. Locate all seven weekday labels and all 11 unselected spillover date labels
   in each October capture. Save each label's crop and coordinates. Identify
   interior stroke samples and the adjacent rendered background for each label;
   keep circle fills, event markers, neighboring glyphs, and antialiased edge
   pixels out of the background sample. Store the actual foreground/background
   RGB samples and sample coordinates so the result can be checked again.
3. Convert each sRGB channel `c` from 0...1 to linear light using `c / 12.92` for
   `c <= 0.04045`, otherwise `((c + 0.055) / 1.055)^2.4`. Compute
   `L = 0.2126 R + 0.7152 G + 0.0722 B` and
   `(max(Ltext, Lbackground) + 0.05) / (min(Ltext, Lbackground) + 0.05)`.
   Use the lowest ratio from the reliable stroke/background sample pairs for
   each label; report every label and the minimum across labels. Require at
   least 4.5:1 for the affected text. Compare the same labels before and after.
4. At these small font sizes a glyph may have no reliable interior sample at a
   given scale. Record that sampling limit and leave that measurement unresolved.
   Do not reconstruct a foreground from the source opacity, count a single
   bright edge pixel as a full label pass, or substitute a nominal ratio.
5. Measure unselected in-month text, selected black text on its light circle,
   and today's white text on red as unchanged controls. Report any pre-existing
   failure separately; this change makes no contrast claim for those states.

### Check clipping, hierarchy, and unchanged date behavior

1. In full Calendar, confirm the grid is still 168 points wide with seven equal
   columns, an 11-point weekday row, and six 18-point date rows. In Duo, use its
   actual mounted width, seven equal columns, the same 11-point weekday row,
   and six 17-point date rows. The Calendar content height remains 165 points.
   Record actual frame/crop dimensions rather than treating these source values
   as measured geometry.
2. Inspect all seven headings and all 42 date numbers at original scale and at
   nearest-neighbor enlargement. Record glyph bounding boxes, row baselines, and
   clearances from their cell and grid clip edges. Require complete glyphs,
   including two-digit spillover dates, with at least one physical pixel of
   clearance from clip edges. Check both outer columns and the complete sixth
   row. Require no overlap, truncation, lost stroke, or baseline/frame movement
   between the baseline and candidate. Capture panel geometry before and after
   to catch a crop that hid part of the grid.
3. Confirm the brighter in-month hierarchy, month title, selected circle, and
   today circle are still distinct in the pixels. An empty grid has no event
   markers; their appearance remains outside this acceptance case.
4. Select a visible spillover date through `calendar.selectDate`, using its real
   ISO date in the existing time zone. Require the selected date and month heading
   to advance to that date's month, then return to October 15 and compare the
   remounted grid. Preserve the damaged file and empty recovery state. This
   exercises date selection through the real API; native button activation and
   hit areas remain parent-owned interface gates.
5. Repeat contrast and clipping checks on available native 1x and 2x displays,
   and in the parent's permitted appearance/accessibility configurations:
   default, Increase Contrast with Reduce Transparency off, and both on. Include
   Bold Text where available. Keep unavailable scales/settings explicitly
   pending; do not resize a PNG to simulate another scale or change display
   hardware. Keep host settings unchanged unless the parent's scope allows it.

For each case record the two commit/bundle identities, isolated recovery status,
selected date, locale/time zone, layout, measured geometry, scale, appearance and
accessibility settings, capture method, private PNG/crop paths, per-label RGB and
contrast results, clipping observations, and pass/fail/unavailable status. Empty
mounted acceptance cannot establish event data, permissions, Calendar app routes,
frame pacing, or overall feature parity.
