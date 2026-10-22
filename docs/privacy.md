# Privacy, permissions, and network use

OpenCove runs as a native app on your Mac. It has no app-operated account, analytics service, crash upload, update checker, or remote control backend. It is not sandboxed. OS and third-party services have their own policies. Private integrations are enabled by default and can be turned off in Settings; optional protected features still need the relevant permission or explicit feature choice.

## Permissions

Permissions are requested from explicit app controls, not an automatic first-launch sequence. A previously granted permission can be used when its feature is enabled.

- **Calendar:** EventKit full calendar access supplies events, calendar names, locations, and meeting links. OpenCove reads events; it does not create or edit them.
- **Automation:** Optional Apple Events to Music or Spotify read metadata and perform supported playback actions. The system MediaRemote adapter is a separate path. It runs independently authored JavaScript in an app-owned `/usr/bin/osascript` child without Apple Events or Automation permission. The retained Swift diagnostic adapter uses `/usr/bin/swift` and needs developer tools.
- **Bluetooth:** Allows available connection and accessory information. CoreAudio can expose the active audio route independently. Some battery details depend on OS driver data and private integrations.
- **Focus:** Reads shared Focus status. Focus mode names are not promised.
- **Accessibility:** Optional hardware-key interception can replace supported volume/brightness HUDs. Optional notification mirroring reads new readable Notification Center banner text. Banner titles and bodies can contain private messages or codes. Mirroring requires consent and a confirmed active, unlocked session; stopping or locking clears mirrored presentation data.
- **Location:** A one-time device location can be requested for weather or travel. Manual coordinates avoid a location permission request. Saving an origin/location is consent to use that location for its selected feature; it can be reused on later launches while enabled.
- **System audio / screen recording:** Optional ScreenCaptureKit capture computes audio levels in memory. macOS may show its screen/audio capture permission UI. The app does not request microphone access, save screen images, or record/upload audio. The stream uses a minimal video configuration, but registers only an audio output and receives no screen pixels.
- **Notifications:** A separate opt-in can send OpenCove alerts through macOS Notification Center. Timer alerts can be scheduled to fire after the app exits. This is separate from reading banners with Accessibility.
- **Login item:** The user can choose to register OpenCove with ServiceManagement. No privileged daemon or root helper is installed.

macOS controls permission storage and revocation in System Settings. Disabling an app feature stops its work; it does not automatically revoke an OS grant or erase every saved preference. Secure lock-screen widget visibility and private-content behavior still require manual validation on each supported OS.

## Local data

Release data defaults to `~/Library/Application Support/OpenCove`. Development Finder launches use `OpenCove Development`; the wrapper uses `.local/runtime`. `OPENCOVE_DATA_DIR` overrides the directory. The data is ordinary local files, not an encrypted vault.

The app requires an owned private data directory, created with mode `0700`. It rejects unsafe existing directories without silently changing their permissions. Startup resolves and pins the data path before opening the instance lock; services use that same target for the session. Instance locks and control descriptors use mode `0600`. Use a new private temporary directory for the [integration workflow](quality.md).

Saved data can include preferences, calendar filters and alert receipts, a timer deadline, file paths/bookmarks, weather coordinates and consent, travel origin and alert-receipt hashes, and optional notification-URL API credentials. Tray removal removes the reference, not the original file. Calendar event snapshots, media state/artwork, mirrored banner text, and audio levels are held in memory rather than intentionally written as content archives. OS notifications or logs can persist separately under macOS policy. Do not attach raw app state, preferences, or data folders to public issues.

Disable the related feature and remove its saved origin/location in Settings when available. To remove all local app data, quit OpenCove and remove its own data folder. This also removes saved timers and file references. It does not delete source files, revoke OS permissions, or cancel all OS-managed records. Turn off native notifications and login-item registration in the app before uninstalling if those options were enabled.

## Network and external services

- **Weather:** When enabled with a selected location, OpenCove sends latitude and longitude to `api.open-meteo.com` for current conditions and hourly/daily forecasts in one request. It can refresh about every 15 minutes. The provider also sees normal network metadata, including your IP address. Weather data is credited to [Open-Meteo](https://open-meteo.com/) under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The [free-service terms](https://open-meteo.com/en/terms) permit non-commercial use and set request limits; they apply separately from the data license and the app's MIT license. Commercial use needs a separately arranged provider service; OpenCove currently uses the free endpoint. No weather dataset is bundled.
- **Travel:** After travel opt-in and origin selection, MapKit sends the necessary event destination query and origin region to Apple Maps. Directions use origin/destination coordinates and the event's arrival time. The app does not send the event title, notes, body, or meeting URL as a place query. Requests can recur when an eligible route becomes stale. This is not an offline feature.
- **Artwork:** With the Spotify Automation fallback, artwork URLs on Spotify's `scdn.co` image CDN can be downloaded over HTTPS. The CDN sees the image request and normal connection metadata. Other metadata/artwork can come from the local media system or the chosen app.
- **Links and sharing:** Opening a meeting, media, calendar, Maps, or weather link hands it to its registered app or browser. File sharing uses the selected macOS share service. Those apps/services can contact their own servers.
- **Development and distribution:** SwiftPM has no third-party package to download. Git clone and CI use GitHub. Normal local packaging does not upload. Only an explicit `--notarize` command submits a signed app to Apple's notary service with the maintainer's keychain profile.

## Local control interfaces

An explicit `--control-port` launch enables an HTTP listener bound to `127.0.0.1`. It requires an ephemeral token and checks the host/origin. `control.json` holds the token in the app data directory with owner-only file permissions. The API can expose media, event, file, and device state and perform real app/settings actions. A token-bearing URL grants that access to its holder; do not share it. Normal launches do not start the listener.

A separate optional notification URL API uses the app's URL scheme and a saved token. Its token can appear in a URL and in the sending application's history or logs. It is off until enabled. Revoke it from the app if exposed. Neither interface is an internet service.
