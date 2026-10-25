# Finite Lock Screen Keep Awake

Composition: `L06-direct-finite-lock-session-v1`. This is OpenCove policy. The
retained Alcove changelog declares Lock Screen Keep Awake and later range
increases. Alcove's default, range, trigger, layout and cleanup remain
`SPEC_UNKNOWN`. No original reference app, source or assets supplied this work.

The source candidate requires independent review and a separately authorized
build. Syntax parsing cannot establish type correctness, native reachability,
power behavior, accessibility, performance, or full parity.

## Controls and scope

Keep Awake is the first section inside the existing lock card's ScrollView.
Existing media, calendar, weather, battery, Focus and connectivity stay below it.
The panel keeps its authentication-safe frame and non-key/non-main policy:
320–560 points wide, 180–280 high, default 460×250. Content scrolls inside that
frame. The new row adds no animation, countdown, text field, keyboard equivalent,
popover, global input monitor, activation, sound, haptic or wake request.

The shared whole-minute duration draft starts at **5 minutes**, with a **1–120
minute** range. Start is explicit. Stop names the exact current session. Restart
is a separate explicit action: it releases the old assertion before attempting
a new finite assertion. A duration edit affects the next action only. Repeated
Start does not change the current assertion or deadline. The draft resets at a
new lock epoch, controller restart, or loss of all admitted panels. Routine
layout and rendering preserve it.

The public `PreventUserIdleDisplaySleep` assertion affects automatic display
sleep system-wide, including idle system sleep. The display ID identifies the
control card, not a physical power target. It does not wake an already sleeping
display or override manual or lid sleep. Activity and duration are never saved
or synced. Lock, wake, relock, login, restart, preference save, prepare and view
mount cannot start or renew a session.

## Authority and lifetime

`OpenCoveDelegate` roots one `@MainActor LockScreenKeepAwakeSession` independently
of controllers, views, Settings and the optional control server. Only that owner
calls the public power APIs. It holds at most one owned assertion, including
provisional, retiring and quarantined states.

The controller retains the complete incoming `(CovePreferences, SystemState)`
tuple before reconciliation effects. It uses snapshot/admission/presentation
revisions, a reconciliation-depth guard, and a newest-pass identity. Old outer
work cannot publish or remount authority over a newer incoming tuple/layout
pass. Layout uses the retained winner. At admission and after successful create,
complete stored getters must equal the retained winner. This check can only
veto; old Combine `willSet` getters cannot grant authority.

Start and Restart require the current running controller and one-way lifetime,
known locked state, enabled private integration and lock widgets, an active
logged-in console session, awake displays, and at least one admitted existing
widget. The existing display resolver and bounded frame must still select the
same display. The exact native row must belong to the same panel/content view,
with the same mount identity, intersecting visible native content bounds. A
passive `NSViewRepresentable` row attachment registers this identity and reports
native geometry/removal; it cannot start power. Native buttons resolve the real
row at activation. The offscreen renderer receives no capability and defaults
to an inert projection. Settings receives only the root's read-only status.

The opaque action binds owner, controller lifetime, lock epoch, presentation,
mount, display and selected display IDs, full private tuple, revisions, purpose,
validated minutes/seconds and expected session. The root binds the request ID
and payload. Command tokens also bind continuous issue/expiry times and the
owner's current intent revision. They never appear in `/state` or a cached
receipt. Full tuples stay private in memory.

A mounted, ordered ordinary panel plus private lock knowledge is an
app-confirmed admission boundary. It does **not** prove visibility above macOS's
secure screen or physical user input. Later user-led native proof must establish
visible, reachable controls and intact authentication. Failure there fails usable
L06 acceptance; command-only success cannot replace that gate.

## Revocation

Current effective preferences can revoke even when their save fails. No saved
power grant, saved-consent receipt, new preference, Store callback, reader or
helper is added. The existing Store and recovery paths stay unchanged.

Retirement occurs on private integration or lock-widget opt-out, a follows-
activities change, private-content reduction, removal of any previously admitted
widget, or any display-selection policy change. Unknown/unlocked state, inactive
console/session, sleep, origin display/frame loss, origin panel/content/row
removal, controller stop/deinit and graceful app termination also retire.

