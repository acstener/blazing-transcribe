import SwiftUI

struct SettingsHubView: View {
    @Environment(TabSelection.self) private var selection
    var body: some View {
        Group {
            switch selection.settingsSection {
            case "Dictation": RecordingSettingsView()
            case "Shortcuts": ShortcutsSettingsView()
            case "Audio": AudioSettingsView()
            case "Experimental": ExperimentalSettingsView()
            case "Usage": StatsView()
            default: GeneralSettingsView()
            }
        }
    }
}

struct ExperimentalSettingsView: View {
    @Environment(AppViewModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Experimental").font(.btTitle)
                Text("Try new dictation features. Stable is recommended for everyday use.")
                    .font(.btBody).foregroundStyle(Color.btSecondaryText)
                BTCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ModeOption(icon: "checkmark.shield", title: "Stable", subtitle: "Text appears when you finish speaking",
                                   isSelected: model.transcriptionPreset == .stable) { model.onSwitchPreset?(.stable) }
                        ModeOption(icon: "waveform", title: "Turbo · Experimental", subtitle: "Text appears as you speak",
                                   isSelected: model.transcriptionPreset == .powerUserFastest) { model.onSwitchPreset?(.powerUserFastest) }
                        Text("Turbo keeps the microphone active between recordings, even in Manual mode. The macOS mic indicator stays on until you pause the mic or it sleeps. AI text cleanup is unavailable in Turbo.")
                            .font(.btCaption).foregroundStyle(Color.btSecondaryText)
                    }
                }
            }.padding(32).frame(maxWidth: 800, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}
