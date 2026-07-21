import SwiftUI

struct HistoryView: View {
    @State private var viewModel = TranscriptionHistoryViewModel()
    @State private var hoveredDayGroup: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned header + search
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)
                    .padding(.horizontal, BTSpacing.lg)
                    .padding(.top, BTSpacing.lg)
                    .padding(.bottom, BTSpacing.md)

                HStack(spacing: BTSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.btSecondaryText)
                        .font(.system(size: 13))
                    TextField("Search transcriptions...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.btBody)
                        .onChange(of: viewModel.searchText) { _, newValue in
                            viewModel.search(newValue)
                        }
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                            viewModel.loadRecent()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.btSecondaryText)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(BTSpacing.sm + 2)
                .background(Color.btBackground)
                .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                        .stroke(Color.btBorder, lineWidth: 1)
                )
                .padding(.horizontal, BTSpacing.lg)
                .padding(.bottom, BTSpacing.md)
            }
            .frame(maxWidth: BTSpacing.contentMaxWidth)

            // Scrollable entries
            ScrollView {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: BTSpacing.lg) {
                        ForEach(viewModel.groupedEntries) { group in
                            daySection(group)
                        }
                    }
                    .padding(.horizontal, BTSpacing.lg)
                    .padding(.top, BTSpacing.sm)
                    .padding(.bottom, BTSpacing.xl)
                }

                Spacer(minLength: 0)
                    .frame(maxWidth: BTSpacing.contentMaxWidth)
            }
            .btHideScrollIndicators()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            let t = CFAbsoluteTimeGetCurrent()
            guard !hasLoaded else {
                print("[TabPerf] HistoryView.onAppear skipped (already loaded)")
                return
            }
            hasLoaded = true
            viewModel.onRetryTranscription = { id in
                NotificationCenter.default.post(name: .retryTranscriptionRequested, object: id)
            }
            viewModel.onNavigateToStats = {
                NotificationCenter.default.post(name: .showStatsTab, object: nil)
            }
            viewModel.loadRecent()
            print("[TabPerf] HistoryView.onAppear first load: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t) * 1000))ms (\(viewModel.entries.count) entries)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionHistoryDidChange)) { _ in
            viewModel.loadRecent()
        }
    }

    // MARK: - Day Section

    private func daySection(_ group: TranscriptionHistoryViewModel.DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Day header
            HStack {
                Text(group.label)
                    .font(.btLabel)
                    .foregroundStyle(Color.btSecondaryText)
                    .tracking(0.5)

                Spacer()

                // Copy all for this day (on hover)
                if hoveredDayGroup == group.id {
                    Button {
                        viewModel.copyDayTranscriptions(group.entries)
                    } label: {
                        Text("Copy transcript")
                            .font(.btLabel)
                            .foregroundStyle(Color.btSecondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.btActiveBackground)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, BTSpacing.sm)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredDayGroup = hovering ? group.id : nil
                }
            }

            // Entries card
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    HistoryEntryRow(
                        entry: entry,
                        onCopy: { viewModel.copyToClipboard(entry) },
                        onRetry: { viewModel.retryTranscription(entry) },
                        onDismiss: { viewModel.dismissEntry(entry) },
                        onRecover: { viewModel.recoverEntry(entry) },
                        onDelete: { viewModel.deleteEntry(entry) },
                        onDownloadAudio: { viewModel.downloadAudio(entry) }
                    )

                    if index < group.entries.count - 1 {
                        Divider()
                            .foregroundStyle(Color.btBorder.opacity(0.5))
                            .padding(.horizontal, BTSpacing.md)
                    }
                }
            }
            .background(Color.btCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                    .stroke(Color.btBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BTSpacing.sm) {
            Spacer()
                .frame(height: 80)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Color.btSecondaryText.opacity(0.5))
            Text(viewModel.searchText.isEmpty ? "No transcriptions yet" : "No results")
                .font(.btBody)
                .foregroundStyle(Color.btSecondaryText)
            if viewModel.searchText.isEmpty {
                Text("Your transcription history will appear here")
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText.opacity(0.7))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

}
