# Time-to-leave alerts

OpenCove estimates travel time for the next supplied calendar event with a physical location within 24 hours. This is independently authored MIT code. It uses public Core Location and MapKit APIs. It uses no phone or watch service and needs no API key.

## User consent

Alerts start off. Enable **Time-to-leave alerts**, choose Driving or Walking, and set an arrival buffer from 0 to 120 minutes. Then enter origin coordinates or select **Use Device Location Once**. Enabling alone does not request location or contact Apple Maps. Opening settings never requests location. A saved explicit enablement and saved origin allow route requests after the next app launch.

The device-location button is the only path that creates a location manager or requests location permission. It requests one recent fix, then stops and releases the manager. It times out after 30 seconds. Denied or restricted access shows an error and permits manual coordinates. The installed bundle needs a nonempty `NSLocationUsageDescription` or `NSLocationWhenInUseUsageDescription` that explains travel origins. The shared bundle description must cover weather and travel.

Both origin methods save a fixed origin. OpenCove does not track movement or update the origin in the background. Use the button again when the origin changes. **Forget Origin** cancels pending work and removes the saved coordinates. Disabling alerts cancels all route, location, and deadline work but retains the origin for the next explicit enablement.

## Routing and privacy

The activity service supplies `[CoveEvent]` through `updateEvents(_:)`. TravelController does not request EventKit access or read event notes or bodies. It ignores all-day, started, and out-of-window events. It removes links and rejects online-meeting labels and join instructions from location text. An online-only event is not a travel destination. A hybrid event can use a separate physical-location line. Events with only a Maps URL need a plain address or place name in their location field.

Only the reduced destination search text goes into `MKLocalSearch.Request.naturalLanguageQuery`. Search has an origin-region bias; directions use the explicit origin coordinate and the first valid MapKit search result. `MKDirections.calculate()` supplies a real route ETA for the selected mode and event arrival time. There is no straight-line estimate or made-up fallback. The resolved destination appears in settings so the user can check ambiguous place names. A precise street address gives better results than a room name.

Apple Maps receives the origin, destination search text or resolved destination, travel mode, and arrival time needed for these requests. Event titles stay in local state and the local HUD. No event notes, bodies, meeting links, URL logs, or raw provider errors are sent or logged by this service. Route data and event titles are not persisted in travel settings. See Apple's [MKDirections documentation](https://developer.apple.com/documentation/mapkit/mkdirections) and [one-shot location documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation()).

Settings live in `travel-settings.json` under `OPENCOVE_DATA_DIR`, or the app's Application Support/OpenCove directory. The file contains enablement, mode, buffer, consented origin coordinates/source/time, last route-attempt time, and up to 128 hashed occurrence identifiers with expiry times for alert deduplication. It never contains calendar titles, destinations, notes, or meeting URLs. The service creates temporary files with mode `0600`, writes and synchronizes them, then atomically replaces the settings file. It enforces mode `0600` on load and rejects symbolic links. A persistence error is visible; choices and deduplication can then last only for that session.

## Refreshes and alerts

There is at most one route attempt per 15 minutes, including failed searches, event/origin/mode changes, and stop/start or app restarts. Each attempt performs at most one local search and one directions calculation. A 30-second timeout and cancellation guard prevent late results from replacing a newer selection. A 30-second local timer checks calendar selection, freshness, and the retry gate; it does not bypass that gate. No event or no origin causes no provider work.

The leave deadline is `event.start − travelSeconds − bufferMinutes × 60`. A separate timer checks the deadline, including after sleep/wake. The HUD callback fires only at or after that deadline, before the event starts, and only after a successful ETA less than 15 minutes old. It never announces a synthetic countdown or success just because alerts were enabled. If the first valid ETA arrives after the leave deadline, the HUD fires then if the event has not started.

The occurrence identifier combines event ID and start time. Persisting it before the HUD callback prevents another alert after ETA/buffer changes, stop/start, or restart. Rescheduling the event to a different start creates a new occurrence. No routable result, provider failure, or an expired route sets `available = false` and removes `leaveAt`; an old ETA cannot trigger an alert. A fresh successful result restores availability. Alerts require the app and its owner-provided HUD callback to be active; this service does not schedule system notifications or background execution.

## Store integration

Own one `TravelController` for the app. Connect `onHUD` to the existing HUD presentation path. Call `start()` and `stop()` with the app lifecycle. Feed the current events and all calendar updates, including an empty array after permission loss or calendar deselection, into `updateEvents(_:)`. Embed `TravelSettingsView(controller:)` under Calendar. The view observes the supplied controller and never starts it.

The controller publishes `state: TravelState`, `lastError`, and `status`. TravelState is Codable and contains `enabled`, `available`, `eventTitle`, `destination`, `travelSeconds`, `leaveAt`, `source`, and `updatedAt`. The UI must check both `available` and `!isStale` before presenting an actionable ETA. `mode`, `bufferMinutes`, origin accessors, `isCalculating`, and `isRequestingLocation` support settings. The service also provides `clearOrigin()` for explicit removal.

## Verification boundary

The default [integration workflow](quality.md) disables provider work and requests no permissions. A successful compile does not establish a Maps result. With explicit consent and existing access, verify: disabled/no-origin causes no prompt or request; denied location permits a manual origin; an online-only event produces no route; a physical event yields the matching destination and ETA; the HUD fires once at its deadline; event removal, expired routes, provider failure, and stop cancel pending alerts; a restart preserves private settings and occurrence deduplication. Perform those flows through an approved real caller without desktop input automation.
