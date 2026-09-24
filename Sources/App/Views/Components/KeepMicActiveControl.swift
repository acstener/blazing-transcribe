import SwiftUI

struct KeepMicActiveControl: View {
    @Environment(AppViewModel.self) private var viewModel

    enum Style {
        case settingsCard
        case dashboardFooter
    }

    let style: Style

    @AppStorage("disableKeepMicReady") private var disableKeepMicReady = false
    /// 0 = never sleep. Defaults to 15 — sleep-when-idle is on out of the box.
    @AppStorage("micIdleSleepMinutes") private var micIdleSleepMinutes = 15

    private static let idleSleepMinuteOptions = [0, 5, 10, 15, 30, 60]

    private var isForcedOnByAlwaysOnMode: Bool {
        viewModel.recordingMode == .alwaysOn || viewModel.transcriptionPreset.usesRealtimeEngine
    }

    private var keepMicReadyBinding: Binding<Bool> {
        Binding(
            get: { isForcedOnByAlwaysOnMode || !disableKeepMicReady },
            set: { newValue in
                guard !isForcedOnByAlwaysOnMode else { return }
                let newDisableValue = !newValue
                guard disableKeepMicReady != newDisableValue else { return }
                disableKeepMicReady = newDisableValue
                NotificationCenter.default.post(name: .keepMicReadyDidChange, object: nil)
            }
        )
    }

    private var keepMicReadyEnabled: Bool {
        keepMicReadyBinding.wrappedValue
    }

    private var idleSleepMinutesBinding: Binding<Int> {
        Binding(
            get: { micIdleSleepMinutes },
            set: { newValue in
                guard micIdleSleepMinutes != newValue else { return }
                micIdleSleepMinutes = newValue
                NotificationCenter.default.post(name: .micIdleSleepPreferenceDidChange, object: nil)
            }
        )
    }

    var body: some View {
        switch style {
        case .settingsCard:
            settingsCard
        case .dashboardFooter:
            dashboardFooter
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep mic active")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                    Text(settingsSubtitle)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Keep microphone active", isOn: keepMicReadyBinding)
                    .labelsHidden()
                    .toggleStyle(.btSwitch)
            }
            .disabled(isForcedOnByAlwaysOnMode)

            if keepMicReadyEnabled {
                Divider()

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep when idle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.btText)
                        Text(idleSleepSubtitle)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Sleep microphone after", selection: idleSleepMinutesBinding) {
                        ForEach(Self.idleSleepMinuteOptions, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var dashboardFooter: some View {
        HStack(alignment: .center, spacing: BTSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mic Standby")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.btSecondaryText)
                    .textCase(.uppercase)

                Text("Keep mic active")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.btText)

                Text(dashboardSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: BTSpacing.md)

            Toggle("Keep microphone active", isOn: keepMicReadyBinding)
                .labelsHidden()
                .toggleStyle(.btSwitch)
                .disabled(isForcedOnByAlwaysOnMode)
        }
        .padding(.horizontal, BTSpacing.md)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                .fill(Color.btCardBackground.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                .strokeBorder(Color.btBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.025), radius: 4, y: 2)
    }

    private var settingsSubtitle: String {
        if isForcedOnByAlwaysOnMode {
            return viewModel.recordingMode == .alwaysOn
                ? "Hands-free keeps the microphone active until paused or asleep."
                : "Experimental realtime requires an active microphone between recordings. Choose Stable in Experimental settings to turn standby off."
        }
        return "Keeps the microphone active between recordings for faster starts. macOS shows its mic indicator while active. Turn off to stop capture between recordings."
    }

    private var idleSleepSubtitle: String {
        guard micIdleSleepMinutes > 0 else {
            return "Turn the mic fully off after a period without dictation, until you use it again."
        }
        if isForcedOnByAlwaysOnMode {
            return "Mic turns off after \(micIdleSleepMinutes) min without dictation. Listening pauses while asleep — press a recording shortcut to wake it."
        }
        return "Mic turns off after \(micIdleSleepMinutes) min without dictation. Your next recording wakes it; starting may take a moment."
    }

    private var dashboardSubtitle: String {
        if isForcedOnByAlwaysOnMode {
            return "Always-on mode already keeps the mic live. Switch to Manual to control standby behavior."
        }
        if keepMicReadyEnabled {
            return "Faster starts. The microphone stays active between recordings."
        }
        return "Microphone off between recordings. Starting may take a moment."
    }
}
