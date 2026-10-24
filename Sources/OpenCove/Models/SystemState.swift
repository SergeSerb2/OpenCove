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

struct SystemState: Codable, Equatable {
    var volume = 0.0
    var brightness = 0.0
    var isMuted = false
    var batteryPercent = 0
    // Reported IOPowerSources estimate in minutes; nil means unknown or inapplicable.
    var batteryTimeToEmptyMinutes: Int? = nil
    var isCharging = false
    var hasBattery = false
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
