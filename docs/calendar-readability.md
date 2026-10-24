# Calendar grid readability

## Scope and status

The implementation started as a source-only handoff from base
`75fbec47915d0c32dc3d8f5985fdee5d762615db`. Fresh isolated acceptance now covers
the optimized development build, real mounted empty-recovery Calendar and Duo,
authenticated date navigation, remounts, saved layout, and native/compositor PNGs.
Peak contrast increased for every affected label. Reliable interior contrast at
the available 1× scale and the other gates listed below remain pending.

The original static validation passed: `/usr/bin/swiftc -frontend -parse
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

## Owned acceptance recorded on 2026-10-23

The isolated acceptance worktree cherry-picked
`a7bda2350691122692ff8373db38ee58e64d27d6` as
`4b0f0a7`. Its safe Duo procedure and public-document allowlist were corrected
in `de50f1b58dad03c731fab7edbe21cb628a21276b`. The tested optimized arm64
development bundle records that exact commit and source tree
`db1479e5fbba993d1147a165252e6033ca2940f1a512d4dab27ba9b83925443f`.
Its Calendar source SHA-256 is
`6e187847522b688b5e5d69402da0ce6811d9623cde572261edf67bf078530f70`.
Source manifests matched before and after the 42.343-second packaging build.
The later acceptance report is a documentation-only change; it was not part of
that bundle.

The baseline was an owned private copy of the existing development bundle from
`75fbec47915d0c32dc3d8f5985fdee5d762615db`, source tree
`9e299bb0f85b9a2ed588d7ccbf166d4eff2b055a5e23022ffad2e9e215234016`.
Its Calendar source SHA-256 is
`0776b0af7909c802f1dd949a83d932676d377e53413bcae980cf31e6aed0bc1e`.
Only the owned copy was launched. The parent's app and checkout were not built
or edited.

Both bundles used the inspected `Runtime` and `SAFE` from
`script/runtime_e2e.py`, plus the authenticated `ControlClient` from
`script/verify_control.py`. Their child environments were
rebuilt from the permitted minimal key set. No ambient token was forwarded.
The real damaged settings file was written before launch and kept byte-for-byte
equal to `{"excludedCalendarIdentifiers":"damaged"}`. Its SHA-256 is recorded
with each flow. Recovery authorization, zero events, and no Calendar activity
were checked before and after commands and captures. Media stayed unavailable,
with private APIs and AppleScript off. No player fixture was needed.

Authenticated API checks covered October 15, both spillover months, September 27,
November 7, return to October, Calendar/Duo tab changes, collapse/expand remounts,
and process restart. The visible native panels were 440 × 235 pixels for full
Calendar and 440 × 240 for Duo, at native 1× scale. Full mode required the Calendar
tab and `expandedDuo == false`; Duo required the media tab and
`expandedDuo == true`. The selected civil day survived view remounts. The saved
Duo preference survived process restart. Selected day is controller state and
starts at today in a new process; the checks selected October 15 again after
restart. This change adds no persisted date selection.

An owned incognito T3 browser tab exercised the real development controls,
including Calendar selection, spillover navigation, explicit Duo, collapse, and
expand. Authenticated requests to `live-notch` returned the mounted panel.
The page's ordinary `notch` preview was not used as mounted evidence.
One browser snapshot timed out; the control clicks, authenticated state checks,
and mounted capture requests succeeded. Browser credentials and authenticated
state were cleared, and the owned tab was closed.

### Actual pixel results and sampling limit

Both full Calendar and Duo were captured through `live-notch` and through
`live-notch-compositor`. The first caches the mounted AppKit view; the second
captures the owned window through ScreenCaptureKit. Compositor capture succeeded
without a permission request. Neither establishes frame cadence.

The PNGs identify `Rec. ITU-R BT.2020-1; sRGB Gamma`. Measurements use the
PNG's native CGImage ICC color space and actual unpremultiplied pixel bytes,
converted with `CGColor.converted(to: sRGB, intent: relativeColorimetric)`.
All sampled label cells are opaque. No background was assumed or flattened.

A diagnostic decoder used `NSBitmapImageRep.colorAt`, which returned Generic
RGB despite the embedded profile. Its inflated results are retained only as
superseded evidence. They are excluded from these results. PNG hashes can also
differ because of generated ICC metadata while their decoded, converted pixels
remain identical; both hashes and converted pixel comparisons are retained.

The table gives the strongest observed text pixel against its adjacent rendered
black background. The same values were measured in both layouts and with both
capture methods. These are **peak samples, not full-label contrast passes**.
Each affected label has no 3 × 3 interior plateau at 95% of its own observed
peak. No reliable interior coverage was established at 1×. All 18 affected
labels therefore remain pending for the requested reliable-interior contrast
gate. No foreground was reconstructed from source opacity.

| Label | Baseline peak ratio | Candidate peak ratio |
| --- | ---: | ---: |
| Sunday heading | 4.3654 | 5.6148 |
| Monday heading | 4.4288 | 5.6910 |
| Tuesday heading | 4.4288 | 5.6910 |
| Wednesday heading | 4.4288 | 5.6910 |
| Thursday heading | 4.4288 | 5.6910 |
| Friday heading | 4.1185 | 5.2446 |
| Saturday heading | 4.3654 | 5.6148 |
| September 27 | 2.4843 | 5.6910 |
| September 28 | 2.4843 | 5.6910 |
| September 29 | 2.4843 | 5.6910 |
| September 30 | 2.4843 | 5.6910 |
| November 1 | 2.4843 | 5.6910 |
| November 2 | 2.4843 | 5.6910 |
| November 3 | 2.4843 | 5.6910 |
| November 4 | 2.3696 | 5.3172 |
| November 5 | 2.4843 | 5.6910 |
| November 6 | 2.4843 | 5.6910 |
| November 7 | 2.3696 | 5.3172 |

Unchanged control peak samples were 16.8260 for an unselected in-month date,
21.0000 for selected black text on white, and 3.4460 for today's white text on
red. The today sample is below 4.5:1 in both bundles; this is a pre-existing
limitation, not a new regression. These small glyph controls also do not establish
a full-label pass.

### Geometry, clipping, evidence, and remaining gates

All seven headings and 42 dates were inspected in the original PNGs and in
nearest-neighbor 8× crops. Both outer columns, two-digit spillover dates, and the
complete sixth row remained visible. There was no observed clipping, overlap,
truncation, or lost stroke. The brighter in-month text, month title, selected
circle, and today circle stayed distinct.

Exactly 677 pixels changed per panel, all inside the 18 affected label cells.
All 31 in-month cells and every pixel outside the affected cells were unchanged.
All 18 affected glyph patterns had zero best alignment shift when each captured
pattern was normalized by its own observed peak for shape comparison only.
This is not a contrast reconstruction. Some low-intensity antialiased fringe
bounds gained one pixel as the text brightened; no layout shift was observed.

The full grid crop is `(252, 50, 168, 120)`; the Duo crop is
`(234, 51, 186, 114)`, in physical pixels from the PNG's top-left corner.
Date-row pitch is 18 pixels in full mode and 17 in Duo. Affected ink had at least
two pixels of clearance from source-projected cell boundaries. Invisible native
cell frames and the exact 165-point content frame were not directly measured;
source-projected boundaries are explicitly labelled in the evidence. Source
review confirms no font, frame, layout, hit-area, or action changes. Native
button activation and hit testing remain untested within this scope.

Private evidence is under `.local/calendar-readability-acceptance-20261023/`.
`bundle-identities.json` and `frozen-source.json` retain source and binary
hashes. `runtime-observations.json` retains filtered before/after state;
`compositor-observations.json` records paired captures.
`pixel-analysis/*/measurements.json` records every label's original PNG/crop
path, profile, coordinates, sRGB foreground/background values, ratio, bounding
box, and unresolved sampling status. `pixel-analysis/layout-comparison.json`
records pixel isolation and pattern alignment. Runtime ownership and cleanup
records retain the owned paths, PIDs, and available start evidence. Evidence
directories are private; data files are 0600 and executable artifacts stay
owner-executable.

The host used Gregorian Calendar, Sunday first, `en_CA`, and
`America/Vancouver`. Dark appearance was active, Increase Contrast and Reduce
Transparency were off, and the host's Reduce Motion was off; app Reduce Motion
was on. Bold Text was unavailable in the read-only inventory. No host setting
was changed.

Remaining gates are reliable interior contrast, native 2× rendering, changed
appearance/accessibility settings, native button activation/hit testing, and
direct measurement of invisible native cell frames. Populated schedules,
authorized empty schedules, event markers, permissions, Calendar app routes,
and frame pacing are outside this empty recovery case. The observed runtime
flows and brighter samples pass their stated checks; overall readability
acceptance remains pending.

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
   `hideInFullscreen: false`, and `reduceMotion: true`. Set `enableMedia: true`
   for the empty Duo pane, with `enablePrivateAPIs: false` and
   `allowAppleScript: false`. `MediaController.start(privateAPIs:appleScript:)`
   leaves its remote backend absent; `readAdapterFallback` then skips adapter
   startup, and `readScriptFallback` clears state without running scripts. This
   enables the feature without reading or controlling a personal player. No
   fixture player is needed. Do not run the existing activities flow just for these
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
4. Repeat with `expandedLayout: "duo"`, `enableMedia: true`,
   `enablePrivateAPIs: false`, and `allowAppleScript: false`. Select the `media`
   tab explicitly: Duo is attached to that tab, not the Calendar tab. Require
   `visibleTab == "media"`, `expandedDuo == true`, and a visibly mounted
   condensed Calendar before accepting its PNG. Return to Calendar, collapse,
   and expand once; repeat the captures to
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