Origin loss ends the session even if another card survives. Non-origin card loss
preserves it. Geometry and scrolling invalidate pending contexts; scrolling alone
does not stop or renew an active assertion. Additions, styling, ordinary metadata
and unrelated saves do not extend or replace a session. Fallback, reconnect,
wake, relock and re-enabling policy can restore idle controls only.

Controller deinit synchronously invalidates a private, locked, Sendable one-way
lifetime record. It queues retirement for that exact controller/session
generation on the main actor. The root still owns the handle; no controller
cycle or destructor-owned assertion is needed. A late successful create under
an invalidated lifetime is rooted provisionally and immediately retired.

## Finite API and failure policy

Create uses `IOPMAssertionCreateWithProperties`, with type
`kIOPMAssertionTypePreventUserIdleDisplaySleep`, initial level On, name
`OpenCove Lock Screen Keep Awake`, non-personal duration details, exact numeric
`TimeoutSeconds` from 60 through 7200, and explicit
`kIOPMAssertionTimeoutActionTurnOff`. It never updates an old timeout, re-arms an
old assertion, calls Retain, uses TimeoutActionRelease, or declares user activity.

The owner records continuous attempt/return instants `t0`/`t1`. The application
deadline is `t0 + seconds`. Successful OS activation occurred during that call,
so its finite deadline is bounded by `t1 + seconds`; this is a public API bound,
not an observed hardware timestamp. Wall-clock expected-end text is a convenience
label only. A return after the application deadline retires the provisional
handle without publishing it active.

One cancellable ContinuousClock task exists only for the exact active session,
generation, deadline and lifetime. No periodic power query, countdown, inactive
timer, retry or renewal is added. `/state` can derive passage of expected bounds
on demand. It cannot observe OS expiry or perform cleanup. Start/Restart reject
an expiry-pending handle until scheduled/lifecycle retirement or explicit Stop
finishes.

Every retirement revokes intent and cancels/removes the expiry task first, then
calls `IOPMAssertionSetProperty(LevelOff)` once and `IOPMAssertionRelease` once,
even if Off fails. Only successful Release clears the owned slot. Release
failure retains the full original assertion/context, creation properties,
finite timing evidence, retirement reason and both codes in process-life
quarantine. No later path touches that numeric ID or creates another assertion.

If Off succeeded but Release failed, the UI says ending was accepted and cleanup
is unconfirmed. If both failed, it says the Mac may remain awake until the
original finite limit. On-demand reads after that bound still say cleanup is
unconfirmed. No uncertain state is labelled successfully stopped.

Create error transfers no valid output handle by the public contract. The owner
never reads, sets or releases its output on error. It retains the attempted
finite properties, timings and code, reports creation uncertainty, and blocks
further creates for the process. Quit/relaunch is the recovery. Graceful
termination uses the same retirement before controller/store teardown. Hard exit
cannot run cleanup; immediate process-exit behavior remains unverified. The
original finite OS timeout remains the contractual bound for an accepted effect.

## Authenticated command schema

These actions use only the existing opt-in loopback `POST /command`, its existing
host/origin/token checks, body limit, descriptor ownership and generic
`script/opencovectl command` transport. No listener or CLI change is added.
Each action requires **exactly** the listed keys. There is no state, visibility,
bounds, clock, permission, API-result or native-origin override.

- Prepare Start: `action: "keepAwake.prepare"`, `operation: "start"`, `minutes`,
  `displayID`.
- Prepare Restart: the same with `operation: "replace"` and a required exact
  current `expectedSessionID` UUID string.
- Commit Start: `action: "keepAwake.start"`, `intentToken`, `requestID`.
- Commit Restart: `action: "keepAwake.replace"`, `intentToken`, `requestID`.
- Stop: `action: "keepAwake.stop"`, `requestID`, `expectedSessionID`. The last
  field is a UUID string for the exact active session, or JSON null only when
  idle. A stale ID cannot stop a later Restart.

