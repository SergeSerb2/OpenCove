# Privacy, permissions, and network use

OpenCove runs as a native app on your Mac. It has no app-operated account, analytics service, crash upload, or remote control backend. Configured release builds use Sparkle for updates, as described below. It is not sandboxed. OS and third-party services have their own policies. Private integrations are enabled by default and can be turned off in Settings; optional protected features still need the relevant permission or explicit feature choice.

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

The OFF-by-default `showMediaTotalDuration` choice is ordinary local presentation
data. It changes only the right time label when an admitted media slider has known
duration. It stays outside reader consent and the cloud allowlist; it adds no
media reading, permission, player request, action or independent widget grant.
Settings allows this choice with Media OFF. Missing or invalid values recover to
false through the existing merge. Ordinary save failure keeps the session choice
and existing error; restart uses the actual saved document or existing recovery.
An overall failure status alone does not prove that the local write failed.

If the preferences document cannot be read or recovered as a whole, including
oversized, malformed or non-object JSON, the session starts with all 29 optional
integration, widget, HUD, haptic and reader selections off. Corruption cannot
restore their enabled factory defaults. This fallback does not change new-install
defaults for a missing file, valid saved choices, or individual-field recovery.
Local presentation defaults, including Calendar source colors, list and dots,
remain unchanged. Features can be enabled again through their existing explicit
controls; existing macOS permissions and separate reader-consent rules still apply.
Recovery itself requests no new permission.

