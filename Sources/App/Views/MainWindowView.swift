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

                        Divider()

                        DetailContainerView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(tabSelection)
                .frame(minWidth: 660, minHeight: 500)
                .background(Color.btBackground)
                .onReceive(NotificationCenter.default.publisher(for: .showHistoryTab)) { _ in
                    tabSelection.current = .history
                }
                .onReceive(NotificationCenter.default.publisher(for: .showCustomDictionaryTab)) { _ in
                    tabSelection.current = .dictionary
                }
                .onReceive(NotificationCenter.default.publisher(for: .showStatsTab)) { _ in
                    tabSelection.current = .stats
                }
            }
        }
        .task {
            await pollPermissionState()
        }
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        switch windowWidth {
        case ..<700:
            return 208
        case ..<840:
            return 228
        default:
            return BTSpacing.sidebarWidth
        }
    }

    @MainActor
    private func pollPermissionState() async {
        while !Task.isCancelled {
            viewModel.refreshPermissionState()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
