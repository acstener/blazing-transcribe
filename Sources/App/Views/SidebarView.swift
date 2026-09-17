import SwiftUI

struct SidebarView: View {
    @Environment(TabSelection.self) private var selection
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 0) {
            // Header — custom title bar area
            HStack(spacing: BTSpacing.sm) {
                // Leave room for traffic light buttons
                Color.clear.frame(width: 60, height: 1)
                Spacer()
            }
            .frame(height: 52)

            HStack(spacing: BTSpacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.btText)
                Text("Blazing Transcribe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.btText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
            }
            .padding(.horizontal, BTSpacing.md)
            .padding(.bottom, BTSpacing.md)

            // Navigation items
            VStack(spacing: 2) {
                BTSidebarItem(
                    title: "Dashboard",
                    icon: "square.grid.2x2",
                    isSelected: selection.current == .dashboard,
                    namespace: namespace
                ) { selection.current = .dashboard }

                BTSidebarItem(
                    title: "History",
                    icon: "clock.arrow.circlepath",
                    isSelected: selection.current == .history,
                    namespace: namespace
                ) { selection.current = .history }

                BTSidebarItem(
                    title: "Dictionary",
                    icon: "book.closed",
                    isSelected: selection.current == .dictionary,
                    namespace: namespace
                ) { selection.current = .dictionary }

                BTSidebarItem(
                    title: "Shortcuts",
                    icon: "keyboard",
                    isSelected: selection.current == .shortcuts,
                    namespace: namespace
                ) { selection.current = .shortcuts }

                BTSidebarItem(
                    title: "Audio",
                    icon: "speaker.wave.2",
                    isSelected: selection.current == .audio,
                    namespace: namespace
                ) { selection.current = .audio }

                BTSidebarItem(
                    title: "Settings",
                    icon: "gearshape",
                    isSelected: selection.current == .general,
                    namespace: namespace
                ) { selection.current = .general }

                Divider()
                    .padding(.vertical, BTSpacing.sm)
                    .padding(.horizontal, BTSpacing.md)

                BTSidebarItem(
                    title: "Stats",
                    icon: "chart.bar",
                    isSelected: selection.current == .stats,
                    namespace: namespace
                ) { selection.current = .stats }
            }
            .padding(.horizontal, BTSpacing.sm)

            Spacer()

            // Bottom quick toggle intentionally hidden to keep the sidebar quieter for now.
            // ModeQuickToggle()
            //     .padding(BTSpacing.md)
        }
        .background(Color.btBackground)
    }
}

// MARK: - Mode Quick Toggle

struct ModeQuickToggle: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(title: "Always-on", mode: .alwaysOn)
            toggleButton(title: "Manual", mode: .manual)
        }
        .background(Color.btActiveBackground)
        .clipShape(Capsule())
    }

    private func toggleButton(title: String, mode: RecordingMode) -> some View {
        Button {
            viewModel.onSwitchRecordingMode?(mode)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(viewModel.recordingMode == mode ? Color.btOnPrimary : Color.btSecondaryText)
                .background(viewModel.recordingMode == mode ? Color.btPrimaryFill : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.btSpring, value: viewModel.recordingMode)
    }
}
