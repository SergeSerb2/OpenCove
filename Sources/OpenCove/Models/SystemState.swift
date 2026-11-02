import Foundation

struct CoveAudioOutput: Codable, Equatable, Identifiable {
    var id: UInt32
    var name: String
    var uid: String
    var isBluetooth: Bool
}

/// Only values actually reported by a connected accessory are present. A missing
/// component is unknown, not empty or fully charged.
struct CoveAccessoryBattery: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var percentage: Int? = nil
    var leftPercentage: Int? = nil
    var rightPercentage: Int? = nil
    var casePercentage: Int? = nil
}

/// Cached API reporting, not a hardware-support or permission determination.
enum LowPowerModeStatus: String, Codable {
    case disabled, paused, awaitingBaseline, reported, apiUnavailable
}

struct SystemState: Codable, Equatable {
    var volume = 0.0
    var brightness = 0.0
    var isMuted = false
    var batteryPercent = 0
    // Reported IOPowerSources estimate in minutes; nil means unknown or inapplicable.
    var batteryTimeToEmptyMinutes: Int? = nil
    var batteryTimeToFullMinutes: Int? = nil
    var isCharging = false
    var hasBattery = false
    // False also covers unknown/unsupported hardware in the public API.
    // Only .reported carries a value. This state is never a charge estimate.
    var lowPowerModeEnabled: Bool? = nil
    var lowPowerModeStatus: LowPowerModeStatus = .disabled
    var outputDevice = ""
    var bluetoothDevices: [String] = []
    var focusEnabled = false
    var isLocked = false

    // A zero value is not a measurement until the corresponding capability is available.
    var volumeAvailable = false
    var canSetVolume = false
    var muteAvailable = false
    var canSetMute = false
    var brightnessAvailable = false
    var canSetBrightness = false
    var brightnessDisplayName = ""
    var brightnessDisplayID: UInt32?
    var brightnessKeysAvailable = false
    var batteryAvailable = false
    var isOnACPower = false
    var outputDeviceUID = ""
    var outputDeviceID: UInt32?
    var outputDevices: [CoveAudioOutput] = []
    var canSelectOutputDevice = false
    var audioOutputIsBluetooth = false
    var accessoryBatteries: [CoveAccessoryBattery] = []
    // This describes the full Classic Bluetooth list. The active Bluetooth audio route
    // remains visible through CoreAudio even without Bluetooth permission.
    var bluetoothAvailable = false
    var bluetoothAuthorization = "notDetermined"
    var focusAvailable = false
    var focusAuthorization = "notDetermined"
    var lockStateKnown = false
    var capabilityMessages: [String: String] = [:]
}

/// Chooses a device symbol from an accessory's name. Names are user-editable,
/// so this is a best-effort match with a generic fallback.
enum CoveDeviceSymbol {
    static func symbol(forName name: String, fallback: String) -> String {
        let text = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("airpods max") { return "airpodsmax" }
        if has("airpods pro") { return "airpodspro" }
        if has("airpods") { return "airpods" }
        if has("powerbeats") { return "beats.powerbeatspro" }
        if has("studio buds", "beats fit", "beats flex", "solo buds") { return "beats.earphones" }
        if has("beats") { return "beats.headphones" }
        if has("homepod") { return "homepod.fill" }
        if has("keyboard") { return "keyboard" }
        if has("magic mouse") { return "magicmouse.fill" }
        if has("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if has("mouse", "mx master", "mx anywhere") { return "computermouse.fill" }
        if has("controller", "dualsense", "dualshock", "xbox", "gamepad", "joy-con") { return "gamecontroller.fill" }
        if has("pencil") { return "applepencil" }
        if has("speaker", "soundlink", "boom", "sonos", "jbl") { return "hifispeaker.fill" }
        if has("buds", "earbuds", "wf-", "earphone") { return "earbuds" }
        if has("headphone", "wh-", "bose qc", "quietcomfort", "headset") { return "headphones" }
        return fallback
    }
}

extension CoveAccessoryBattery {
    /// The lowest known charge, for a short summary such as "AirPods · 80%".
    var summaryPercentage: Int? {
        [percentage, leftPercentage, rightPercentage].compactMap { $0 }.min()
    }

    /// "L 80% · R 82% · Case 45%" for earbuds, or "80%" for a single battery.
    var detailText: String? {
        let parts = [("L", leftPercentage), ("R", rightPercentage), ("Case", casePercentage)]
            .compactMap { label, value in value.map { "\(label) \($0)%" } }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return percentage.map { "\($0)%" }
    }
}
