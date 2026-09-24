import SwiftUI

struct RecordingSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: BTSpacing.lg) {
                Text("Dictation").font(.btTitle).frame(maxWidth: .infinity, alignment: .leading)
                ModeToggleCard()
                    .btStaggered(index: 0)

                // Text Cleanup card
                TextCleanupCard()
                    .btStaggered(index: 1)

                // Keep Mic Active card
                BTCard {
                    KeepMicActiveControl(style: .settingsCard)
                }
                .btStaggered(index: 2)
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Text Cleanup Card

struct TextCleanupCard: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        let llmCleanupAvailable = viewModel.isLLMCleanupAvailable
        let llmCleanupSubtitle = llmCleanupAvailable
            ? "AI-powered punctuation and formatting"
            : "Unavailable in Turbo realtime"
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.md) {
                Text("Text Cleanup")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                    .textCase(.uppercase)

                VStack(spacing: BTSpacing.sm) {
                    CleanupOption(
                        icon: "xmark.circle",
                        title: "Off",
                        subtitle: "Raw transcription, no cleanup",
                        isSelected: viewModel.textCleanupMode == .off,
                        isEnabled: true,
                        action: {
                            viewModel.onSwitchTextCleanup?(.off)
                        }
                    )

                    CleanupOption(
                        icon: "text.badge.minus",
                        title: "Filler Removal",
                        subtitle: "Remove ums, ahs, and fillers (instant)",
                        isSelected: viewModel.textCleanupMode == .regex,
                        isEnabled: true,
                        action: {
                            viewModel.onSwitchTextCleanup?(.regex)
                        }
                    )

                    HStack(spacing: 0) {
                        CleanupOption(
                            icon: "sparkles",
                            title: "LLM Cleanup",
                            subtitle: llmCleanupSubtitle,
                            isSelected: viewModel.textCleanupMode == .llm,
                            isEnabled: llmCleanupAvailable,
                            action: {
                                viewModel.onSwitchTextCleanup?(.llm)
                            }
                        )

                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.btSecondaryText.opacity(0.6))
                            .padding(.trailing, BTSpacing.sm)
                            .help(
                                llmCleanupAvailable
                                    ? "Run a local AI model for private cleanup, or use a cloud provider for speed. Choose below when LLM Cleanup is enabled."
                                    : "Turbo prioritizes realtime speed, so LLM Cleanup is disabled there. Use Filler Removal for instant cleanup."
                            )
                    }
                }


                if llmCleanupAvailable && viewModel.textCleanupMode == .llm {
                    Divider()
                    LLMSourcePicker()
                    if LLMCleanupService.isVoiceStyleEnabled {
                        Divider()
                        VoiceStylePicker()
                    }
                }
            }
        }
    }
}

// MARK: - LLM Source Selection

enum LLMSourceOption: String, CaseIterable {
    case qwen, groq, gemini

    var title: String {
        switch self {
        case .qwen: "Qwen"
        case .groq: "Groq"
        case .gemini: "Gemini"
        }
    }

    var icon: String {
        switch self {
        case .qwen: "shield.lefthalf.filled"
        case .groq, .gemini: "cloud.fill"
        }
    }

    var isLocal: Bool {
        switch self {
        case .qwen: true
        case .groq, .gemini: false
        }
    }

    var localModelID: String? {
        switch self {
        case .qwen: "qwen3.5-2b-q4_k_m"
        default: nil
        }
    }

    var bullets: [String] {
        switch self {
        case .qwen: [
            "Private \u{2022} runs on your Mac",
            "Good stability",
            "Basic formatting",
        ]
        case .groq: [
            "Fastest cleanup",
            "Good stability",
            "Your Groq API key",
        ]
        case .gemini: [
            "Most stable & reliable",
            "Moderate speed",
            "Your Gemini API key",
        ]
        }
    }

    var cloudKeyProvider: CloudKeyProvider? {
        switch self {
        case .qwen: nil
        case .groq: .groq
        case .gemini: .gemini
        }
    }
}

/// Cloud providers that need a user-supplied API key (BYO — no keys ship with the app).
enum CloudKeyProvider {
    case groq
    case gemini

    var label: String {
        switch self {
        case .groq: "Groq API key"
        case .gemini: "Gemini API key"
        }
    }

