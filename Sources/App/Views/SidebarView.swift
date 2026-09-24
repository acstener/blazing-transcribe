import SwiftUI

struct SidebarView: View {
    @Environment(TabSelection.self) private var selection
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BlazingMark().fill(Color.btText).frame(width: 20, height: 26).accessibilityHidden(true)
                Text("Blazing").font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(Color.btText)
            .padding(.horizontal, 22).padding(.top, 48).padding(.bottom, 32)

            if selection.current == .general {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selection.current = .dashboard
                    } label: {
                        Label("Back to Dictate", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.btSecondaryText)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)

                    Text("SETTINGS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.btSecondaryText)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)

                    VStack(spacing: 5) {
                        settingsItem("General", icon: "gearshape")
                        settingsItem("Dictation", icon: "text.alignleft")
                        settingsItem("Shortcuts", icon: "command")
                        settingsItem("Audio", icon: "mic")
                        settingsItem("Usage", icon: "chart.bar")
                    }
                    Spacer()
                    settingsItem("Experimental", icon: "flask")
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 5) {
                    BTSidebarItem(title: "Dictate", icon: "waveform", isSelected: selection.current == .dashboard,
                                  namespace: namespace) { selection.current = .dashboard }
                    BTSidebarItem(title: "History", icon: "clock", isSelected: selection.current == .history,
                                  namespace: namespace) { selection.current = .history }
                    BTSidebarItem(title: "Dictionary", icon: "text.book.closed", isSelected: selection.current == .dictionary,
                                  namespace: namespace) { selection.current = .dictionary }
                }.padding(.horizontal, 12)
                Spacer()
                BTSidebarItem(title: "Settings", icon: "gearshape", isSelected: false,
                              namespace: namespace) { selection.current = .general }
                    .padding(.horizontal, 12).padding(.bottom, 20)
            }
        }
        .background(Color.btBackground)
    }

    private func settingsItem(_ title: String, icon: String) -> some View {
        BTSidebarItem(title: title, icon: icon,
                      isSelected: selection.settingsSection == title,
                      namespace: namespace) { selection.settingsSection = title }
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
                .foregroundStyle(viewModel.recordingMode == mode ? Color.btAccentForeground : Color.btSecondaryText)
                .background(viewModel.recordingMode == mode ? Color.btAccent : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.btSpring, value: viewModel.recordingMode)
    }
}
