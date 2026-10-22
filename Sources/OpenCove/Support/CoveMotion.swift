// SPDX-License-Identifier: MIT
import QuartzCore
import SwiftUI

/// One timing policy for the native window and its SwiftUI content. Both can
/// retarget an in-flight transition; reduced motion is resolved by each owner.
enum CoveMotion {
    static func duration(preferences: CovePreferences, hud: Bool) -> Double {
        let base: Double = hud && preferences.hudSpeed == "instant" ? 0
            : hud && preferences.hudSpeed == "fast" ? 0.12 : 0.22
        return base / min(2, max(0.25, preferences.animationSpeed))
    }

    static func animation(preferences: CovePreferences, hud: Bool) -> Animation? {
        let seconds = duration(preferences: preferences, hud: hud)
        return seconds > 0 ? .timingCurve(0.23, 1, 0.32, 1, duration: seconds) : nil
    }

    static let timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
}
