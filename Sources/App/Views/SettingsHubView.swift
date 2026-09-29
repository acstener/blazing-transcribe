import SwiftUI
import AudioEngine

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
    @AppStorage(AppDelegate.bluetoothInputGuardKey) private var keepBluetoothHeadphonesHighQuality = false
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
                BTCard {
                    HStack(alignment: .center, spacing: BTSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep AirPods sounding right in every app")
                                .font(.btBody)
                                .foregroundStyle(Color.btText)
                            Text("When Bluetooth headphones connect, macOS makes them your mic too, and any app that listens (Zoom, Shazam, Siri) drops them to call-quality audio. This switches your Mac's input back to its built-in mic. Blazing already does this for its own recordings. Pick your headphones' mic in System Settings any time and it stays.")
                                .font(.btCaption)
                                .foregroundStyle(Color.btSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: BTSpacing.md)
                        Toggle("Keep AirPods sounding right in every app", isOn: $keepBluetoothHeadphonesHighQuality)
                            .toggleStyle(.btSwitch)
                            .labelsHidden()
                            .onChange(of: keepBluetoothHeadphonesHighQuality) { _, newValue in
                                BluetoothInputGuard.shared.isEnabled = newValue
                            }
                    }
                }
            }.padding(32).frame(maxWidth: 800, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}