Loading damaged preferences does not replace the original file. Before an explicit
save can replace it, recovery copies its exact bytes to a private
`preferences.recovery.<UUID>.json` backup. If that backup fails, the save does not
replace the damaged file. Ordinary session-only save behavior and errors still
apply. Shared startup, session and system-status work can still run with optional
selections off; this policy does not promise zero OS calls. The real startup and
backup-failure checks remain [pending](quality.md#whole-document-preferences-recovery-safety).

Choosing an individual display saves its system display UUID in preferences. Names and geometry remain in memory and appear in the optional authenticated control state. This display information is not sent to a service. Choosing Main or Built-in clears the saved UUID; choosing All retains it for later use.

Disable the related feature and remove its saved origin/location in Settings when available. To remove all local app data, quit OpenCove and remove its own data folder. This also removes saved timers and file references. It does not delete source files, revoke OS permissions, or cancel all OS-managed records. Turn off native notifications and login-item registration in the app before uninstalling if those options were enabled.

## Optional Low Power Mode overlays

**Low Power Mode changes** is off by default. Its separate native Settings choice
is local to this Mac and outside the fixed iCloud allowlist. The central preference
save must succeed before a new grant installs an observer or reads a baseline.
Generic preference edits, reset, cloud updates, unrelated saves and widget consent
cannot add this grant. Missing or malformed consent, repaired documents and damaged
documents leave it off. A valid saved grant can resume on a later launch.

**Battery & charging** is the parent category. Turning either choice off immediately
retires this mode domain and its overlay before saving. Turning the category back
on does not restore mode consent. If revocation cannot be saved, it stays off for
the session; the settings error warns that an older saved grant may return after
restart. This does not change the existing IOPowerSources charge monitor, its
defaults or its battery-widget behavior. Category opt-out does not stop that older
public charge monitor. Battery-widget consent never grants mode reading or alerts.

While admitted in the active, awake session, this feature reads only the public
`ProcessInfo.isLowPowerModeEnabled` Boolean and listens to its default-center
power-state notification. It has no polling, permission request, power-mode setter,
helper, network request or native Notification Center alert. It does not depend on
notification permission or private integrations. Reported false cannot distinguish
off from unknown or unsupported hardware. Charge, charging and AC state do not
determine Low Power Mode. The reported value and comparison baseline stay in memory.

Registration precedes a silent baseline. Only a later observed Boolean difference
can show “Low Power Mode on” or “Low Power Mode off”, without a percentage. These
use the existing battery overlay duration, motion, labels and optional haptics.
Same-value notifications do nothing. Stop, processed session resignation, sleep,
screen sleep, known lock and shutdown retire mode state and its overlay. Return
starts a new silent baseline with no replay. Existing unknown-lock limitations
remain; this is not a secure-session guarantee. Delayed notifications can collapse
intermediate changes. There is no event history or every-transition guarantee.
See the bounded [acceptance plan](quality.md#public-low-power-mode-overlays).

## Optional BetterDisplay feedback

**Show BetterDisplay brightness feedback** is off by default. This explicit native
Settings choice applies only to this Mac and is excluded from iCloud settings.
Generic preferences cannot enable it. A new grant starts reception only after the
central preference save succeeds. Turning it off, or disabling the brightness
category, stops reception and clears the report cache and external HUD immediately,
even if saving fails. The settings error then explains if an old saved choice may
return after restart. Missing/malformed fields and repaired documents do not grant
this reader. Lock-widget consent remains separate.

When enabled for one explicitly selected, unique external display, OpenCove listens
for public local Foundation BetterDisplay `.osd`, `.launched` and `.terminated`
notifications. It does not discover, launch or configure BetterDisplay, send any
notification/request, invoke its CLI, contact a network service, read/write display
hardware, request permission or take ownership of hardware keys for this feature.
The user configures dispatch and any duplicate vendor overlays in BetterDisplay.

Any local sender can spoof these notifications. Their JSON object string has a
fixed 16 KiB bound. OpenCove accepts only the selected presentation display ID,
`hardwareBrightness` and strictly typed finite in-range numbers. It ignores external
text, symbols, commands, paths and other presentation instructions. It does not log
or persist the payload. One in-memory report holds provider, UUID/current-ID/
generation identity, control target, fraction and monotonic receipt time. The
5-second receipt limit is a local eligibility rule, not a physical freshness or
sender-authentication guarantee. Reports contain no source timestamp, and delivery
can be delayed or lost.

Selection, display and session changes, sleep, shutdown, stop, opt-out and category
disable retire cached data and external presentation. Orderly provider termination
also retires it; silent termination is not detectable. Hidden overlay labels pause
reception so external values retain visible source attribution. These HUDs and the
separate cache-only BetterDisplay preview never produce haptics. Native brightness
state, setters, permission gates, key ownership and the ordinary native preview keep
their existing paths. Physical readings, completed changes, installed-vendor positive
acceptance and runtime privacy behavior remain unverified; see [acceptance limits](hardware-huds.md#betterdisplay-acceptance--unverified).

## Network and external services

- **Weather:** When enabled with a selected location, OpenCove sends latitude and longitude to `api.open-meteo.com` for current conditions and hourly/daily forecasts in one request. It can refresh about every 15 minutes. The provider also sees normal network metadata, including your IP address. Weather data is credited to [Open-Meteo](https://open-meteo.com/) under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The [free-service terms](https://open-meteo.com/en/terms) permit non-commercial use and set request limits; they apply separately from the data license and the app's MIT license. Commercial use needs a separately arranged provider service; OpenCove currently uses the free endpoint. No weather dataset is bundled.
- **Travel:** After travel opt-in and origin selection, MapKit sends the necessary event destination query and origin region to Apple Maps. Directions use origin/destination coordinates and the event's arrival time. The app does not send the event title, notes, body, or meeting URL as a place query. Requests can recur when an eligible route becomes stale. This is not an offline feature.
- **Artwork:** With the Spotify Automation fallback, artwork URLs on Spotify's `scdn.co` image CDN can be downloaded over HTTPS. The CDN sees the image request and normal connection metadata. Other metadata/artwork can come from the local media system or the chosen app.
- **Links and sharing:** Opening a meeting, media, calendar, Maps, or weather link hands it to its registered app or browser. File sharing uses the selected macOS share service. Those apps/services can contact their own servers.
- **Updates:** Configured releases contact the HTTPS appcast host when you choose Check for Updates or permit automatic checks. Downloads contact the archive host named in the feed. The configured feed and current release archive use the Cloudflare-backed `opencove.sergeserbinenko.com`. Those hosts see the requested feed/archive, normal connection metadata including IP address, and Sparkle's app/version request information. OpenCove leaves Sparkle system profiling off. Automatic downloads start off and can be enabled in Settings or Sparkle's consent UI. Sparkle stores its preferences and last-check state in macOS user defaults and can cache downloaded updates under macOS cache policy. Ordinary development and control launches do not start the updater; explicit isolated verification uses a loopback feed and separate updater preferences. See [updates](updates.md).
- **iCloud settings (optional):** Sync is off by default and requires an explicit opt-in on each Mac. With a usable signed iCloud Key-value storage capability, OpenCove uses Apple's `NSUbiquitousKeyValueStore` to sync an explicit allowlist of appearance and behavior settings, such as panel layout, hover and animation timing, media presentation, alert duration/speed, accent color, and weather presentation style. Apple/iCloud processes these settings and normal service connection metadata under Apple's policies. The payload excludes sync consent and other integration/access choices, credentials and tokens, file paths/bookmarks, display identity, weather/travel locations, Calendar identifiers/events, media/artwork/playback state, mirrored notification content, and other live state. Turning sync off stops new app cloud reads, writes, and incoming settings updates on that Mac. Local preferences and the shared iCloud snapshot are kept; macOS can still deliver writes queued before disabling or quitting. Passing the app's signed capability check does not prove service acceptance. Real delivery between two Macs remains unvalidated. See [iCloud settings](icloud-settings.md).
- **Development and distribution:** SwiftPM downloads the official Sparkle binary SDK from GitHub and verifies the pinned SHA-256. Git clone and CI also use GitHub. Normal local packaging does not upload. Only an explicit `--notarize` command submits a signed app to Apple's notary service with the maintainer's keychain profile.

## Local control interfaces

An explicit `--control-port` launch enables an HTTP listener bound to `127.0.0.1`. It requires an ephemeral token and checks the host/origin. `control.json` holds the token in the app data directory with owner-only file permissions. The API can expose media, event, file, and device state and perform real app/settings actions. A token-bearing URL grants that access to its holder; do not share it. Normal launches do not start the listener.

A separate optional notification URL API uses the app's URL scheme and a saved token. Its token can appear in a URL and in the sending application's history or logs. It is off until enabled. Revoke it from the app if exposed. Neither interface is an internet service.

## Explicit finite Lock Screen Keep Awake (L06)

An available lock card can explicitly start a 1–120 minute system-wide display-
idle assertion, default 5 minutes. It can affect other displays and idle system
sleep. It does not wake a sleeping display or override lid/manual sleep. No
active state or duration is saved or synced. Effective private/widget opt-outs,
private-content reductions and other admission losses retire the session even
if saving fails. There is no new preference, permission, reader or helper.

Full incoming tuples and action authority remain private in memory. The opt-in
authenticated loopback command route exposes only bounded non-content receipts
and opaque one-use prepare tokens; tokens and private tuples do not appear in
the Keep Awake state projection. Release uncertainty blocks later creates for
the process and stays visible after unlocking. Ordinary app-panel facts do not
prove visibility above the secure screen. Real secure reachability, intact
authentication and physical power behavior remain separate user-led acceptance
gates. See [the finite-session contract](lock-screen-keep-awake.md).

## I08 ordinary status-menu playback

The status menu adds fixed **Previous Track**, **Play/Pause** and **Next Track**
labels. It exposes no title, artist, artwork, source row or playback history.
Opening or validating the menu reads existing in-memory preferences, media
availability/capability and lifecycle state. Eligible validation reuses the
existing public active-console/login check. Media OFF, unavailable media and an
unsupported command return before that query. This does not promise zero OS
work or establish that an unknown lock state is securely unlocked.

Only a deliberate selection that passes fresh admission calls the matching
existing transport method for the currently accepted source. Existing backend
checks and no-prompt command permission behavior remain unchanged. Previously
submitted adapter/AppleScript work can finish after a later item/session change
under its existing queue contract. Selection supplies no new success receipt,
source-authenticity guarantee or cancellation lease.

This adds no reader, consent, permission request, persistence, schema, default,
cloud field, observer, timer, process or power handle. Media OFF disables these
actions even if independent lock-widget consent keeps media populated. Existing
whole-document recovery's Media OFF is sufficient; missing-file factory policy
is unchanged. Failed admission does not start a reader, refresh, save, open
Settings or queue a command for later. Existing media error surfaces remain
available through Open OpenCove. Native/privacy acceptance remains separate.

## I06: Local hover choice and persistence

**Don't expand on hover when idle** stores `disableIdleHoverExpansion`, default `false`, through the existing ordinary Settings binding. The control is disabled when **Expand on hover** is off; its saved value and scope note remain. This choice applies to this Mac. It adds no reader, consent field, permission, prompt, helper, provider or cloud allowlist/schema member. Existing remote allowlisted choices can change the master hover setting without replacing this local value; M1 stays deferred.

Existing synthesized Codable/Equatable, strict recovery and generic API validation include the new Boolean. A new/missing file or missing key uses `false`. Actual JSON Booleans persist. A malformed saved field repairs to `false` with the existing repaired-field notice, damaged-byte backup and independent-grant reduction. Whole-document fallback uses `Self()` plus the unchanged all-29-reader-OFF recovery inventory. Invalid API types reject the whole transaction before apply; they do not exercise file repair.

Ordinary Store application/save/equality/retry and existing visible errors remain in charge. A save failure can leave a session value whose older saved value returns after restart. An overall failed transaction can coexist with a successful JSON write. Session value, disk bytes, backup/error and restart are separate evidence. Backup failure preserves the damaged original. No new error history, banner or retry is added. Common Settings/save work can still reconcile readers, login-item status and session state; this choice makes no zero-status-call claim.

The veto applies only to automatic idle-clock hover. Visible compact input and the existing **Open OpenCove** menu still provide explicit access without enabling readers. With idle hosting content retired, hidden clock clicks are not promised. The task uses existing local surface/model/session facts and one existing public completion getter; it adds no monitor or protected operation and supplies no secure or physical-input guarantee.