`minutes` is a required finite non-Boolean integral JSON number in 1…120.
`displayID` is a required non-Boolean integral UInt32 identifying an actually
admitted mounted card. Strings, missing numbers, fractions and out-of-range
values reject without power. Request IDs and tokens are UUID strings. Origin is
always derived by the route. Native actions use the same owner/validator without
a remote token.

Prepare returns one opaque `intentToken` with `validForSeconds: 10`, based on
ContinuousClock. It creates no assertion or task. A new prepare replaces the
pending token. Any incoming tuple or geometry change invalidates it. A matching
commit consumes it before expiry, purpose and admission validation. A retired
owner intent revision also vetoes old tokens. A token can never create twice.
Evicted, consumed or invalidated tokens return `INTENT_USED`; an extant expired
token returns `INTENT_EXPIRED`. A retained context that fails current authority
returns the appropriate policy error or `STALE_CONTEXT`.

Successful command responses carry `app`, `pid`, and `dataDirectory` for the existing
CLI owner-identity check.
Every effect response includes `resultCode` and a bounded immutable
`keepAwakeOutcome`, cached before response encoding. The last request ID and
exact typed payload replay the same cached outcome. A different payload under
that last ID returns `INVALID_ARGUMENT`. No automatic response retry occurs.
Exact replay describes the original request's API attempts; it performs none.
The single cached outcome is reconciled through `/state` after a dropped reply.

Receipts include request/creation-request/origin/purpose, session/generation,
assertion type/timeout action, duration/context
revisions, process-relative continuous attempt/return/deadline bounds, API codes,
intent/handle states, effect evidence, `apiAttempted` and saturating real create
and retirement attempt counts. Restart retains the old retirement and, if
needed, the stale new-handle retirement in a bounded array of at most two records,
each with exact session/generation, codes, reason and call times. No private
content, full tuple, assertion ID or token is exposed by this projection.

HTTP status distinctions:

- **400**: `INVALID_ARGUMENT`.
- **401/403**: existing authentication and host/origin/cross-site failures.
- **409**: `OWNER_UNAVAILABLE`, `OPERATION_IN_PROGRESS`, `POLICY_DISABLED`,
  `LOCK_STATE_UNKNOWN`, `NOT_LOCKED`, `SESSION_INACTIVE`, `SCREENS_ASLEEP`,
  `NO_ADMITTED_WIDGET`, `NO_ADMITTED_PANEL`, `CONTROL_NOT_MOUNTED`, `STALE_CONTEXT`,
  `INTENT_EXPIRED`, `INTENT_USED`, `ALREADY_ACTIVE`, `SESSION_MISMATCH`,
  `CLEANUP_UNCONFIRMED`.
- **500**: `API_CREATE_FAILED`, `API_RETIRE_FAILED`.
- **200**: `PREPARED`, `STARTED`, `REPLACED`, `STOPPED`, or the idle Stop no-op
  `IDLE`. Lifecycle receipt `RETIRED` records accepted Release.

The authenticated `/state` `keepAwake` field reads the root owner independently
of the weak controller reference. It contains the projection, last outcome and
attempt counts. It creates no context, power query, task or cleanup. Existing
unrelated state fields retain their prior semantics.

## Parent gates remain open

Only syntax parsing and static source/Git/hash/mode/range checks are in scope
for this implementation task. Independent exact implementation reviews precede
a parent-owned isolated build. A new no-effect real-interface caller/package
binding and a separate parent execution decision precede runtime work. Positive
power and user-led secure/native/AX acceptance each need their own explicit
commission. Failure branches need real reachable failures; no unit tests, mocks,
fixtures, fake events, state, clock or API-result injection may replace them.
Performance needs comparable real-flow measurements.

M12's exact-26cf saved evidence and R7 CLEAR do not transfer to this candidate.
C-PID stays FAILED; M1 USER-DEFERRED; C03 and Stage4/Focus HOLD; blur FAILED;
sound blocked. Native, positive power, secure reachability, AX and performance
stay UNVERIFIED. Reference remains SPEC_UNKNOWN. Full parity is INCOMPLETE.
