import SwiftUI
import AudioEngine
import CoreAudio

struct AudioSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var selectedDevice: String = UserDefaults.standard.string(forKey: "preferredInputDevice") ?? ""
    @State private var silenceTimeout: Double = UserDefaults.standard.object(forKey: "silenceTimeout") != nil
        ? UserDefaults.standard.double(forKey: "silenceTimeout") : 0.5
    @State private var vadThreshold: Double = UserDefaults.standard.object(forKey: "vadThreshold") != nil
        ? UserDefaults.standard.double(forKey: "vadThreshold") : 0.35
    @State private var cachedDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BTSpacing.lg) {
                Text("Audio")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)

                // Input device picker
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Input device")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.sm) {
                            if cachedDevices.isEmpty {
                                Text("No input devices found")
                                    .font(.btBody)
                                    .foregroundStyle(Color.btSecondaryText)
                            } else {
                                // An empty preference means "follow the macOS default input".
                                deviceRow("System default", detail: "Follows your Mac's input setting",
                                          isSelected: selectedDevice.isEmpty) {
                                    selectedDevice = ""
                                    UserDefaults.standard.removeObject(forKey: "preferredInputDevice")
                                    viewModel.audioCapture?.setInputDevice(0)
                                }
                                ForEach(cachedDevices, id: \.id) { device in
                                    deviceRow(device.name, isSelected: selectedDevice == device.name) {
                                        selectedDevice = device.name
                                        UserDefaults.standard.set(device.name, forKey: "preferredInputDevice")
                                        viewModel.audioCapture?.setInputDevice(device.id)
                                    }
                                }
                                if !selectedDevice.isEmpty, !cachedDevices.contains(where: { $0.name == selectedDevice }) {
                                    deviceRow(selectedDevice, detail: "Not connected — using the system default until it's back",
                                              isSelected: true) {}
                                        .disabled(true)
                                }
                            }
                        }
                    }
                }

                // Audio level
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Audio level")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        AudioLevelWaveform(meter: viewModel.audioLevelMeter)
                            .frame(height: 48)
                    }
                }

                // Advanced
                VStack(alignment: .leading, spacing: BTSpacing.sm) {
                    Text("Advanced")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.btText)

                    BTCard {
                        VStack(alignment: .leading, spacing: BTSpacing.md) {
                            VStack(alignment: .leading, spacing: BTSpacing.xs) {
                                BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 320) {
                                    Text("Silence timeout")
                                        .font(.btBody)
                                        .foregroundStyle(Color.btText)
                                } trailing: {
                                    Text(String(format: "%.2fs", silenceTimeout))
                                        .font(.btMono)
                                        .foregroundStyle(Color.btSecondaryText)
                                }
                                Slider(value: $silenceTimeout, in: 0.2...2.0, step: 0.05)
                                    .onChange(of: silenceTimeout) { _, newValue in
                                        UserDefaults.standard.set(newValue, forKey: "silenceTimeout")
                                        viewModel.audioCapture?.silenceTimeout = newValue
                                    }
                                Text("Lower makes always-on end faster. Higher gives you more room for mid-sentence thinking pauses.")
                                    .font(.btCaption)
                                    .foregroundStyle(Color.btSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(alignment: .leading, spacing: BTSpacing.xs) {
                                BTTrailingActionRow(horizontalAlignment: .center, horizontalMinWidth: 320) {
                                    Text("Voice detection threshold")
                                        .font(.btBody)
                                        .foregroundStyle(Color.btText)
                                } trailing: {
                                    Text(String(format: "%.2f", vadThreshold))
                                        .font(.btMono)
                                        .foregroundStyle(Color.btSecondaryText)
                                }
                                Slider(value: $vadThreshold, in: 0.1...0.9, step: 0.05)
                                    .onChange(of: vadThreshold) { _, newValue in
                                        UserDefaults.standard.set(newValue, forKey: "vadThreshold")
                                        viewModel.audioCapture?.vadThreshold = Float(newValue)
                                    }
                            }
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
            if cachedDevices.isEmpty {
                let t = CFAbsoluteTimeGetCurrent()
                cachedDevices = AudioCaptureService.availableInputDevices
                print("[TabPerf] AudioSettingsView device query: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t) * 1000))ms (\(cachedDevices.count) devices)")
            }
        }
    }
}

private extension AudioSettingsView {
    func deviceRow(_ name: String, detail: String? = nil, isSelected: Bool,
                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BTSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.btBody.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.btText)
                    if let detail {
                        Text(detail)
                            .font(.btCaption)
                            .foregroundStyle(Color.btSecondaryText)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.btText)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.vertical, BTSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small subview that reads only AudioLevelMeter, so the parent body doesn't re-render at 60Hz.
private struct AudioLevelWaveform: View {
    let meter: AudioLevelMeter

    var body: some View {
        WaveformSwiftUI(audioLevel: meter.level)
    }
}
