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

    /// Rough character threshold for "long" entries that should be truncated.
    private static let truncationThreshold = 120

    private var isLongEntry: Bool {
        entry.succeeded && entry.text.count > Self.truncationThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Timestamp row — always at the top
            HStack(alignment: .center, spacing: BTSpacing.sm) {
                Text(timeString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.btSecondaryText.opacity(0.6))

                Spacer(minLength: BTSpacing.sm)

                actionButtons
            }
            .padding(.bottom, 4)

            // Content
            contentView
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
            if entry.text.isEmpty {
                Text("Empty transcription")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.btSecondaryText.opacity(0.5))
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.btText)
                        .lineLimit(isExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)

                    if isLongEntry {
                        Button {
                            withAnimation(.btSpring) { isExpanded.toggle() }
                        } label: {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            HStack(spacing: BTSpacing.sm) {
                Circle()
                    .fill(Color.red.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("Failed")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.btSecondaryText)

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

    // MARK: - Computed

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: entry.timestamp).lowercased()
    }
}
