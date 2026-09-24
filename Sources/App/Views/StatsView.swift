import SwiftUI

struct StatsView: View {
    @State private var refreshTrigger = false
    @State private var showResetConfirmation = false

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
        // Flexible columns so cards always fill the content width (no half-empty rows).
        let statCardColumns = [
            GridItem(.flexible(), spacing: BTSpacing.md, alignment: .top),
            GridItem(.flexible(), spacing: BTSpacing.md, alignment: .top)
        ]
        let performanceColumns = [
            GridItem(.adaptive(minimum: 150), spacing: BTSpacing.md, alignment: .top)
        ]

        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Usage")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                // Big stat cards
                LazyVGrid(columns: statCardColumns, alignment: .leading, spacing: BTSpacing.md) {
                    StatCard(
                        title: "Total words",
                        value: hasData ? formattedNumber(stats.totalWords) : dash,
                        icon: "text.word.spacing"
                    )
                    StatCard(
                        title: "Dictations",
                        value: hasData ? formattedNumber(stats.totalUtterances) : dash,
                        icon: "waveform"
                    )
                    StatCard(
                        title: "Time saved vs typing",
                        value: hasData && stats.timeSavedVsTyping > 0
                            ? UsageStats.formatDuration(stats.timeSavedVsTyping)
                            : dash,
                        icon: "clock.arrow.circlepath"
                    )
                    StatCard(
                        title: "Time speaking",
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
                                label: "Speaking rate",
                                value: hasData && stats.speakingWPM > 0
                                    ? "~\(Int(stats.speakingWPM)) wpm"
                                    : dash
                            )
                            statRow(
                                label: "Avg transcription time",
                                value: hasData && stats.avgTranscriptionTime > 0
                                    ? "\(Int(stats.avgTranscriptionTime * 1000)) ms"
                                    : dash
                            )
                            statRow(
                                label: "Pages of text",
                                value: hasData ? String(format: "%.1f", stats.pagesOfText) : dash
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                LazyVGrid(columns: statCardColumns, alignment: .leading, spacing: BTSpacing.md) {
                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            Text("Milestones")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.btText)

                            statRow(
                                label: "Equivalent text",
                                value: hasData ? "That's \(stats.funEquivalent)" : dash
                            )
                            statRow(
                                label: "Tracking since",
                                value: trackingSinceText
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            Text("Compared to alternatives")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.btText)

                            statRow(
                                label: "Keypresses saved vs push-to-talk tools",
                                value: hasData ? formattedNumber(stats.keypressesSaved) : dash
                            )
                            statRow(
                                label: "Time saved vs cloud processing",
                                value: hasData && stats.timeSavedVsShortcutTools > 0
                                    ? UsageStats.formatDuration(stats.timeSavedVsShortcutTools)
                                    : dash
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Reset: quiet, and always confirmed — it can't be undone.
                HStack {
                    Spacer()
                    BTButton("Reset stats…", style: .secondary) {
                        showResetConfirmation = true
                    }
                    .disabled(!hasData)
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
            .id(refreshTrigger)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
        .confirmationDialog("Reset all usage stats?", isPresented: $showResetConfirmation) {
            Button("Reset stats", role: .destructive) {
                stats.reset()
                refreshTrigger.toggle()
            }
        } message: {
            Text("Word counts, time saved and milestones go back to zero. Your history is kept.")
        }
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
