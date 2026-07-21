import SwiftUI

struct OverlayWaveformMetrics {
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let barBaseHeight: CGFloat
    let amplitudeBase: CGFloat
    let amplitudeVariance: CGFloat
    let height: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    var totalWidth: CGFloat {
        CGFloat(OverlayWaveformLayout.barCount) * barWidth
            + CGFloat(OverlayWaveformLayout.barCount - 1) * barSpacing
    }
}

enum OverlayWaveformLayout {
    static let barCount = 16

    static func metrics(for visualStyle: OverlayVisualStyle) -> OverlayWaveformMetrics {
        switch visualStyle {
        case .glass:
            return OverlayWaveformMetrics(
                barWidth: 4,
                barSpacing: 3,
                barBaseHeight: 5,
                amplitudeBase: 3.8,
                amplitudeVariance: 1.0,
                height: 26,
                horizontalPadding: 4,
                verticalPadding: 2
            )
        case .black:
            return OverlayWaveformMetrics(
                barWidth: 3,
                barSpacing: 3,
                barBaseHeight: 4.5,
                amplitudeBase: 3.2,
                amplitudeVariance: 0.8,
                height: 22,
                horizontalPadding: 12,
                verticalPadding: 3
            )
        }
    }
}

/// Animated waveform for the recording pill.
/// Renders directly from the latest mic level to minimize visible lag.
struct OverlayWaveformView: View {
    let viewModel: OverlayViewModel
    let visualStyle: OverlayVisualStyle

    var body: some View {
        // The waveform only renders during active recording, so keep it on a
        // steady 60fps schedule instead of re-smoothing inside the draw pass.
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                drawBars(context: context, size: size, date: timeline.date)
            }
        }
    }

    private func drawBars(context: GraphicsContext, size: CGSize, date: Date) {
        let metrics = OverlayWaveformLayout.metrics(for: visualStyle)
        let level = CGFloat(max(0, min(1, viewModel.smoothedAudioLevel)))
        let barColor: Color
        if visualStyle == .black {
            barColor = Color.white.opacity(0.96)
        } else if #available(macOS 26.0, *) {
            barColor = viewModel.colorScheme == .dark
                ? Color.white
                : Color.black.opacity(0.82)
        } else {
            barColor = Color.overlayText
        }

        let totalWidth = metrics.totalWidth
        let startX: CGFloat = (size.width - totalWidth) / 2
        let time: Double = date.timeIntervalSinceReferenceDate

        for i in 0..<OverlayWaveformLayout.barCount {
            // Slow staggered sine — relaxed breathing motion
            let freq: Double = 0.8 + Double(i % 5) * 0.15
            let phase: Double = sin(time * freq + Double(i) * 0.6)

            // Moderate amplitude: bars grow ~3–5x when speaking
            let scaleY: CGFloat = 1.0 + level * (metrics.amplitudeBase + CGFloat(phase) * metrics.amplitudeVariance)
            let barHeight: CGFloat = min(metrics.barBaseHeight * scaleY, size.height)

            let x: CGFloat = startX + CGFloat(i) * (metrics.barWidth + metrics.barSpacing)
            let y: CGFloat = (size.height - barHeight) / 2

            let rect = CGRect(x: x, y: y, width: metrics.barWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: metrics.barWidth / 2)

            // Gentle opacity: always visible base, subtle bloom when active
            let opacity: Double = 0.4 + 0.5 * Double(level) * (phase * 0.5 + 0.75)
            context.fill(path, with: .color(barColor.opacity(opacity)))
        }
    }
}
