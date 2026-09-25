import SwiftUI

struct ModeToggleCard: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.sm) {
                Text("Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                    .textCase(.uppercase)

                BTSegmentedControl(
                    segments: [
                        .init(value: RecordingMode.alwaysOn, title: "Always-on", icon: "waveform"),
                        .init(value: RecordingMode.manual, title: "Manual", icon: "mic.fill"),
                    ],
                    selection: viewModel.recordingMode
                ) { mode in
                    viewModel.onSwitchRecordingMode?(mode)
                }

                // Explains the selected mode; crossfades when the mode changes.
                ZStack(alignment: .topLeading) {
                    Text(subtitle(for: viewModel.recordingMode))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(viewModel.recordingMode)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: viewModel.recordingMode)

                ModeToggleHint()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func subtitle(for mode: RecordingMode) -> String {
        switch mode {
        case .alwaysOn:
            return "Speak without holding a key. Dictation ends when you pause."
        case .manual:
            return viewModel.transcriptionPreset == .powerUserFastest
                ? "Hold \(viewModel.pttShortcutLabel) for live dictation."
                : "Hold \(viewModel.pttShortcutLabel) to record, release to transcribe."
        }
    }
}

// MARK: - Mode Option Button

private struct ModeToggleHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(Color.btBorder)
                .frame(width: 16, height: 1)
            Text(ShortcutConfig.shared.modeToggleShortcut.map { "\($0.displayString) to switch" } ?? "double-tap fn to switch")
                .font(.system(size: 10))
                .foregroundStyle(Color.btSecondaryText.opacity(0.45))
            Rectangle()
                .fill(Color.btBorder)
                .frame(width: 16, height: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ModeOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.btAccentForeground : Color.btText)
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.btAccent : Color.btActiveBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.btSecondaryText)
                }

                Spacer()
            }
            .padding(BTSpacing.sm)
            .background(isSelected ? Color.btActiveBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                    .strokeBorder(isSelected ? Color.btAccent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