    var consoleURL: URL {
        switch self {
        case .groq: URL(string: "https://console.groq.com/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// Key entry for a cloud cleanup provider. Saves on every keystroke via the
/// viewModel callback so there's no explicit save button to forget.
struct APIKeyField: View {
    let provider: CloudKeyProvider
    @Environment(AppViewModel.self) private var viewModel
    @State private var key: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: BTSpacing.xs) {
                Text(provider.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                Link("Get a free key", destination: provider.consoleURL)
                    .font(.system(size: 10))
            }

            SecureField("Paste your API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: key) { _, newValue in
                    switch provider {
                    case .groq: viewModel.onGroqAPIKeyChanged?(newValue)
                    case .gemini: viewModel.onGeminiAPIKeyChanged?(newValue)
                    }
                }

            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Cloud cleanup needs your own key. Without one, cleanup uses the local model instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.btSecondaryText)
            }
        }
        .onAppear {
            switch provider {
            case .groq: key = viewModel.groqAPIKey
            case .gemini: key = viewModel.geminiAPIKey
            }
        }
        .id(provider.label)
    }
}

// MARK: - LLM Source Picker

struct LLMSourcePicker: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var selected: LLMSourceOption = .qwen

    var body: some View {
        VStack(alignment: .leading, spacing: BTSpacing.sm) {
            Text("LLM Source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.btSecondaryText)
                .textCase(.uppercase)

            // Local
            VStack(alignment: .leading, spacing: 6) {
                Text("Local")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)

                LLMSourceCard(option: .qwen, isSelected: selected == .qwen) {
                    select(.qwen)
                }
            }

            // Cloud
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)

                HStack(spacing: BTSpacing.sm) {
                    LLMSourceCard(option: .groq, isSelected: selected == .groq) {
                        select(.groq)
                    }
                    LLMSourceCard(option: .gemini, isSelected: selected == .gemini) {
                        select(.gemini)
                    }
                }

                if let provider = selected.cloudKeyProvider {
                    APIKeyField(provider: provider)
                }
            }
        }
        .onAppear {
            selected = currentSelection()
        }
    }

    private func select(_ option: LLMSourceOption) {
        selected = option
        if option.isLocal, let modelID = option.localModelID {
            viewModel.onSelectLocalModel?(modelID)
        } else if option == .groq {
            viewModel.onToggleLocalLLM?(false)
            viewModel.onSelectLLMProvider?(LLMCleanupService.groqAPIModelID)
        } else if option == .gemini {
            viewModel.onToggleLocalLLM?(false)
            viewModel.onSelectLLMProvider?(LLMCleanupService.defaultAPIModelID)
        }
    }

    private func currentSelection() -> LLMSourceOption {
        if viewModel.useLocalLLM {
            return .qwen
        }
        let apiID = LLMCleanupService.preferredAPIModelID
        if apiID.contains("groq") { return .groq }
        return .gemini
    }
}

struct LLMSourceCard: View {
    let option: LLMSourceOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: option.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.btSecondaryText)
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(option.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\u{2022}")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.btSecondaryText)
                                .padding(.top, 1)
                            Text(bullet)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.btSecondaryText)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BTSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.btBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice Style Picker

