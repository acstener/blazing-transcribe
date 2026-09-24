import SwiftUI

struct CustomDictionaryView: View {
    @State private var store = CustomVocabularyStore()
    @FocusState private var isInputFocused: Bool
    @State private var highlightedEntryID: UUID?
    @State private var flashingEntryID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Dictionary")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Vocabulary")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            Text("Help Blazing recognize names and words you use often.")
                                .font(.btCaption)
                                .foregroundStyle(Color.btSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            BTFlowLayout(spacing: BTSpacing.sm, rowSpacing: BTSpacing.sm) {
                                BTBadge(text: termCountLabel, color: .btActiveBackground, textColor: .btText)

                                if store.isGenerating {
                                    BTBadge(text: "Adding", color: .btAccent, textColor: .btAccentForeground)
                                }
                            }

                            // Words as chips with the input as the last "chip": Enter adds,
                            // Backspace on an empty input highlights the last word, again removes it.
                            BTFlowLayout(spacing: BTSpacing.sm, rowSpacing: BTSpacing.sm) {
                                ForEach(store.entries) { entry in
                                    DictionaryChip(
                                        title: entry.canonical,
                                        isHighlighted: highlightedEntryID == entry.id,
                                        isFlashing: flashingEntryID == entry.id,
                                        isDisabled: store.isGenerating,
                                        onRemove: { remove(entry.id) }
                                    )
                                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                                }

                                TextField(store.entries.isEmpty ? "Add a name, brand or word…" : "Add word…",
                                          text: $store.newTermInput)
                                    .textFieldStyle(.plain)
                                    .font(.btBody)
                                    .frame(minWidth: 160)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().strokeBorder(Color.btBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                    .focused($isInputFocused)
                                    .disabled(store.isGenerating)
                                    .onSubmit { submitNewTerm() }
                                    .onChange(of: store.newTermInput) { _, _ in highlightedEntryID = nil }
                                    .onKeyPress(.delete) { handleBackspace() }
                            }
                            .animation(reduceMotion ? nil : .btSpring, value: store.entries.map(\.id))

                            if store.entries.isEmpty {
                                Text("Add a person, company or product name. Blazing learns how it tends to be misheard and fixes it for you — all on your Mac.")
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let statusMessage = store.statusMessage {
                                Text(statusMessage)
                                    .font(.btCaption)
                                    .foregroundStyle(.green)
                            }

                            if let warningMessage = store.warningMessage {
                                Text(warningMessage)
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btWarning)
                            }

                            if let errorMessage = store.errorMessage {
                                Text(errorMessage)
                                    .font(.btCaption)
                                    .foregroundStyle(.red)
                            }

                            DisclosureGroup("Advanced") {
                                Button("Edit pronunciation aliases") { store.openRawFile() }
                                    .disabled(store.isGenerating).padding(.top, 8)
                            }.font(.btCaption).foregroundStyle(Color.btSecondaryText)
                        }
                    }
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
        .onAppear {
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .customVocabularyDidChange)) { _ in
            if store.consumeLocalChangeNotification() {
                return
            }

            if !store.isGenerating {
                store.load()
            }
        }
    }

    private func handleBackspace() -> KeyPress.Result {
        guard store.newTermInput.isEmpty, let last = store.entries.last, !store.isGenerating else { return .ignored }
        if highlightedEntryID == last.id {
            remove(last.id)
        } else {
            highlightedEntryID = last.id
        }
        return .handled
    }

    private func remove(_ id: UUID) {
        highlightedEntryID = nil
        store.removeEntry(id: id)
    }

    private func flash(_ id: UUID) {
        flashingEntryID = id
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            if flashingEntryID == id { flashingEntryID = nil }
        }
    }

    private var termCountLabel: String {
        "\(store.activeTermCount) \(store.activeTermCount == 1 ? "word" : "words")"
    }

    private func submitNewTerm() {
        guard store.canAddTerm else { return }
        let typed = store.newTermInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already there: point at the existing chip instead of re-adding.
        if let existing = store.entries.first(where: { $0.canonical.caseInsensitiveCompare(typed) == .orderedSame }) {
            store.newTermInput = ""
            flash(existing.id)
            return
        }

        Task {
            await store.addTerm()
            isInputFocused = true
        }
    }
}

private struct DictionaryChip: View {
    let title: String
    let isHighlighted: Bool
    let isFlashing: Bool
    let isDisabled: Bool
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.btBody)
                .foregroundStyle(isHighlighted ? Color.btAccentForeground : Color.btText)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHighlighted ? Color.btAccentForeground : Color.btSecondaryText)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isHighlighted ? 1 : 0.5)
            .disabled(isDisabled)
            .help("Remove \(title)")
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(isHighlighted ? Color.btAccent : Color.btBackground))
        .overlay(Capsule().strokeBorder(isFlashing ? Color.btEmber : Color.btBorder, lineWidth: isFlashing ? 1.5 : 1))
        .animation(.btSnappy, value: isHighlighted)
        .animation(.btSnappy, value: isFlashing)
        .onHover { isHovered = $0 }
        .opacity(isDisabled ? 0.72 : 1)
    }
}
