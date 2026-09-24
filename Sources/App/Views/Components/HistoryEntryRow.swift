import SwiftUI

struct HistoryEntryRow: View {
    let entry: TranscriptionRecord
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void
    let onRecover: () -> Void
    let onDelete: () -> Void
    let onDownloadAudio: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showCopiedTooltip = false
    @State private var isShowingDiff = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rough character threshold for "long" entries that should be truncated.
    private static let truncationThreshold = 120

    private func isLongEntry(diff: WordDiff?) -> Bool {
        guard entry.succeeded else { return false }
        if isShowingDiff, let diff {
            let diffLength = diff.segments.reduce(0) { $0 + $1.text.count + 1 }
            return diffLength > Self.truncationThreshold
        }
        return entry.text.count > Self.truncationThreshold
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(timeString)
                .font(.system(size: 11))
                .foregroundStyle(Color.btSecondaryText)
                .frame(width: 60, alignment: .leading)
                .padding(.top, 2)
            contentView.frame(maxWidth: .infinity, alignment: .leading)
            actionButtons
        }
        .padding(.horizontal, BTSpacing.md)
        .padding(.vertical, BTSpacing.sm + 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .background(isHovered ? Color.btCardHover : Color.clear)
        .overlay(alignment: .bottom) {
            if showCopiedTooltip {
                Text("Copied to clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .retryCopiedToClipboard)) { notification in
            guard let id = notification.object as? UUID, id == entry.id else { return }
            withAnimation(.btSnappy) { showCopiedTooltip = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.btSoft) { showCopiedTooltip = false }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if entry.dismissed {
            HStack(spacing: BTSpacing.sm) {
                Text("Dismissed")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.btSecondaryText)

                Button("Recover") { onRecover() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.btText)
                    .underline()
                    .buttonStyle(.plain)
            }
        } else if entry.succeeded {
            if entry.text.rangeOfCharacter(from: .alphanumerics) == nil {
                Text("No words transcribed")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.btSecondaryText.opacity(0.5))
                    .italic()
            } else {
                let diff = entry.cleanupDiff
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if isShowingDiff, let diff {
                            Text(Self.attributedDiff(diff))
                                .transition(.opacity)
                        } else {
                            Text(entry.text)
                                .transition(.opacity)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color.btText)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)

                    if isLongEntry(diff: diff) {
                        Button {
                            withAnimation(.btSpring) { isExpanded.toggle() }
                        } label: {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }

                    if let diff {
                        cleanupChip(fixCount: diff.fixCount)
                    }
                }
            }
        } else {
            HStack(spacing: BTSpacing.sm) {
                // Empty/short captures are usually accidental taps, not errors — keep them quiet.
                if !isBenignFailure {
                    Circle()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
                Text(failureText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.btSecondaryText)
                    .italic(isBenignFailure)

                if entry.audioFileName != nil {
                    Button("Retry") { onRetry() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                        .underline()
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !entry.dismissed {
            HStack(spacing: BTSpacing.xs) {
                if entry.succeeded && !entry.text.isEmpty {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.btSecondaryText.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(isHovered ? Color.btActiveBackground.opacity(0.6) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }

                Menu {
                    if entry.succeeded {
                        Button(action: onDismiss) {
                            Label("Dismiss", systemImage: "flag")
                        }
                    }
                    if entry.audioFileName != nil {
                        Button(action: onRetry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    if entry.audioFileName != nil {
                        Divider()
                        Button(action: onDownloadAudio) {
                            Label("Download audio", systemImage: "arrow.down.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.btSecondaryText.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(isHovered ? Color.btActiveBackground.opacity(0.6) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
            .opacity(isHovered ? 1 : 0)
        }
    }

    // MARK: - Cleanup diff

    private func cleanupChip(fixCount: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .btSpring) {
                isShowingDiff.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isShowingDiff ? "eye.slash" : "wand.and.stars")
                    .font(.system(size: 9, weight: .medium))
                Text(cleanupChipLabel(fixCount: fixCount))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.btSecondaryText.opacity(isShowingDiff ? 0.9 : 0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.btActiveBackground.opacity(isShowingDiff ? 0.9 : 0.5))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help(isShowingDiff ? "Show cleaned text" : "Show what cleanup changed")
        .accessibilityLabel(cleanupChipLabel(fixCount: fixCount))
        .accessibilityHint(isShowingDiff ? "Shows the cleaned text" : "Shows what cleanup changed")
    }

    private func cleanupChipLabel(fixCount: Int) -> String {
        let name = entry.cleanupKind == .llm ? "LLM Cleanup" : "Cleaned"
        return "\(name) · \(fixCount) \(fixCount == 1 ? "fix" : "fixes")"
    }

    /// Inline diff: removed words struck through at 45% opacity, inserted words on an Ember tint.
    static func attributedDiff(_ diff: WordDiff) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in diff.segments.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .unchanged:
                break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = Color.btText.opacity(0.45)
            case .inserted:
                piece.backgroundColor = Color.btEmber.opacity(0.15)
            }
            result += piece
        }
        return result
    }

    // MARK: - Computed

    private var isBenignFailure: Bool {
        guard let message = entry.errorMessage else { return false }
        return message == "No speech detected" || message == "Audio too short to transcribe"
    }

    private var failureText: String {
        guard let message = entry.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return "Couldn’t transcribe" }
        return isBenignFailure ? message : "Couldn’t transcribe · \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: entry.timestamp).lowercased()
    }
}