private struct VoiceStylePicker: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var savedPresets: [SavedVoicePreset] = SavedVoicePreset.loadAll()
    @State private var builtInPromptOverrides: [String: String] = BuiltInVoicePresetOverrideStore.load()
    @State private var isAddingNew = false
    @State private var newLabel = ""
    @State private var newPrompt = ""
    @State private var editingPreset: EditableVoicePreset?
    @State private var isEditingCustomPrompt = false
    @State private var editingPrompt = ""

    private var activePrompt: String {
        viewModel.customPromptInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedBuiltIn: BuiltInVoicePreset? {
        guard viewModel.isCustomPromptEnabled else { return nil }
        return BuiltInVoicePreset.all.first { prompt(for: $0) == activePrompt }
    }

    private var selectedSaved: SavedVoicePreset? {
        guard viewModel.isCustomPromptEnabled else { return nil }
        return savedPresets.first { $0.prompt == activePrompt }
    }

    private var isCustomFreeform: Bool {
        viewModel.isCustomPromptEnabled && selectedBuiltIn == nil && selectedSaved == nil && !activePrompt.isEmpty
    }

    private var isEditingSelectedPreset: Bool {
        editingPreset != nil
    }

    private var showPromptPanel: Bool {
        viewModel.isCustomPromptEnabled || isEditingCustomPrompt || isAddingNew || isEditingSelectedPreset
    }

    private var currentVoiceLabel: String {
        if let selectedSaved {
            return selectedSaved.label
        }
        if let selectedBuiltIn {
            return selectedBuiltIn.label
        }
        return "Custom Voice"
    }

    private var selectedBuiltInHasOverride: Bool {
        guard let selectedBuiltIn else { return false }
        guard let override = builtInPromptOverrides[selectedBuiltIn.id] else { return false }
        return !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var styleSummary: String {
        if selectedSaved != nil {
            return "Saved voice"
        }
        if let selectedBuiltIn {
            return selectedBuiltIn.shortDescription
        }
        if isCustomFreeform {
            return "Freeform custom voice"
        }
        return "Default cleanup"
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: BTSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Style")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                    .textCase(.uppercase)

                Text("Layer custom voices on top of the default cleanup prompt and safety examples.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.btSecondaryText)
            }

            BTFlowLayout(spacing: BTSpacing.sm, rowSpacing: BTSpacing.sm) {
                VoiceStyleOptionCard(
                    title: "Default Cleanup",
                    subtitle: "Surface cleanup only",
                    isSelected: !viewModel.isCustomPromptEnabled,
                    action: selectNone
                )

                ForEach(BuiltInVoicePreset.all) { preset in
                    VoiceStyleOptionCard(
                        title: preset.label,
                        subtitle: preset.shortDescription,
                        isSelected: selectedBuiltIn?.id == preset.id,
                        action: {
                            selectPreset(prompt: prompt(for: preset))
                        }
                    )
                }

                if isCustomFreeform {
                    VoiceStyleOptionCard(
                        title: "Custom Voice",
                        subtitle: "Freeform custom rule",
                        isSelected: true,
                        action: beginCustomPromptEditing
                    )
                }

                ForEach(savedPresets) { preset in
                    VoiceStyleOptionCard(
                        title: preset.label,
                        subtitle: "Saved custom voice",
                        isSelected: selectedSaved?.id == preset.id,
                        action: {
                            selectPreset(prompt: preset.prompt)
                        }
                    )
                }
            }

            HStack(spacing: BTSpacing.sm) {
                VoiceStyleActionButton(
                    title: viewModel.isCustomPromptEnabled ? "Edit Style" : "Custom Voice",
                    icon: "slider.horizontal.3",
                    action: beginEditingActiveVoice
                )

                VoiceStyleActionButton(
                    title: activePrompt.isEmpty ? "New Voice" : "Save As New",
                    icon: "plus",
                    action: {
                        beginCreatingPreset(prefillPrompt: activePrompt)
                    }
                )

                if selectedBuiltInHasOverride {
                    VoiceStyleActionButton(
                        title: "Reset Style",
                        icon: "arrow.counterclockwise",
                        action: resetSelectedBuiltInOverride
                    )
                }

                if let selectedSaved {
                    VoiceStyleActionButton(
                        title: "Delete Voice",
                        icon: "trash",
                        role: .destructive,
                        action: {
                            withAnimation(.btSpring) {
                                removeSavedPreset(selectedSaved)
                            }
                        }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if showPromptPanel {
                let showCustomEditor = isEditingCustomPrompt || isCustomFreeform || activePrompt.isEmpty

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: BTSpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentVoiceLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText)
                                .textCase(.uppercase)

                            Text(styleSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.btSecondaryText.opacity(0.85))
                        }

                        Spacer()

                        Text("Layered")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if isAddingNew {
                        VStack(alignment: .leading, spacing: BTSpacing.sm) {
                            TextField("Style name", text: $newLabel)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .padding(BTSpacing.sm)
                                .background(Color.btBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.btBorder, lineWidth: 1)
                                )

                            TextField("Describe the voice style...", text: $newPrompt, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .lineLimit(3...6)
                                .padding(BTSpacing.sm)
                                .background(Color.btBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.btBorder, lineWidth: 1)
                                )

                            HStack(spacing: BTSpacing.sm) {
                                Button("Cancel") {
                                    withAnimation(.btSpring) {
                                        isAddingNew = false
                                        newLabel = ""
                                        newPrompt = ""
                                    }
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText)
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    saveNewPreset()
                                } label: {
                                    Text("Save Voice")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(canSave ? Color.white : Color.btSecondaryText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(canSave ? Color.accentColor : Color.btActiveBackground)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canSave)
                            }
                        }
                    } else if showCustomEditor {
                        TextField("e.g. Rewrite the cleaned transcript in a crisp, friendly tone.", text: $viewModel.customPromptInstruction, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.btText.opacity(0.9))
                            .lineLimit(3...6)
                            .padding(BTSpacing.sm)
                            .background(Color.btBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.btBorder, lineWidth: 1)
                            )
                            .onChange(of: viewModel.customPromptInstruction) { _, newValue in
                                viewModel.onCustomPromptChanged?(newValue)
                            }
                    } else if isEditingSelectedPreset {
                        VStack(alignment: .leading, spacing: BTSpacing.sm) {
                            Text("Style Rule")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText)
                                .textCase(.uppercase)

                            TextField("Describe the voice style...", text: $editingPrompt, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.btText.opacity(0.9))
                                .lineLimit(3...6)
                                .padding(BTSpacing.sm)
                                .background(Color.btBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.btBorder, lineWidth: 1)
                                )

                            HStack(spacing: BTSpacing.sm) {
                                Button("Cancel") {
                                    cancelPresetEditing()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.btSecondaryText)
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    savePresetEdits()
                                } label: {
                                    Text("Save")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(canSavePresetEdits ? Color.white : Color.btSecondaryText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(canSavePresetEdits ? Color.accentColor : Color.btActiveBackground)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canSavePresetEdits)
                            }
                        }
                    } else if let selectedBuiltIn {
                        BuiltInVoicePreviewCard(
                            title: selectedBuiltIn.label,
                            description: selectedBuiltIn.detailDescription,
                            inputExample: selectedBuiltIn.previewInput,
                            outputExample: selectedBuiltIn.previewOutput
                        )
                    } else {
                        Text(activePrompt)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.btSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(BTSpacing.sm)
                            .background(Color.btBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.btBorder, lineWidth: 1)
                            )
                    }
                }
                .padding(BTSpacing.sm)
                .background(Color.btActiveBackground.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.btBorder, lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.btSpring, value: viewModel.isCustomPromptEnabled)
        .animation(.btSpring, value: isAddingNew)
    }

    private var canSave: Bool {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && !prompt.isEmpty
    }

    private var canSavePresetEdits: Bool {
        !editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prompt(for preset: BuiltInVoicePreset) -> String {
        let override = builtInPromptOverrides[preset.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? preset.defaultPrompt
    }

    private func selectNone() {
        cancelPresetEditing()
        isEditingCustomPrompt = false
        withAnimation(.btSpring) {
            isAddingNew = false
        }
        viewModel.isCustomPromptEnabled = false
        viewModel.customPromptInstruction = ""
        viewModel.onCustomPromptChanged?("")
    }

    private func selectPreset(prompt: String) {
        cancelPresetEditing()
        isEditingCustomPrompt = false
        withAnimation(.btSpring) {
            isAddingNew = false
        }
        viewModel.isCustomPromptEnabled = true
        viewModel.customPromptInstruction = prompt
        viewModel.onCustomPromptChanged?(prompt)
    }

    private func beginCustomPromptEditing() {
        cancelPresetEditing()
        withAnimation(.btSpring) {
            isAddingNew = false
            isEditingCustomPrompt = true
        }
        if activePrompt.isEmpty {
            viewModel.customPromptInstruction = ""
            viewModel.onCustomPromptChanged?("")
        }
    }

    private func beginCreatingPreset(prefillPrompt: String = "") {
        cancelPresetEditing()
        isEditingCustomPrompt = false
        newLabel = ""
        newPrompt = prefillPrompt
        withAnimation(.btSpring) {
            isAddingNew = true
        }
    }

    private func saveNewPreset() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !prompt.isEmpty else { return }

        let preset = SavedVoicePreset(label: label, prompt: prompt)
        savedPresets.append(preset)
        SavedVoicePreset.saveAll(savedPresets)

        withAnimation(.btSpring) {
            isAddingNew = false
            newLabel = ""
            newPrompt = ""
        }

        selectPreset(prompt: prompt)
    }

    private func beginEditingActiveVoice() {
        if isCustomFreeform || activePrompt.isEmpty {
            beginCustomPromptEditing()
        } else {
            beginEditingSelectedPreset()
        }
    }

    private func beginEditingSelectedPreset() {
        if let preset = selectedSaved {
            beginEditingSavedPreset(preset)
        } else if let preset = selectedBuiltIn {
            beginEditingBuiltIn(preset)
        } else {
            beginCustomPromptEditing()
        }
    }

    private func beginEditingBuiltIn(_ preset: BuiltInVoicePreset) {
        let presetPrompt = prompt(for: preset)
        viewModel.isCustomPromptEnabled = true
        viewModel.customPromptInstruction = presetPrompt
        viewModel.onCustomPromptChanged?(presetPrompt)
        editingPrompt = presetPrompt
        withAnimation(.btSpring) {
            isAddingNew = false
            isEditingCustomPrompt = false
            editingPreset = .builtIn(preset.id)
        }
    }

    private func beginEditingSavedPreset(_ preset: SavedVoicePreset) {
        viewModel.isCustomPromptEnabled = true
        viewModel.customPromptInstruction = preset.prompt
        viewModel.onCustomPromptChanged?(preset.prompt)
        editingPrompt = preset.prompt
        withAnimation(.btSpring) {
            isAddingNew = false
            isEditingCustomPrompt = false
            editingPreset = .saved(preset.id)
        }
    }

    private func cancelPresetEditing() {
        withAnimation(.btSpring) {
            editingPreset = nil
        }
        editingPrompt = ""
    }

    private func savePresetEdits() {
        let prompt = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let editingPreset else { return }

        switch editingPreset {
        case .builtIn(let presetID):
            if let preset = BuiltInVoicePreset.all.first(where: { $0.id == presetID }) {
                if prompt == preset.defaultPrompt {
                    builtInPromptOverrides.removeValue(forKey: presetID)
                } else {
                    builtInPromptOverrides[presetID] = prompt
                }
                BuiltInVoicePresetOverrideStore.save(builtInPromptOverrides)
            }
        case .saved(let presetID):
            guard let index = savedPresets.firstIndex(where: { $0.id == presetID }) else { return }
            savedPresets[index] = SavedVoicePreset(label: savedPresets[index].label, prompt: prompt)
            SavedVoicePreset.saveAll(savedPresets)
        }

        selectPreset(prompt: prompt)
    }

    private func removeSavedPreset(_ preset: SavedVoicePreset) {
        if selectedSaved?.id == preset.id {
            selectNone()
        }
        savedPresets.removeAll { $0.id == preset.id }
        SavedVoicePreset.saveAll(savedPresets)
    }

    private func resetSelectedBuiltInOverride() {
        guard let selectedBuiltIn else { return }
        builtInPromptOverrides.removeValue(forKey: selectedBuiltIn.id)
        BuiltInVoicePresetOverrideStore.save(builtInPromptOverrides)
        selectPreset(prompt: selectedBuiltIn.defaultPrompt)
    }
}

