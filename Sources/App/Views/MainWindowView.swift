import SwiftUI

enum SidebarSection: String, CaseIterable {
    case dashboard
    case history
    case dictionary
    case shortcuts
    case audio
    case general
    case stats
}

/// Lightweight observable for tab selection — views read it independently,
/// so changing tabs doesn't cascade body re-evaluations through the entire tree.
@Observable
final class TabSelection {
    var current: SidebarSection = .dashboard
    var settingsSection = "General"
}

struct MainWindowView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var tabSelection = TabSelection()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding || viewModel.isOnboardingPreviewActive {
                OnboardingView()
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        SidebarView()
                            .frame(width: sidebarWidth(for: geometry.size.width))

                        DetailContainerView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.btBorder.opacity(0.5), lineWidth: 1))
                            .padding(.trailing, 12).padding(.vertical, 12)
                    }
                }
                .environment(tabSelection)
                .onChange(of: viewModel.requestedWindowSection, initial: true) { _, destination in
                    guard let destination else { return }
                    tabSelection.current = destination
                    viewModel.requestedWindowSection = nil
                }
                .frame(minWidth: 660, minHeight: 500)
                .background(Color.btBackground)
                .onReceive(NotificationCenter.default.publisher(for: .showHistoryTab)) { _ in
                    tabSelection.current = .history
                }
                .onReceive(NotificationCenter.default.publisher(for: .showCustomDictionaryTab)) { _ in
                    tabSelection.current = .dictionary
                }
                .onReceive(NotificationCenter.default.publisher(for: .showStatsTab)) { _ in
                    tabSelection.settingsSection = "Usage"
                    tabSelection.current = .general
                }
            }
        }
        .task {
            await pollPermissionState()
        }
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth < 740 ? 164 : 184
    }

    @MainActor
    private func pollPermissionState() async {
        while !Task.isCancelled {
            viewModel.refreshPermissionState()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
