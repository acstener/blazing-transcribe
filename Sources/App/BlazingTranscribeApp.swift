import SwiftUI

@main
struct BlazingTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Blazing Transcribe", id: "main") {
            MainWindowView()
                .environment(appDelegate.viewModel)

        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            #if DEBUG
            CommandGroup(after: .appInfo) {
                if Bundle.main.bundleIdentifier == "com.blazingtranscribe.experience-preview" {
                    Button("Preview menu bar") { appDelegate.openExperiencePreviewMenu() }
                }
            }
            #endif
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
