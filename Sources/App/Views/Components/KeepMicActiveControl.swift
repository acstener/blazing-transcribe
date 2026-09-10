import SwiftUI

struct KeepMicActiveControl: View {
    @Environment(AppViewModel.self) private var viewModel

    enum Style {
        case settingsCard
        case dashboardFooter
    }

    let style: Style

    @AppStorage("disableKeepMicReady") private var disableKeepMicReady = true
    /// 0 = never sleep. Defaults to 15 — sleep-when-idle is on out of the box.
    @AppStorage("micIdleSleepMinutes") private var micIdleSleepMinutes = 15

    private static let idleSleepMinuteOptions = [0, 5, 10, 15, 30, 60]

    private var isForcedOnByAlwaysOnMode: Bool {
        viewModel.recordingMode == .alwaysOn
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
                    Text("Keep Mic Active")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                    Text(settingsSubtitle)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: keepMicReadyBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .allowsHitTesting(!isForcedOnByAlwaysOnMode)

            if keepMicReadyEnabled {
                Divider()

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep When Idle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.btText)
                        Text(idleSleepSubtitle)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("", selection: idleSleepMinutesBinding) {
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

                Text("Keep Mic Active")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.btText)

                Text(dashboardSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: BTSpacing.md)

            Toggle("", isOn: keepMicReadyBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .allowsHitTesting(!isForcedOnByAlwaysOnMode)
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
        .shadow(color: Color.btCardShadow, radius: 4, y: 2)
    }

    private var settingsSubtitle: String {
        if isForcedOnByAlwaysOnMode {
            return "Always-on has to keep the mic open, so macOS shows the orange privacy light. Switch to Manual, or use Toggle Mic, to turn that light off."
        }
        return "Off by default so the orange privacy light is not stuck on. Turn it on only if you want instant Manual start (~0.7s faster, orange light stays between presses)."
    }

    private var idleSleepSubtitle: String {
        guard micIdleSleepMinutes > 0 else {
            return "Turn the mic fully off after a period without dictation, clearing the orange indicator until you use it again."
        }
        if isForcedOnByAlwaysOnMode {
            return "Mic turns off after \(micIdleSleepMinutes) min without dictation. The orange light clears while asleep — press a recording shortcut or Toggle Mic to wake it."
        }
        return "Mic turns off after \(micIdleSleepMinutes) min without dictation. Your next recording starts about 0.7s slower, then stays warm again."
    }

    private var dashboardSubtitle: String {
        if isForcedOnByAlwaysOnMode {
            return "Always-on keeps the mic live, so the orange privacy light stays on. Switch to Manual or use Toggle Mic to clear it."
        }
        if keepMicReadyEnabled {
            return "Manual recording starts instantly. The orange privacy light stays on between presses."
        }
        return "Mic is fully off between presses. No orange privacy light until you record."
    }
}
