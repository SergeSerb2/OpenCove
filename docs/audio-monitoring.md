# Audio level and output inventory reads

Volume/mute notifications and the synchronous hardware-control read refresh the
actual current route, UID, levels and capabilities. They do not rebuild the
output-device inventory when the route is unchanged and inventory monitoring is
healthy. Metadata/device-list notifications, current-route changes, missing or
changed UIDs, unavailable routes, read errors and failed inventory listeners
retain a full read. A pending full audio read also takes priority.

Startup, explicit Refresh, the native output picker and existing fallback
polling still read all output choices. The picker keeps fresh names, eligibility
and route selection. Setter validation still checks actual IDs/UIDs before
writing. This changes no hardware value and adds no timer or recurring telemetry.

The opt-in development `system.refreshAudio` command accepts `hardwareControl`
to exercise the real read-only current-level entry. Its existing request-scoped
evidence reports actual synchronous domain entries and attempted setters.
`nativePicker` mounts the real Activities settings picker; `developmentAPI`
retains the full audio refresh. No caller posts a hardware event. Physical
volume-key delivery, natural listener events, hotplug, service restart and
listener-failure recovery require separate live coverage. Read counts alone do
not establish CPU, energy or reference-product superiority.
