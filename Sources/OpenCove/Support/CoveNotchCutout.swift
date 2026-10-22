// SPDX-License-Identifier: MIT
import CoreGraphics

/// Presentation clearance can grow around a camera, but never replace or
/// shrink its physical geometry. Shared by live and preview views.
enum CoveNotchCutout {
    static func resolve(physical: CGSize, preferences: CovePreferences) -> CGSize {
        let physical = CGSize(width: physical.width.isFinite ? max(0, physical.width) : 0,
                              height: physical.height.isFinite ? max(0, physical.height) : 0)
        guard preferences.simulateNotch else { return physical }
        let width = preferences.notchWidth.isFinite ? min(400, max(120, preferences.notchWidth)) : 190
        let height = preferences.notchHeight.isFinite ? min(64, max(24, preferences.notchHeight)) : 32
        return CGSize(width: max(physical.width, CGFloat(width)), height: max(physical.height, CGFloat(height)))
    }
}
