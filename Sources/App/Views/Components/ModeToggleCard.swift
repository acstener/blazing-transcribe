import SwiftUI

struct ModeToggleCard: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.md) {
                // Mode: Always-on / Manual
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Mode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.btSecondaryText)
                        .textCase(.uppercase)

                    VStack(spacing: 6) {
                        HStack(spacing: BTSpacing.sm) {
                            alwaysOnModeOption
                            manualModeOption
                        }

                        ModeToggleHint()
                    }
                }


            }
        }
    }

    private var manualModeSubtitle: String {
        viewModel.transcriptionPreset == .powerUserFastest
            ? "Hold \(viewModel.pttShortcutLabel) for live dictation"
            : "Hold \(viewModel.pttShortcutLabel) to record"
    }
}

// MARK: - Mode Option Button

private struct ModeToggleHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(Color.btBorder)
                .frame(width: 16, height: 1)
            Text("double-tap fn to switch")
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
                    .foregroundStyle(isSelected ? Color.white : Color.btText)
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.accentColor : Color.btActiveBackground)
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
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private extension ModeToggleCard {
    var alwaysOnModeOption: some View {
        ModeOption(
            icon: "waveform",
            title: "Always-on",
            subtitle: "Speak without holding a key",
            isSelected: viewModel.recordingMode == .alwaysOn
        ) {
            viewModel.onSwitchRecordingMode?(.alwaysOn)
        }
    }

    var manualModeOption: some View {
        ModeOption(
            icon: "mic.fill",
            title: "Manual",
            subtitle: manualModeSubtitle,
            isSelected: viewModel.recordingMode == .manual
        ) {
            viewModel.onSwitchRecordingMode?(.manual)
        }
    }

}
