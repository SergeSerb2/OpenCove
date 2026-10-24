import Combine
import Foundation
import Security

/// Uses the public iCloud KVS only after durable, local device consent. The
/// default store and account token are never obtained in init or while off.
@MainActor
final class CoveSettingsSyncController: ObservableObject {
    enum State: Equatable { case off, unavailable, choosing, active, conflict, paused }
    @Published private(set) var state: State = .off
    @Published private(set) var status = "Off on this Mac"
    @Published private(set) var detail = "Local settings stay on this Mac."

    var currentPreferences: (() -> CovePreferences?)?
    var applySettings: ((CoveSyncedSettings) -> Bool)?

    var canChooseLocal: Bool { cloud != nil && (state == .choosing || state == .conflict) }
    var canChooseCloud: Bool { canChooseLocal && candidate != nil }
    var canCheck: Bool { cloud != nil }
    var canReconnect: Bool { savedConsent && !localSaveFailed && (state == .unavailable || state == .paused) }

    private static let key = "opencove.settings.snapshot"
    private var cloud: NSUbiquitousKeyValueStore?
    // The token is memory-only. Never encode, print, or expose it in status.
    private var accountToken: NSObjectProtocol?
    private var observers: [AnyCancellable] = []
    private var generation = UUID()
    private var accepted: CoveSettingsSyncEnvelope?
    private var candidate: CoveSettingsSyncEnvelope?
    private var localRevision: UUID?
    private var savedConsent = false
    private var localSaveFailed = false
    private var applyingRemote = false

