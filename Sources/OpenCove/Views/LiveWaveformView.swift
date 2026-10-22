// SPDX-License-Identifier: MIT
import SwiftUI

/// Displays measured RMS time bins only. This view never starts capture or asks
/// for permission; the store owns lifecycle and an explicit settings action
/// owns consent. An unavailable meter is a quiet, static row of equal bars.
struct LiveWaveformView: View {
    @ObservedObject var controller: AudioWaveformController
    var isPlaying: Bool
    var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<8) { index in
                Capsule()
                    .fill(color.opacity(controller.available ? 0.95 : 0.4))
                    .frame(width: 2, height: height(at: index))
            }
        }
        .frame(width: 28, height: 20)
        // No timer, sine animation, or playback-derived amplitude is used.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.available ? "System audio levels" : (isPlaying ? "Playing" : "Paused"))
        .accessibilityValue(controller.status)
        .help(controller.lastError ?? controller.status)
    }

    private func height(at index: Int) -> CGFloat {
        guard controller.available, controller.levels.indices.contains(index) else { return 2 }
        let value = controller.levels[index]
        let level = value.isFinite ? min(1, max(0, value)) : 0
        return 2 + CGFloat(level) * 16
    }
}
