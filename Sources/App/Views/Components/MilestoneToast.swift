import SwiftUI

/// One-time "You just passed a short novel 📖" toast for Home. Self-contained: it watches
/// usage changes, shows only while the window is key (so nobody misses it while dictating
/// into another app), and marks the milestone celebrated once it has actually been shown.
struct MilestoneToast: View {
    var stats: UsageStats = .shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var milestone: UsageMilestone?
    @State private var bounce = 0

    var body: some View {
        ZStack {
            if let milestone {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.btEmber)
                        .symbolEffect(.bounce, value: bounce)
                    Text(milestone.celebrationText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.btCardBackground, in: Capsule())
                .overlay(Capsule().stroke(Color.btBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                .onTapGesture { dismiss() }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 8))
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .task(id: milestone.words) {
                    if !reduceMotion { bounce += 1 }
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    dismiss()
                }
            }
        }
        .padding(.bottom, 20)
        .onAppear(perform: checkForMilestone)
        .onChange(of: controlActiveState) { _, _ in checkForMilestone() }
        .onReceive(NotificationCenter.default.publisher(for: .usageStatsDidChange)) { _ in
            checkForMilestone()
        }
    }

    private func checkForMilestone() {
        guard milestone == nil, controlActiveState == .key,
              let pending = stats.pendingCelebration else { return }
        stats.markCelebrated(pending)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .btSpring) {
            milestone = pending
        }
        AccessibilityNotification.Announcement(pending.celebrationText).post()
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { milestone = nil }
    }
}
