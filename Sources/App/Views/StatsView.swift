import SwiftUI

/// The numbers the Usage page shows, captured together so they can count up and animate as one.
struct UsageSnapshot: Equatable {
    var words: Double = 0
    var dictations: Double = 0
    var timeSavedVsTyping: Double = 0
    var speechSeconds: Double = 0
    var cleanupFixes: Double = 0
    var pages: Double = 0
    var speakingWPM: Double = 0
    var avgTranscriptionTime: Double = 0
    var keypressesSaved: Double = 0
    var timeSavedVsCloud: Double = 0
    var milestoneWords: Double = 0

    static let zero = UsageSnapshot()

    init() {}

    init(_ stats: UsageStats) {
        words = Double(stats.totalWords)
        dictations = Double(stats.totalUtterances)
        timeSavedVsTyping = stats.timeSavedVsTyping
        speechSeconds = stats.totalSpeechSeconds
        cleanupFixes = Double(stats.totalCleanupFixes)
        pages = stats.pagesOfText
        speakingWPM = stats.speakingWPM
        avgTranscriptionTime = stats.avgTranscriptionTime
        keypressesSaved = Double(stats.keypressesSaved)
        timeSavedVsCloud = stats.timeSavedVsShortcutTools
        milestoneWords = Double(stats.currentMilestone?.words ?? 0)
    }

    /// Values keyed for "changed since last visit" comparisons.
    var comparable: [String: Double] {
        [
            "words": words, "dictations": dictations, "timeSavedVsTyping": timeSavedVsTyping,
            "speechSeconds": speechSeconds, "cleanupFixes": cleanupFixes, "pages": pages,
            "milestone": milestoneWords
        ]
    }

    /// Keys whose value differs from `previous`. Nothing flashes on a first-ever visit.
    func changedKeys(since previous: [String: Double]) -> Set<String> {
        guard !previous.isEmpty else { return [] }
        return Set(comparable.compactMap { key, value in
            guard let old = previous[key] else { return nil }
            return abs(old - value) > 0.0001 ? key : nil
        })
    }
}

struct StatsView: View {
    /// Count-up runs on the first visit per app session only; later visits show values directly.
    private static var hasCountedUpThisSession = false
    private static let countUpDuration = 0.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayed: UsageSnapshot
    @State private var changed: Set<String> = []
    @State private var showResetConfirmation = false

    private var stats: UsageStats { UsageStats.shared }
    private var hasData: Bool { stats.totalUtterances > 0 || stats.totalWords > 0 }
    private var dash: String { "\u{2014}" }

