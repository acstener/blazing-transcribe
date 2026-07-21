import SwiftUI

struct StatsView: View {
    @State private var refreshTrigger = false

    private var stats: UsageStats { UsageStats.shared }
    private var hasData: Bool { stats.totalUtterances > 0 || stats.totalWords > 0 }
    private var dash: String { "\u{2014}" }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        let statCardColumns = [
            GridItem(.adaptive(minimum: 220, maximum: 320), spacing: BTSpacing.md, alignment: .top)
        ]
        let performanceColumns = [
            GridItem(.adaptive(minimum: 150, maximum: 240), spacing: BTSpacing.md, alignment: .top)
        ]

        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Stats")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                // Big stat cards
                LazyVGrid(columns: statCardColumns, alignment: .leading, spacing: BTSpacing.md) {
                    StatCard(
                        title: "Total Words",
                        value: hasData ? formattedNumber(stats.totalWords) : dash,
                        icon: "text.word.spacing"
                    )
                    StatCard(
                        title: "Utterances",
                        value: hasData ? formattedNumber(stats.totalUtterances) : dash,
                        icon: "waveform"
                    )
                }

                LazyVGrid(columns: statCardColumns, alignment: .leading, spacing: BTSpacing.md) {
                    StatCard(
                        title: "Time Saved vs Typing",
                        value: hasData && stats.timeSavedVsTyping > 0
                            ? UsageStats.formatDuration(stats.timeSavedVsTyping)
                            : dash,
                        icon: "clock.arrow.circlepath"
                    )
                    StatCard(
                        title: "Total Time Speaking",
                        value: hasData ? UsageStats.formatDuration(stats.totalSpeechSeconds) : dash,
                        icon: "mic"
                    )
                }

                // Speed & efficiency
                BTCard {
                    VStack(alignment: .leading, spacing: BTSpacing.md) {
                        Text("Performance")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.btText)

                        LazyVGrid(columns: performanceColumns, alignment: .leading, spacing: BTSpacing.md) {
                            statRow(
                                label: "Speaking Rate",
                                value: hasData && stats.speakingWPM > 0
                                    ? "~\(Int(stats.speakingWPM)) WPM"
                                    : dash
                            )
                            statRow(
                                label: "Avg Transcription",
                                value: hasData && stats.avgTranscriptionTime > 0
                                    ? "\(Int(stats.avgTranscriptionTime * 1000))ms per utterance"
                                    : dash
                            )
                            statRow(
                                label: "Pages of Text",
                                value: hasData ? String(format: "%.1f pages", stats.pagesOfText) : dash
                            )
                        }
                    }
                }

                BTCard {
                    VStack(alignment: .leading, spacing: BTSpacing.md) {
                        Text("Tracking")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.btText)

                        statRow(
                            label: "Equivalent Text",
                            value: hasData ? "That's \(stats.funEquivalent)" : dash
                        )
                        statRow(
                            label: "Tracking Since",
                            value: trackingSinceText
                        )
                    }
                }

                // Comparisons
                BTCard {
                    VStack(alignment: .leading, spacing: BTSpacing.md) {
                        Text("Compared to Alternatives")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.btText)

                        statRow(
                            label: "Keypresses saved vs PTT tools",
                            value: hasData ? formattedNumber(stats.keypressesSaved) : dash
                        )
                        statRow(
                            label: "Time saved vs cloud processing",
                            value: hasData && stats.timeSavedVsShortcutTools > 0
                                ? UsageStats.formatDuration(stats.timeSavedVsShortcutTools)
                                : dash
                        )
                    }
                }

                // Reset
                HStack {
                    Spacer()
                    BTButton("Reset Stats", style: .destructive) {
                        stats.reset()
                        refreshTrigger.toggle()
                    }
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
            .id(refreshTrigger)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .usageStatsDidChange)) { _ in
            refreshTrigger.toggle()
        }
    }

    private func statRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.btText)
            Text(label)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
        }
    }

    private var trackingSinceText: String {
        guard let firstUseDate = stats.firstUseDate else { return dash }
        return Self.dateFormatter.string(from: firstUseDate)
    }

    private func formattedNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
