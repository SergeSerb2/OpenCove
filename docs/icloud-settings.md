# iCloud settings synchronization

This source implements opt-in synchronization through the public
`NSUbiquitousKeyValueStore`. It has not been built or run against iCloud. The
current package does not provision the required capability, so its opt-in must
report unavailable. Cross-device delivery is an outstanding acceptance gate.

## Apple contract reviewed on 2026-10-23

- [NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
  shares property-list values between instances using the same Apple account.
  It allows 1 MB total, 1 MB per value, and 1024 keys. Its current reference gives
  a 128 UTF-16 character key limit. It warns against sensitive data because its
  on-disk store is not encrypted. Offline writes can remain local and upload
  after a later sign-in.
- [synchronize()](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize())
  can report an entitlement/service error. A successful return does not force
  upload or establish delivery to another device. Apple schedules and limits
  updates. This implementation calls it at opt-in/reconnect, while an enabled
  session returns to the foreground, or for the explicit check action.
- [External change notifications](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/didchangeexternallynotification)
  supply server-change, initial-sync, quota, and account-change reasons, with
  optional changed keys. An initial notification is not a delivery receipt.
- [Apple's preferences sample](https://developer.apple.com/documentation/foundation/synchronizing-app-preferences-with-icloud)
  retains local persistence, enables Key-value storage, registers an observer
  before synchronizing, and asks for the same account and iCloud Drive enabled
  on both devices.
- [The entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.ubiquity-kvstore-identifier)
  requires the iCloud capability with Key-value storage enabled. The current
  [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
  marks iCloud key-value storage available for Developer ID as well as paid
  Apple Developer Program distribution. The Foundation class page still says
  App Store/Mac App Store distribution is required. Preserve this discrepancy
  in the release review; do not infer service acceptance from Developer ID
  signing or from either document alone.
- [ubiquityIdentityToken](https://developer.apple.com/documentation/foundation/filemanager/ubiquityidentitytoken)
  represents the iCloud Drive Documents identity. The token can detect account
  changes without opening a document container. This implementation requires
  that identity as a conservative account safety gate. It does not treat the
  token as proof that KVS can deliver data. A properly provisioned KVS-only app
  must still prove that this gate is usable on the supported macOS versions.

No original Alcove source, executable, or assets are an input to this work.

## Local ownership and data scope

`CovePreferences.syncSettingsWithiCloud` is false by default. A missing or
invalid legacy consent value recovers as false. Each device stores its own
choice in the existing local preference document. The choice is never part of
the cloud payload. There is no cloud store construction, account-token read,
cloud observer, or synchronization call before saved consent and the signed
capability gate pass. Disabled foreground callbacks return before cloud access.

`CoveStore` owns all preference persistence and runtime updates. Incoming data
overlays only the explicit allowlist and uses `savePreferences()`. The existing
normalization, damaged-file backup, atomic JSON write, layout callback, and
error reporting remain the owners of their respective work. An apply guard
prevents that save from publishing an incoming snapshot again. Failed local
saves do not publish session-only changes and pause incoming updates. A
successful later save permits an explicit reconnect.

The existing update path can apply settings for the current session even when
its save fails, or save JSON while a separate login-item update fails. An
incoming update follows that same contract and pauses on an overall failure;
its status does not claim that the whole update was saved successfully.

The allowlist in `CoveSyncedSettings` contains:

- Contrast outline; idle/full-screen hiding; hover expansion and delay;
  collapse delay; panel dimensions and radius; animation speed and reduced motion.
- Paused-media display and delay; song-change peek and duration; compact activity
  and expanded layout; Now Playing style; playback indicator; artwork color accent.
- Global and per-alert duration/speed; accent color; weather presentation style.

All integration switches and device access choices remain local. This includes
Calendar access and app choice, media access and app choice, private APIs,
AppleScript, waveform capture, notification mirroring, HUD replacement,
lock-screen access and private content, weather access, display identity and
placement, simulated notch, haptics, login registration, onboarding, and sync
consent. File trays, paths, bookmarks, Calendar identifiers/content, credentials,
tokens, permission grants, artwork, playback state, and other live state are
never read into the payload. New preferences remain local by default.

## Payload, conflicts, and stopping

One key, `opencove.settings.snapshot`, contains a JSON `Data` value of at most
16,384 bytes. Version 1 stores only the allowlist, a random revision UUID, and
an optional parent revision UUID. It contains no device name, account identity,
timestamp, or history. Values must have their exact expected primitive type,
finite numeric range, and allowed string choice. Missing/unknown setting keys,
invalid values, wrong object types, oversized data, and unsupported versions
stop synchronization without replacing local settings or overwriting cloud data.

At each start or reconnect, an equal cached snapshot permits automatic sync
without a write. A different snapshot requires **Use iCloud Settings** or
**Use This Mac's Settings**. An empty cache waits without seeding automatically.
The latter action explicitly chooses to replace the shared snapshot, including
one still in transit. It rereads and validates the current cache at the action.
There is no public KVS API that proves an empty cache is a globally empty store.

After that choice, saved local changes publish automatically. Repeated equal
snapshots do not publish. Incoming updates apply automatically when no local
publication is pending, or when their parent is the current local revision.
An incoming branch that conflicts with a possible local publication pauses both automatic
directions and keeps the local settings until the user chooses. A missing cloud
snapshot after an accepted snapshot also requires a choice; it never resets
local preferences. A long descendant chain whose intermediate revisions were
not observed may conservatively show a conflict. There is no per-field merge,
wall-clock ordering, cross-device compare-and-swap, or delivery acknowledgement.
Revision state is bounded and memory-only; restart rechecks both snapshots. An
equal cache at startup is conservatively protected as a possible offline local
write from the previous process. A divergent arrival then requires a choice
even when no new local edit was made in this process. An equal cache is never
treated as proof that a previous local write reached the server.

Disabling or resetting settings stops observers, drops the account token and
cached revisions, and invalidates deferred notifications immediately, even if
the local save fails. It does not delete either local preferences or the shared
snapshot. Store shutdown also detaches. Account changes, quota errors, malformed
snapshots, and service errors require explicit reconnect. A local edit alone
does not restart a paused session. The account token is checked before reads and
writes, retained only in memory, and never displayed, logged, or persisted.

macOS owns writes already queued through KVS. Turning sync off, quitting, or
detecting an account change cannot cancel or retract those writes. UI status
states this limit and never labels a local enqueue or synchronize result as
cross-device delivery. There is no timer, retry loop, per-save synchronize call,
cloud delete action, custom cloud endpoint, or local export/import substitute.

## Concrete signing prerequisite

The source package uses `org.opencove.OpenCove` for release and a separate `.dev`
identifier for development. `script/package_release.py` currently supplies only
the automation entitlement to Developer ID app signing. Its validator and
`script/signing_info.swift` intentionally enforce that exact main-app entitlement
set. Neither the package manifest nor packaging supplies an Apple-provisioned
KVS entitlement or embeds a profile for it. This work changes none of those
files, the Sparkle dependency/provenance, release metadata, or delivery infra.

The gate requires a real app bundle, its signed
`com.apple.developer.ubiquity-kvstore-identifier`, its signed
`com.apple.developer.team-identifier`, and a valid Apple-anchored signature for
that team. The store identifier must be the actual provisioned ten-character
App ID prefix plus the running bundle identifier. The App ID prefix is not
assumed to equal the Team ID. This intentionally prevents a `.dev` app from
silently sharing the release store. A text placeholder, ad-hoc signature,
self-signed certificate, absent entitlement, or unrelated store cannot pass.
Passing the gate proves only the local signed capability check, not profile or
server acceptance.

The release owner must obtain/confirm the actual registered App ID, Key-value
storage capability, appropriate Apple-issued provisioning profile, and matching
signing identity in the owning developer account. No account, profile, identity,
or secret was accessed for this implementation. Do not invent a container or
reuse the production store for an isolated probe. Before enabling delivery in a
future package, update signing and release validation together to accept only
the intended main-app capabilities, preserve the automation entitlement, and
leave Sparkle helper signing rules and upstream provenance intact. Validate the
embedded profile and effective entitlements on every architecture. Keep existing
packages fail-closed until those prerequisites and real service acceptance pass.

## Parent runtime acceptance plan

These steps have not been run. They require the parent's runtime ownership and
two separately opted-in real Macs/accounts as specified below. Keep account
identities, tokens, profiles, diagnostics, and setting files in private evidence.

1. Build/typecheck/package the actual source with the repository workflow. First
   use the unchanged ad-hoc and Developer ID configurations in isolated app data.
   With a legacy preference file, verify old saved values remain and sync is off.
   Verify corrupt/missing consent stays off. Save, relaunch, foreground, and reset
   while off. Observe zero KVS/default-store/token calls, observers, and cloud
   writes for these flows using debugger breakpoints or parent-owned diagnostics.
2. Turn sync on in a package without the real entitlement. Verify it saves only
   this Mac's opt-in and shows unavailable before obtaining a token or cloud
   store. Other settings must still save. Turn sync off and relaunch to prove
   the local consent transition. Do not add a fabricated entitlement to pass it.
3. After the signing prerequisite is fulfilled, use an isolated registered app
   identity/store and a real, explicitly authorized validation account. Keep
   Calendar, permissions, hardware controls, capture, and other private integrations
   disabled in the isolated local preferences. Check gate behavior with no Drive
   identity and with a correctly provisioned KVS-only build. Capture effective
   signed capability/profile evidence privately. A token or synchronize success
   alone does not pass cloud acceptance.
4. On Mac A, opt in with a verified empty or deliberately prepared isolated store.
   Confirm no automatic seed when the cache is empty. Choose this Mac's settings;
   verify one bounded value is queued with only the allowlist. On Mac B with the
   same account and app/store identity, keep sync off first: no cloud access or
   application is allowed. Opt in on B with different local style settings, wait
   for real delivery, and choose iCloud settings. Verify A's exact chosen values
   in B's real Settings UI and B's saved preference file, then relaunch B. Keep
   unrelated per-device saved choices distinct and unchanged.
5. Change an accent, a hover delay, and a per-alert duration through A's real
   Settings UI. Observe their real arrival and local persistence on B without
   another manual import. Reverse direction on B. Record exact envelope revisions
   and matching values on both devices privately. Confirm incoming saves do not
   create echo revisions, and equal/unchanged/local-only saves do not enqueue
   duplicates. Do not substitute a local cache read or mocked notification for
   this two-way cross-device proof.
6. Disconnect one Mac, make different allowlisted edits on both Macs, then
   reconnect. Require a real divergent revision delivery and the conflict UI.
   Verify no automatic replacement while it is unresolved. Test each choice in
   separate rounds and verify the selected values eventually converge through
   the service. Repeat with multiple rapid edits and a skipped intermediate
   revision, and restart with a local write pending; a conservative conflict is
   allowed. A divergent arrival after an equal startup cache must not silently
   replace the possible pending local snapshot. KVS can choose a winner before
   the app observes both branches; the app cannot promise lossless history.
7. Disable on B, change A, and wait for delivery. B must keep local values, have
   no live observer/callback work, and not publish further edits. Reenable and
   resolve any difference. Reset B: it must opt out without publishing reset
   defaults or deleting the cloud snapshot. Quit with writes pending: do not
   assert cancellation of already queued system writes.
8. In the isolated validation account/store, verify real account/sign-out changes
   pause reads and writes before further local work. Confirm unrelated saved
   edits cannot reconnect. Explicit reconnect must review the new account/cache
   before any differing local snapshot can be published. Include an offline
   session and later service recovery; status must continue to distinguish
   queued data from verified arrival. macOS may process older queued writes.
9. Use the real signed caller and isolated store for wrong-type, unsupported
   version, omitted/extra setting key, nonfinite/out-of-range value, and 16,385-byte
   payload cases. Require safe pause, no overwrite, and unchanged local settings.
   A nonfinite JSON representation may fail decoding before value validation.
   Real quota rejection needs a controlled store/account setup; leave it as an
   explicit gap unless an actual service quota notification is observed. Do not
   fill a user's production store or fabricate notifications to claim coverage.
10. Make an isolated local settings save fail, verify no new cloud publication
    and no further incoming application after pause, restore writability, save
    successfully, then explicitly reconnect. Cover both a local edit and an
    incoming update save. An attempted incoming update can still apply for the
    session under the existing save contract; its status must report failure.
    Verify the existing error and original saved file/backup ownership. Confirm
    the final signed package still passes release/Sparkle provenance validation.

Source parsing and diff checks cannot prove type correctness, signing/profile
acceptance, identity availability, notifications, quota behavior, offline/account
transitions, UI operation, or cross-device convergence. Those remain runtime
gates until the parent records the corresponding real evidence.
