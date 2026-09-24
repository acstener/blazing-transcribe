import SwiftUI

// The native switch/checkbox tinted with `btAccent` loses its knob/checkmark in dark
// mode (near-white fill under a near-white knob), so Blazing draws its own.

/// Monochrome switch: `btAccent` track with a `btAccentForeground` knob when on.
struct BTSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BTSwitch(configuration: configuration)
    }
}

private struct BTSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Custom styles must honour `.labelsHidden()` themselves.
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        HStack(spacing: BTSpacing.sm) {
            if labelsVisibility != .hidden {
                configuration.label
            }
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Color.btAccent : Color.btActiveBackground)
                    Capsule()
                        .strokeBorder(Color.btBorder, lineWidth: configuration.isOn ? 0 : 1)
                    Circle()
                        .fill(configuration.isOn ? Color.btAccentForeground : Color.btCardBackground)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .padding(2)
                }
                .frame(width: 32, height: 18)
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : .btSnappy, value: configuration.isOn)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Monochrome checkbox: `btAccent` fill with a `btAccentForeground` checkmark when on.
struct BTCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BTCheckbox(configuration: configuration)
    }
}

private struct BTCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Color.btAccent : Color.btCardBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.btSecondaryText.opacity(0.45), lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.btAccentForeground)
                    }
                }
                .frame(width: 14, height: 14)
                if labelsVisibility != .hidden {
                    configuration.label
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == BTSwitchToggleStyle {
    static var btSwitch: BTSwitchToggleStyle { BTSwitchToggleStyle() }
}

extension ToggleStyle where Self == BTCheckboxToggleStyle {
    static var btCheckbox: BTCheckboxToggleStyle { BTCheckboxToggleStyle() }
}