private struct VoiceStyleOptionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.btText)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 146, alignment: .leading)
            .padding(BTSpacing.sm)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.btBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.btBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceStyleActionButton: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(role == .destructive ? Color.red : Color.btText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.btBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(
            Capsule()
                .strokeBorder(role == .destructive ? Color.red.opacity(0.2) : Color.btBorder, lineWidth: 1)
        )
    }
}

private struct BuiltInVoicePreviewCard: View {
    let title: String
    let description: String
    let inputExample: String
    let outputExample: String

    var body: some View {
        VStack(alignment: .leading, spacing: BTSpacing.sm) {
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(Color.btText.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Example")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                    .textCase(.uppercase)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Input")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.btSecondaryText)
                    Text("“\(inputExample)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.btText.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Output")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    Text("“\(outputExample)”")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.btText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BTSpacing.sm)
                .background(Color.btBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.btBorder, lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Voice Preset Models

private struct BuiltInVoicePreset: Identifiable, Equatable {
    let id: String
    let label: String
    let shortDescription: String
    let detailDescription: String
    let previewInput: String
    let previewOutput: String
    let defaultPrompt: String

    static let all: [BuiltInVoicePreset] = [
        .init(
            id: "formal",
            label: "Formal",
            shortDescription: "Sharper professional phrasing",
            detailDescription: "Keeps the same message, but tightens it into more formal professional language.",
            previewInput: "hey can you send the report by friday",
            previewOutput: "Hello, can you send the report by Friday?",
            defaultPrompt: "Rewrite the cleaned transcript in a formal, professional voice. Preserve the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        ),
        .init(
            id: "casual",
            label: "Casual",
            shortDescription: "Relaxed and conversational",
            detailDescription: "Keeps the wording light and natural, like a relaxed chat message.",
            previewInput: "I would appreciate it if you could send that over today",
            previewOutput: "I'd appreciate it if you could send that over today.",
            defaultPrompt: "Rewrite the cleaned transcript in a casual, conversational voice. Preserve the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        ),
        .init(
            id: "email",
            label: "Email",
            shortDescription: "Polished message formatting",
            detailDescription: "Formats clear message dictation like a polished email, but only using what was actually spoken.",
            previewInput: "hello sam can you send the latest numbers by friday thank you very much all the best alex",
            previewOutput: "Hello Sam,\n\nCan you send the latest numbers by Friday?\n\nThank you very much.\n\nAll the best,\nAlex",
            defaultPrompt: "If the transcript is clearly an email or message, format it like a polished email or message with sensible line breaks while preserving only the information actually spoken. Otherwise keep it as regular cleaned text. Do not add greetings, sign-offs, or details that were not spoken. Do not answer questions."
        ),
        .init(
            id: "linkedin",
            label: "LinkedIn",
            shortDescription: "Professional but personable",
            detailDescription: "Polishes the text into a confident LinkedIn-style professional voice without changing the point.",
            previewInput: "we shipped the new onboarding flow today and the early numbers look really strong",
            previewOutput: "We shipped the new onboarding flow today, and the early numbers look really strong.",
            defaultPrompt: "Rewrite the cleaned transcript in a polished LinkedIn-style professional voice. Preserve the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        ),
        .init(
            id: "pirate",
            label: "Pirate",
            shortDescription: "Light pirate diction",
            detailDescription: "Adds a light pirate voice overlay. Think 'ahoy', 'matey', 'ye', and 'be' without turning it into a full joke response.",
            previewInput: "hello, how are you doing?",
            previewOutput: "Ahoy there, how be ye?",
            defaultPrompt: "Rewrite the cleaned transcript in a light pirate voice. Use light pirate wording such as 'ahoy', 'matey', 'ye', and 'be' when it feels natural. Preserve the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        ),
    ]
}

private enum EditableVoicePreset: Equatable {
    case builtIn(String)
    case saved(String)
}

private enum BuiltInVoicePresetOverrideStore {
    private static let storageKey = "builtInVoiceStylePresetOverrides"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    static func save(_ overrides: [String: String]) {
        UserDefaults.standard.set(overrides, forKey: storageKey)
    }
}

private struct SavedVoicePreset: Identifiable, Equatable, Codable {
    var id: String { label }
    let label: String
    let prompt: String

    private static let storageKey = "savedVoiceStylePresets"

    static func loadAll() -> [SavedVoicePreset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([SavedVoicePreset].self, from: data)
        else { return [] }
        return presets
    }

    static func saveAll(_ presets: [SavedVoicePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Cleanup Option

struct CleanupOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(
        icon: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.white : (isEnabled ? Color.btText : Color.btSecondaryText))
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.accentColor : Color.btActiveBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isEnabled ? Color.btText : Color.btSecondaryText)
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
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let state: AppState.State
    let isEngineLoading: Bool

    var body: some View {
        HStack(spacing: BTSpacing.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.btActiveBackground)
        .clipShape(Capsule())
    }

    private var statusText: String {
        if isEngineLoading { return "Starting..." }
        switch state {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .error(let msg): return msg
        }
    }

    private var dotColor: Color {
        if isEngineLoading { return .orange }
        switch state {
        case .idle: return .gray
        case .listening: return .green
        case .recording: return .red
        case .transcribing: return .blue
        case .error: return .red
        }
    }
}
