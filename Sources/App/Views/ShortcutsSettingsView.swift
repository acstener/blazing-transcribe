import SwiftUI
import AppKit
import HotkeyModule

struct ShortcutsSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var shortcutState: ShortcutSettingsState

    init() {
        _shortcutState = State(initialValue: ShortcutSettingsState())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Shortcuts")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    fnKeyCard

                    KeyboardSetupHelp()

                    ShortcutRecorderField(
                        title: "Push-to-talk",
                        subtitle: pttSubtitle,
                        shortcut: shortcutLabel(for: shortcutState.pttShortcut, holdLabel: true),
                        captureHint: "Press any key, modifier key, or key combo now. Esc cancels.",
                        onCapture: updatePTTShortcut,
                        onReset: resetPTTShortcut
                    )

                    ShortcutRecorderField(
                        title: "Toggle recording",
                        subtitle: "Press once to start, again to stop.",
                        shortcut: shortcutState.toggleShortcut.displayString,
                        captureHint: "Press any key, modifier key, or key combo now. Esc cancels.",
                        onCapture: updateToggleShortcut,
                        onReset: resetToggleShortcut
                    )

                    ShortcutRecorderField(
                        title: "Toggle mic",
                        subtitle: "Turns listening on or off globally.",
                        shortcut: shortcutState.micToggleShortcut.displayString,
                        captureHint: "Press any key, modifier key, or key combo now. Esc cancels.",
                        onCapture: updateMicToggleShortcut,
                        onReset: resetMicToggleShortcut
                    )

                    fixedShortcutField(
                        title: "Toggle LLM Cleanup",
                        subtitle: "Switches between Off and LLM Cleanup. Built in.",
                        shortcut: GlobalShortcut.defaultLLMCleanupToggle.displayString
                    )

                    fixedShortcutField(
                        title: "Switch mode",
                        subtitle: "Flips between Always-on and Manual.",
                        shortcut: ShortcutSettingsState.modeToggleLabel(for: shortcutState.modeToggleShortcut)
                    )

                    if let shortcutError = shortcutState.shortcutError {
                        BTCard {
                            Text(shortcutError)
                                .font(.btCaption)
                                .foregroundStyle(Color.red)
                        }
                    }
                }
            }
            .padding(BTSpacing.xl)
            .frame(maxWidth: BTSpacing.contentMaxWidth, alignment: .leading)
        }
        .btHideScrollIndicators()
        .frame(maxWidth: .infinity)
    }

    // MARK: - fn key

    /// One switch for people whose fn/🌐 key already does something on their Mac.
    private var fnKeyCard: some View {
        BTCard {
            HStack(alignment: .center, spacing: BTSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use the fn key")
                        .font(.btBody)
                        .foregroundStyle(Color.btText)
                    Text(shortcutState.usesFnKey
                         ? "Blazing listens to fn. Turn off to keep fn for Emoji, Dictation or anything else your Mac uses it for."
                         : "fn is left alone. Blazing uses \(shortcutState.pttShortcut.displayString) to dictate instead.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BTSpacing.md)
                Toggle("Use the fn key", isOn: Binding(
                    get: { shortcutState.usesFnKey },
                    set: { setUsesFnKey($0) }
                ))
                .toggleStyle(.btSwitch)
                .labelsHidden()
            }
        }
    }

    private func setUsesFnKey(_ useFn: Bool) {
        if useFn {
            shortcutState.useFnKeyDefaults()
        } else if !shortcutState.stopUsingFnKey() {
            return
        }
        applyShortcuts()
    }

    private func applyShortcuts() {
        viewModel.onUpdatePTTShortcut?(shortcutState.pttShortcut)
        viewModel.onUpdateToggleShortcut?(shortcutState.toggleShortcut)
        viewModel.onUpdateModeToggleShortcut?(shortcutState.modeToggleShortcut)
        viewModel.pttShortcutLabel = shortcutState.pttShortcut.displayString
    }

    private func fixedShortcutField(title: String, subtitle: String, shortcut: String) -> some View {
        BTCard {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: BTSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.btBody)
                            .foregroundStyle(Color.btText)
                        Text(subtitle)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                    }

                    Spacer(minLength: BTSpacing.md)

                    Text(shortcut)
                        .font(.btMono)
                        .foregroundStyle(Color.btSecondaryText)
                        .padding(.horizontal, BTSpacing.sm)
                        .padding(.vertical, BTSpacing.xs)
                        .background(Color.btActiveBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(minWidth: 560, alignment: .leading)

                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.btBody)
                            .foregroundStyle(Color.btText)
                        Text(subtitle)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                    }

                    Text(shortcut)
                        .font(.btMono)
                        .foregroundStyle(Color.btSecondaryText)
                        .padding(.horizontal, BTSpacing.sm)
                        .padding(.vertical, BTSpacing.xs)
                        .background(Color.btActiveBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func shortcutLabel(for shortcut: GlobalShortcut, holdLabel: Bool = false) -> String {
        if holdLabel && shortcut == GlobalShortcut.defaultPTT {
            return "fn (hold)"
        }
        return shortcut.displayString
    }

    private var pttSubtitle: String {
        viewModel.transcriptionPreset == .powerUserFastest
            ? "Hold to speak; text streams live in Turbo."
            : "Hold to record, release to transcribe."
    }

    private func updatePTTShortcut(_ captured: CapturedShortcut) {
        guard let candidate = shortcutState.updatePTT(
            keyCode: captured.keyCode,
            modifiers: captured.modifiers.rawValue,
            modifierKeyCode: captured.modifierKeyCode
        ) else { return }
        viewModel.onUpdatePTTShortcut?(candidate)
    }

    private func updateToggleShortcut(_ captured: CapturedShortcut) {
        guard let candidate = shortcutState.updateToggleRecording(
            keyCode: captured.keyCode,
            modifiers: captured.modifiers.rawValue,
            modifierKeyCode: captured.modifierKeyCode
        ) else { return }
        viewModel.onUpdateToggleShortcut?(candidate)
    }

    private func updateMicToggleShortcut(_ captured: CapturedShortcut) {
        guard let candidate = shortcutState.updateMicToggle(
            keyCode: captured.keyCode,
            modifiers: captured.modifiers.rawValue,
            modifierKeyCode: captured.modifierKeyCode
        ) else { return }
        viewModel.onUpdateMicToggleShortcut?(candidate)
    }

    private func updateModeToggleShortcut(_ captured: CapturedShortcut) {
        guard let candidate = shortcutState.updateModeToggle(
            keyCode: captured.keyCode,
            modifiers: captured.modifiers.rawValue,
            modifierKeyCode: captured.modifierKeyCode
        ) else { return }
        viewModel.onUpdateModeToggleShortcut?(candidate)
    }

    private func resetPTTShortcut() {
        let shortcut = shortcutState.resetPTT()
        viewModel.onUpdatePTTShortcut?(shortcut)
    }

    private func resetToggleShortcut() {
        let shortcut = shortcutState.resetToggleRecording()
        viewModel.onUpdateToggleShortcut?(shortcut)
    }

    private func resetMicToggleShortcut() {
        let shortcut = shortcutState.resetMicToggle()
        viewModel.onUpdateMicToggleShortcut?(shortcut)
    }

    private func resetModeToggleShortcut() {
        let shortcut = shortcutState.resetModeToggle()
        viewModel.onUpdateModeToggleShortcut?(shortcut)
    }
}
