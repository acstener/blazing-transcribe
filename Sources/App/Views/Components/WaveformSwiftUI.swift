import SwiftUI

/// Adaptive timeline schedule that runs at target fps when active, 1fps when idle.
struct AdaptiveWaveformSchedule: TimelineSchedule {
    let isActive: Bool
    let fps: Double

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let interval: TimeInterval = isActive ? (1.0 / fps) : 1.0
        var next = startDate
        return AnyIterator {
            let current = next
            next = current.addingTimeInterval(interval)
            return current
        }
    }
}

struct WaveformSwiftUI: View {
    let audioLevel: Float
    private let barCount = 5

    var body: some View {
        TimelineView(AdaptiveWaveformSchedule(isActive: audioLevel > 0.01, fps: 30)) { timeline in
            Canvas { context, size in
                let barWidth: CGFloat = 6
                let spacing: CGFloat = 4
                let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let maxHeight = size.height * 0.8
                let minHeight: CGFloat = 4

                let level = CGFloat(max(0, min(1, audioLevel)))
                let time = timeline.date.timeIntervalSinceReferenceDate

                for i in 0..<barCount {
                    let phase = sin(time * 4 + Double(i) * 0.8)
                    let heightFactor = level * (0.5 + 0.5 * CGFloat(phase))
                    let barHeight = max(minHeight, maxHeight * heightFactor)

                    let x = startX + CGFloat(i) * (barWidth + spacing)
                    let y = (size.height - barHeight) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(Color.btText.opacity(0.3 + 0.7 * Double(heightFactor))))
                }
            }
        }
    }
}
