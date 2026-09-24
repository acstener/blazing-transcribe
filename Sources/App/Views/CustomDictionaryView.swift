import SwiftUI

struct CustomDictionaryView: View {
    @State private var store = CustomVocabularyStore()
    @FocusState private var isInputFocused: Bool

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
                                BTBadge(text: termCountLabel, color: .green)

                                if store.isGenerating {
                                    BTBadge(text: "Adding", color: .btAccent, textColor: .btAccentForeground)
                                }
                            }

                            if store.entries.isEmpty {
                                DictionaryEmptyState()
                            } else {
                                LazyVStack(spacing: BTSpacing.sm) {
                                    ForEach(store.entries) { entry in
                                        DictionaryEntryRow(
                                            title: entry.canonical,
                                            isDisabled: store.isGenerating,
                                            onRemove: {
                                                store.removeEntry(id: entry.id)
                                            }
                                        )
                                    }
                                }
                            }

                            HStack(spacing: BTSpacing.sm) {
                                BTTextField(placeholder: "Add new word...", text: $store.newTermInput)
                                    .focused($isInputFocused)
                                    .onSubmit {
                                        submitNewTerm()
                                    }

                                BTButton(store.isGenerating ? "Adding..." : "Add") {
                                    submitNewTerm()
                                }
                                .disabled(!store.canAddTerm)
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

    private var termCountLabel: String {
        "\(store.activeTermCount) \(store.activeTermCount == 1 ? "word" : "words")"
    }

    private func submitNewTerm() {
        guard store.canAddTerm else { return }

        Task {
            await store.addTerm()
            isInputFocused = true
        }
    }
}

private struct DictionaryEntryRow: View {
    let title: String
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.btBody)
                .foregroundStyle(Color.btText)
                .lineLimit(1)

            Spacer()

            Button("Remove", action: onRemove)
                .buttonStyle(.plain)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
                .disabled(isDisabled)
        }
        .padding(.horizontal, BTSpacing.md)
        .padding(.vertical, 12)
        .background(Color.btBackground)
        .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                .stroke(Color.btBorder, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.72 : 1)
    }
}

private struct DictionaryEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing here yet")
                .font(.btBody)
                .foregroundStyle(Color.btText)

            Text("Add a person, company, or product name. ASR mishearings are generated locally and corrected via regex.")
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BTSpacing.md)
        .padding(.vertical, BTSpacing.md)
        .background(Color.btBackground)
        .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                .stroke(Color.btBorder, lineWidth: 1)
        )
    }
}