    /// Only call with preferences recovered from disk or a successful local save.
    func startIfEnabled(_ preferences: CovePreferences) {
        savedConsent = preferences.syncSettingsWithiCloud
        guard savedConsent else { stop(); return }
        guard cloud == nil else { return }
        localSaveFailed = false
        detach()
        if let failure = Self.capabilityFailure() {
            setStatus(.unavailable, "Unavailable in this app", failure)
            return
        }
        guard let token = FileManager.default.ubiquityIdentityToken else {
            setStatus(.unavailable, "iCloud Drive identity is unavailable", "This app requires an iCloud Drive identity before it reads or writes shared settings. Check iCloud Drive in System Settings, then reconnect here. Local settings are unchanged.")
            return
        }
        accountToken = token
        let store = NSUbiquitousKeyValueStore.default
        cloud = store
        let currentGeneration = generation
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, self.generation == currentGeneration else { return }
                self.changedExternally(notification)
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.generation == currentGeneration else { return }
                _ = self.checkedStore()
            }.store(in: &observers)
        setStatus(.choosing, "Checking iCloud settings", "No settings have been uploaded. iCloud may deliver an older snapshot later.")
        checkForChanges()
    }

    /// A save failure pauses synchronization; it must not publish session-only
    /// settings or allow an incoming update to replace an unsaved local edit.
    func preferencesDidSave(_ preferences: CovePreferences, persisted: Bool) {
        guard !applyingRemote else { return }
        guard preferences.syncSettingsWithiCloud else { stop(); return }
        guard persisted else {
            localSaveFailed = true
            suspend("Paused: local save failed", "Save settings successfully before reconnecting. No new cloud write was made.")
            return
        }
        let wasEnabled = savedConsent
        savedConsent = true
        localSaveFailed = false
        guard cloud != nil else {
            // A stopped account/error session needs an explicit reconnect.
            // Only a newly persisted opt-in may begin automatically.
            if !wasEnabled { startIfEnabled(preferences) }
            return
        }
        guard state == .active, accepted?.settings != CoveSyncedSettings(preferences) else { return }
        publishLocal(overriding: false)
    }

    func stop() {
        guard state != .off || savedConsent || cloud != nil else { return }
        savedConsent = false
        localSaveFailed = false
        detach()
        setStatus(.off, "Off on this Mac", "New cloud reads, writes, and incoming updates are stopped. Local settings and the iCloud snapshot are kept. macOS may still deliver writes queued before you turned this off.")
    }

    func reconnect() {
        guard canReconnect, let preferences = currentPreferences?(), preferences.syncSettingsWithiCloud else { return }
        startIfEnabled(preferences)
    }

    /// Used at opt-in, on foreground, and by the explicit check button. Never
    /// called per preference edit. A true result is not cloud-delivery proof.
    func checkForChanges() {
        guard let store = checkedStore() else { return }
        guard store.synchronize() else {
            suspend("iCloud could not synchronize", "The app's iCloud capability or service is unavailable. Local settings are kept. Reconnect to try again.")
            return
        }
        receiveSnapshot()
    }

    func useCloudSettings() {
        guard canChooseCloud, let store = checkedStore() else { return }
        do {
            guard let latest = try readEnvelope(store) else { receiveSnapshot(); return }
            apply(latest)
        } catch { invalidPayload() }
    }

    func useThisMacSettings() {
        guard canChooseLocal else { return }
        // This is the only operation that may intentionally replace a different
        // cloud snapshot, including one still in transit during initial sync.
        publishLocal(overriding: true)
    }

    private func changedExternally(_ notification: Notification) {
        guard checkedStore() != nil,
              let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber else { return }
        switch reason.intValue {
        case NSUbiquitousKeyValueStoreAccountChange:
            suspend("Paused: iCloud account changed", "Reconnect to review the current account's settings. No new settings will be queued until then. macOS may still process earlier writes.")
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            suspend("Paused: iCloud storage limit", "iCloud rejected a key-value store write. Local settings are kept. Resolve the quota problem, then reconnect. Delivery of earlier writes is not confirmed.")
        case NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreServerChange:
            if let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
               !keys.contains(Self.key) { return }
            receiveSnapshot()
        default: break
        }
    }

    private func receiveSnapshot() {
        guard let store = checkedStore(), let preferences = currentPreferences?() else { return }
        do {
            guard let incoming = try readEnvelope(store) else {
                candidate = nil
                setStatus(accepted == nil ? .choosing : .conflict, "No iCloud settings in this cache", "Local settings are kept. Wait for iCloud or choose this Mac's settings to start. This can replace a snapshot that has not arrived yet.")
                return
            }
            // KVS changes and foreground checks can repeat. Never echo an
            // applied revision or treat our own local cache as a delivery ACK.
            if incoming.revision == accepted?.revision {
                guard incoming == accepted else { invalidPayload(); return }
                return
            }
            candidate = incoming
            let local = CoveSyncedSettings(preferences)
            if incoming.settings == local {
                let startingFromCache = accepted == nil
                accepted = incoming
                candidate = nil
                // After restart, an equal cache may be an offline local write
                // from the previous process. Keep it protected from divergent
                // arrivals without inventing a cloud-delivery acknowledgement.
                localRevision = startingFromCache ? incoming.revision : nil
                setStatus(.active, "Settings match the iCloud cache", "Future saved changes sync automatically. Delivery to other devices is not confirmed.")
            } else if accepted == nil {
                setStatus(.choosing, "Choose settings to start", "iCloud and this Mac have different appearance or behavior settings. Choose which snapshot to use. Device access choices stay local.")
            } else if state == .conflict || (localRevision != nil && incoming.parentRevision != accepted?.revision) {
                setStatus(.conflict, "Settings conflict", "Another snapshot arrived after local changes were queued. Automatic writes and incoming changes are paused. Choose iCloud settings or this Mac's current settings.")
            } else {
                apply(incoming)
            }
        } catch { invalidPayload() }
    }

    private func apply(_ incoming: CoveSettingsSyncEnvelope) {
        // All entry points already validated the bounded payload and account.
        applyingRemote = true
        let saved = applySettings?(incoming.settings) == true
        applyingRemote = false
        guard saved else {
            localSaveFailed = true
            suspend("Paused: incoming settings update failed", "The existing settings update path reported a failure. Some settings may apply for this session or have been saved. Check the local settings error, then save successfully before reconnecting.")
            return
        }
        accepted = incoming
        candidate = nil
        localRevision = nil
        setStatus(.active, "Applied iCloud settings on this Mac", "Appearance and behavior settings were saved locally. Future saved changes sync automatically. Delivery to other devices is not confirmed.")
    }

    private func publishLocal(overriding: Bool) {
        guard let store = checkedStore(), let preferences = currentPreferences?() else { return }
        do {
            let latest = try readEnvelope(store)
            let local = CoveSyncedSettings(preferences)
            if let latest, latest.settings == local {
                accepted = latest
                candidate = nil
                localRevision = latest.revision
                setStatus(.active, "Settings match the iCloud cache", "No duplicate write was queued. Delivery to other devices is not confirmed.")
                return
            }
            if !overriding, latest?.revision != accepted?.revision, latest?.settings != local {
                candidate = latest
                setStatus(.conflict, "Settings conflict", "The iCloud cache changed before this save. Local settings are kept. Choose which snapshot to use.")
                return
            }
            let envelope = CoveSettingsSyncEnvelope(settings: local, parentRevision: latest?.revision)
            let data = try envelope.encoded()
            // One bounded atomic value, no history, no timer, no per-save
            // synchronize(). macOS schedules the actual upload.
            store.set(data, forKey: Self.key)
            accepted = envelope
            candidate = nil
            localRevision = envelope.revision
            setStatus(.active, "Local changes queued for iCloud", "macOS controls upload timing. This Mac has not confirmed delivery to another device. Offline changes may be delivered later, even after sync is turned off.")
        } catch { invalidPayload() }
    }

    private func readEnvelope(_ store: NSUbiquitousKeyValueStore) throws -> CoveSettingsSyncEnvelope? {
        guard let object = store.object(forKey: Self.key) else { return nil }
        guard let data = object as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try CoveSettingsSyncEnvelope.decode(data)
    }

    private func checkedStore() -> NSUbiquitousKeyValueStore? {
        guard savedConsent, currentPreferences?()?.syncSettingsWithiCloud == true, let cloud else { return nil }
        guard let token = FileManager.default.ubiquityIdentityToken,
              let accountToken, accountToken.isEqual(token) else {
            suspend("Paused: iCloud account unavailable or changed", "Local settings are kept. Reconnect to review the current account before sending any more settings.")
            return nil
        }
        return cloud
    }

    private func invalidPayload() {
        suspend("Paused: unsupported iCloud settings", "The snapshot has an unsupported version, invalid values, or exceeds 16 KB. Nothing was imported or overwritten. Update OpenCove or resolve the cloud data before reconnecting.")
    }

    private func suspend(_ title: String, _ message: String) {
        detach()
        setStatus(.paused, title, message)
    }

    private func detach() {
        generation = UUID()
        observers.removeAll()
        cloud = nil
        accountToken = nil
        accepted = nil
        candidate = nil
        localRevision = nil
    }

    private func setStatus(_ next: State, _ title: String, _ message: String) {
        state = next
        status = title
        detail = message
    }

    /// Check only this running app's signed capability, never the Keychain or
    /// an account's contents. Do not derive or fabricate a container identifier.
    private static func capabilityFailure() -> String? {
        let unavailable = "This app does not have a usable signed iCloud Key-value storage capability. Use a build with an Apple-provisioned entitlement and matching app identity. Local settings still work."
        guard Bundle.main.bundleURL.pathExtension == "app", let bundleID = Bundle.main.bundleIdentifier,
              let task = SecTaskCreateFromSelf(nil),
              let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) as? String,
              let team = SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
              team.range(of: "\\A[A-Z0-9]{10}\\z", options: .regularExpression) != nil,
              identifier.utf16.count <= 128,
              identifier.range(of: "\\A[A-Z0-9]{10}\\." + NSRegularExpression.escapedPattern(for: bundleID) + "\\z", options: .regularExpression) != nil else { return unavailable }
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode,
              SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { return unavailable }
        return nil
    }
}