    init() {
        _displayed = State(initialValue: Self.hasCountedUpThisSession ? UsageSnapshot(UsageStats.shared) : .zero)
    }

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
                        value: hasData ? formattedNumber(displayed.words) : dash,
                        icon: "text.word.spacing",
                        flash: changed.contains("words"),
                        flashDelay: flashDelay
                    )
                    StatCard(
                        title: "Dictations",
                        value: hasData ? formattedNumber(displayed.dictations) : dash,
                        icon: "waveform",
                        flash: changed.contains("dictations"),
                        flashDelay: flashDelay
                    )
                    StatCard(
                        title: "Time saved vs typing",
                        value: hasData && stats.timeSavedVsTyping > 0
                            ? UsageStats.formatDuration(displayed.timeSavedVsTyping)
                            : dash,
                        icon: "clock.arrow.circlepath",
                        flash: changed.contains("timeSavedVsTyping"),
                        flashDelay: flashDelay
                    )
                    StatCard(
                        title: "Time speaking",
                        value: hasData ? UsageStats.formatDuration(displayed.speechSeconds) : dash,
                        icon: "mic",
                        flash: changed.contains("speechSeconds"),
                        flashDelay: flashDelay
                    )
                    StatCard(
                        title: "Fixes made by cleanup",
                        value: stats.totalCleanupFixes > 0 ? formattedNumber(displayed.cleanupFixes) : dash,
                        icon: "wand.and.stars",
                        flash: changed.contains("cleanupFixes"),
                        flashDelay: flashDelay
                    )
                    StatCard(
                        title: "Pages of text",
                        value: hasData ? String(format: "%.1f", displayed.pages) : dash,
                        icon: "doc.text",
                        flash: changed.contains("pages"),
                        flashDelay: flashDelay
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
                                    ? "~\(Int(displayed.speakingWPM)) wpm"
                                    : dash
                            )
                            statRow(
                                label: "Avg transcription time",
                                value: hasData && stats.avgTranscriptionTime > 0
                                    ? "\(Int(displayed.avgTranscriptionTime * 1000)) ms"
                                    : dash
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                LazyVGrid(columns: statCardColumns, alignment: .leading, spacing: BTSpacing.md) {
                    milestonesCard

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            Text("Compared to alternatives")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.btText)

                            statRow(
                                label: "Keypresses saved vs push-to-talk tools",
                                value: hasData ? formattedNumber(displayed.keypressesSaved) : dash
                            )
                            statRow(
                                label: "Time saved vs cloud processing",
                                value: hasData && stats.timeSavedVsShortcutTools > 0
                                    ? UsageStats.formatDuration(displayed.timeSavedVsCloud)
                                    : dash
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Reset: quiet, and guarded — it can't be undone. Hold to confirm; VoiceOver and
                // Reduce Motion users get the confirmation dialog instead.
                HStack {
                    Spacer()
                    BTHoldToConfirmButton("Hold to reset") {
                        showResetConfirmation = true
                    } action: {
                        resetStats()
                    }
                    .disabled(!hasData)
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
        .confirmationDialog("Reset all usage stats?", isPresented: $showResetConfirmation) {
            Button("Reset stats", role: .destructive) {
                resetStats()
            }
        } message: {
            Text("Word counts, time saved and milestones go back to zero. Your history is kept.")
        }
        .onAppear(perform: appear)
        .onDisappear {
            stats.setLastViewedValues(UsageSnapshot(stats).comparable)
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageStatsDidChange)) { _ in
            withAnimation(reduceMotion ? nil : .btSoft) {
                displayed = UsageSnapshot(stats)
            }
        }
    }

    // MARK: - Milestones

    private var milestonesCard: some View {
        let words = stats.totalWords
        let remaining = UsageMilestone.remainingText(forWords: words)
        let progress = UsageMilestone.progress(forWords: Int(displayed.words))

        return BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.md) {
                Text("Milestones")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.btText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasData ? "That's \(stats.funEquivalent)" : dash)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.btText)
                        .usageChangeFlash(changed.contains("milestone"), delay: flashDelay)
                    Text("Equivalent text")
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                }

                if let remaining {
                    VStack(alignment: .leading, spacing: 6) {
                        MilestoneProgressBar(progress: progress)
                        Text(remaining)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(Int(progress * 100)) percent")
                } else {
                    Text("Every milestone passed.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                }

                statRow(
                    label: "Tracking since",
                    value: trackingSinceText
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Lifecycle

    /// Flashes wait for the count-up to land so the eye isn't pulled two ways at once.
    private var flashDelay: Double { reduceMotion ? 0.1 : Self.countUpDuration + 0.1 }

    private func appear() {
        let current = UsageSnapshot(stats)
        changed = current.changedKeys(since: stats.lastViewedValues)
        stats.setLastViewedValues(current.comparable)

        guard !Self.hasCountedUpThisSession, !reduceMotion, hasData else {
            Self.hasCountedUpThisSession = true
            displayed = current
            return
        }
        Self.hasCountedUpThisSession = true
        displayed = .zero
        // Next runloop, so the zero state renders before the animated change to real values.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: Self.countUpDuration)) {
                displayed = current
            }
        }
    }

    private func resetStats() {
        stats.reset()
        changed = []
        withAnimation(reduceMotion ? nil : .btSoft) {
            displayed = UsageSnapshot(stats)
        }
    }

    // MARK: - Helpers

    private func statRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.btText)
                .contentTransition(.numericText())
            Text(label)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
        }
    }

    private var trackingSinceText: String {
        guard let firstUseDate = stats.firstUseDate else { return dash }
        return Self.dateFormatter.string(from: firstUseDate)
    }

    private func formattedNumber(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return Self.numberFormatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}

/// Thin monochrome progress track towards the next milestone.
private struct MilestoneProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.btActiveBackground)
                Capsule()
                    .fill(Color.btAccent)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
