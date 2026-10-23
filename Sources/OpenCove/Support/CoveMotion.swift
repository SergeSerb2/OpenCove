// SPDX-License-Identifier: MIT
import QuartzCore
import SwiftUI

/// One timing policy for the native window and its SwiftUI content. Both can
/// retarget an in-flight transition; reduced motion is resolved by each owner.
enum CoveMotion {
    // Reading speed and rest time, independent of panel transition speed.
    static let mediaTextPointsPerSecond = 26.0
    static let mediaTextPause = 1.6

    // Keep the existing decorative bar range/rates. This is independent of
    // panel transition speed and is never presented as a measured waveform.
    static let audioBarRestHeights = [7.0, 13, 18, 11, 6]
    static func audioBarPeriod(index: Int) -> Double { 2 * .pi / (3.4 + Double(index) * 0.45) }

    static func duration(preferences: CovePreferences, hud: Bool, kind: HUDKind? = nil) -> Double {
        let speed = preferences.speed(for: kind)
        let base: Double = hud && speed == "instant" ? 0
            : hud && speed == "fast" ? 0.12 : 0.22
        return base / min(2, max(0.25, preferences.animationSpeed))
    }

    static func animation(preferences: CovePreferences, hud: Bool, kind: HUDKind? = nil) -> Animation? {
        let seconds = duration(preferences: preferences, hud: hud, kind: kind)
        return seconds > 0 ? .timingCurve(0.32, 0.72, 0, 1, duration: seconds) : nil
    }

    static func contentAnimation(preferences: CovePreferences, hud: Bool, entering: Bool, kind: HUDKind? = nil) -> Animation? {
        let seconds = duration(preferences: preferences, hud: hud, kind: kind)
        guard seconds > 0 else { return nil }
        // Let the viewport open before revealing fixed-size controls. Departing
        // controls clear sooner, rather than lingering over the next activity.
        let fade = min(seconds, 0.12 / min(2, max(0.25, preferences.animationSpeed)))
        return .timingCurve(0.23, 1, 0.32, 1, duration: fade)
            .delay(entering ? seconds - fade : 0)
    }

    // A drawer curve gives the native morph a gentler first frame without
    // extending its duration or introducing spring overshoot at the screen edge.
    static let timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
}
