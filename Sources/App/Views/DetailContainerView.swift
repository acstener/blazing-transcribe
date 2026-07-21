import SwiftUI

struct DetailContainerView: View {
    var body: some View {
        ZStack {
            LazyTab(.dashboard, eagerly: true) { DashboardView() }
            LazyTab(.history) { HistoryView() }
            LazyTab(.dictionary) { CustomDictionaryView() }
            LazyTab(.shortcuts) { ShortcutsSettingsView() }
            LazyTab(.audio) { AudioSettingsView() }
            LazyTab(.general) { GeneralSettingsView() }
            LazyTab(.stats) { StatsView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btBackground.opacity(0.5))
    }
}

// MARK: - Lazy Tab (no selection read in body after creation)

/// Creates its content on first selection, then keeps it alive forever.
/// After creation, this body never re-runs — `TabVisibility` handles show/hide independently.
private struct LazyTab<Content: View>: View {
    let tab: SidebarSection
    let content: () -> Content
    @State private var created: Bool

    init(_ tab: SidebarSection, eagerly: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.tab = tab
        self.content = content
        self._created = State(initialValue: eagerly)
    }

    var body: some View {
        if created {
            // This branch does NOT read TabSelection — body won't re-run on tab changes
            content()
                .modifier(TabVisibility(tab: tab))
        } else {
            // Lightweight trigger that watches for first selection
            TabCreationTrigger(tab: tab, created: $created)
        }
    }
}

/// Reads TabSelection in its own scope — only this modifier re-evaluates on tab changes,
/// not the parent LazyTab or the content view.
private struct TabVisibility: ViewModifier {
    let tab: SidebarSection
    @Environment(TabSelection.self) private var selection

    func body(content: Content) -> some View {
        let isSelected = selection.current == tab
        content
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
    }
}

/// Invisible view that triggers lazy creation when its tab is first selected.
private struct TabCreationTrigger: View {
    let tab: SidebarSection
    @Binding var created: Bool
    @Environment(TabSelection.self) private var selection

    var body: some View {
        if selection.current == tab {
            Color.clear
                .onAppear { created = true }
        }
    }
}
