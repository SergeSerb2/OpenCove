# Notification mirroring

`NotificationMirror` is an independent MIT service in `Sources/OpenCove/Services/NotificationMirror.swift`. It uses public macOS Accessibility (AX) observer and read APIs. It has no Alcove dependency, proprietary code, or external runtime dependency.

## Store integration

The service targets macOS 15+. Construction does not start it. `CoveStore` owns it on the main actor and keeps mirroring off by default. Collection requires the notification and mirroring settings, private integrations, a known unlocked state, and an active console session. The store supplies `canCollect`, which the service checks before attaching, before each text read, and before delivery. Its default collection policy denies access.

The store receives `onNotification` only under that policy. `onCollectionStopped` clears mirrored history and any visible mirrored HUD. Only an explicit access button calls `requestAccess()`; startup and periodic checks do not request permission.

Call `start(enabled:)` again when settings change. `start(enabled: false)` is equivalent to `stop()`. Repeated enabled starts do not add duplicate observers. `requestAccess()` does not enable mirroring. Wire that method only to a clear user action, never startup or a periodic check.

`onNotification` receives a best-effort title and body on the main actor. AX supplies label order rather than a structured notification payload: the first nonempty text label becomes the title; later labels form the body. There is no reliable sender bundle ID, notification ID, date, attachment, action, or reply contract. Callers must not infer those fields from the text.

`status` describes permission, process discovery, registration failure, waiting, or confirmed readable content. `available` starts false. It becomes true only after an active Notification Center process exposes readable banner text. Permission alone, observer registration, and a window event do not set it true. It resets on stop, permission loss, or replacement of the process that supplied that content. A true value is evidence of a successful read in this enabled session, not a guarantee about the next notification. Keep the opt-in and permission controls usable while it is false.

## Permission and privacy

The user must explicitly enable mirroring and grant OpenCove Accessibility access in System Settings > Privacy & Security > Accessibility. `start(enabled:)` uses the non-prompting `AXIsProcessTrusted()` check. Only `requestAccess()` uses `AXIsProcessTrustedWithOptions` with its prompt option. The system prompt is asynchronous; a grant can be detected by the next enabled lifecycle check. The service does not change system settings or restart any process.

Accessibility access is broad. Explain that mirroring can display sensitive text from notification previews, including messages and one-time codes. There is no automatic content redaction or reliable app-specific filter. This implementation reads only what Notification Center exposes through AX. It does not fetch hidden previews, query another app, read the notification database, or bypass Focus or notification settings. Do not describe this as a guarantee that all sensitive text is redacted: AX exposure and macOS preview rules can change.

The service does not persist, transmit, or log notification text. It retains window references and process-random content fingerprints in memory for duplicate suppression. Fingerprints expire after 12 seconds and are capped at 128 entries. It does not keep a notification history. The store keeps callback content transient and applies the same privacy rules to presentation. Disabling either setting, locking, or leaving the active session stops collection and clears mirrored presentation. The service itself does not manage lock-screen UI.

## Passive observation and bounds

While enabled and trusted, the service finds `com.apple.notificationcenterui`. It also accepts system executables named `NotificationCenter` or `NotificationCenterUI` under `/System/Library/` to cover another or missing bundle ID. It watches at most four matching processes. It installs `AXWindowCreated` and, when supported, `AXCreated` observers on each process's application element. Generic created events qualify only when their element is an AX window from that process. It does not walk the application tree or read existing windows on attachment; it remembers up to 64 existing window identities to avoid replay.

For each new window, a bounded read looks for an `AXNotificationCenterBanner` subrole. This system subrole is an undocumented compatibility heuristic, not a public Apple notification delivery contract. If it is absent, the service does not present arbitrary window text as a notification. It reads only title, description, and static text values inside a matching banner. Structural roles, subroles, and child relationships scope the read. It skips input controls and action labels. Empty and repeated labels are removed. A banner with only a readable title can be delivered with an empty body.

Each attempt visits at most 96 elements, at most six child levels below the window, and at most 16 children per element. It makes at most 256 attribute reads, with a 150 ms soft elapsed-time budget and a 40 ms per-element AX messaging timeout. AX calls are synchronous, so these time limits depend on macOS honoring its timeout; they are not a hard real-time guarantee. Output is limited to 16 labels of 512 characters each, a 256-character title, and a 2,048-character body. One AX string may be larger before local truncation.

At most four windows can have pending reads. Each gets up to three attempts, after delays of 120, 300, and 600 ms, to allow text to populate. The service remembers up to 128 window identities per process and suppresses identical title/body pairs for 12 seconds across transient replacement windows. Legitimate identical notifications within that interval can be suppressed. Reused windows, large trees, rapid bursts, missing text, and unsupported container roles can cause missed notifications.

The three-second timer checks permission and process lifetime only; it never polls notification content. Workspace launch and termination events trigger the same check. Old run-loop sources and subscriptions are removed when a process exits, trust is lost, or the service stops. New processes get fresh observers. Pending reads verify that the original process observation is still active before they deliver. Registration failures retry after 15 or 30 seconds. Dropping the service also cleans up its timer, tasks, workspace listeners, and AX sources.

The service never clicks, types, closes, moves, activates, or dismisses a window. It never sets a UI attribute, performs an AX action, injects input, runs a script, or changes a system setting. `AXUIElementSetMessagingTimeout` changes only the local AX client's request timeout. It does not modify the observed UI. There is no distributed notification fallback or fabricated content.

## Compatibility and limits

macOS 15+ is the build target, not proof that each macOS release exposes Notification Center banners. Apple documents AX observers and their possible unsupported-notification errors, but does not provide a public cross-app notification delivery API through `UNUserNotificationCenter`. That API manages the calling app's notifications. The AX implementation therefore cannot promise full Alcove feature parity or complete delivery.

Registration can succeed without a banner event or readable text. Some versions may reuse a window, change the banner subrole or tree, omit labels, or expose no useful creation events. The service reports that support is unconfirmed until a readable banner arrives. Silence cannot distinguish no new notifications from an unsupported event path. A window event with no readable banner leaves `available` false. No database read, hidden API, broad tree scan, or invented distributed event masks these failures.

The default [integration workflow](quality.md) does not enable live banner capture. Build success and observer registration do not establish delivery on a particular macOS version. With explicit user opt-in, verify off/no-callback behavior, denied access without an automatic prompt, the explicit access button, a real visible incoming banner, repeated window events, disabling during a pending read, and observer recovery after a natural Notification Center relaunch. Do not automate desktop input or terminate system processes to run these checks. If a real banner does not produce an event or readable text, report that macOS version and the content-free service status as a compatibility limitation.

Apple references: [AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification), [AXUIElement API and trust checks](https://developer.apple.com/documentation/applicationservices/axuielement_h), and [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter).
