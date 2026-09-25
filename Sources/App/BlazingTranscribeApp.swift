import SwiftUI

@main
struct BlazingTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Blazing Transcribe", id: "main") {
            MainWindowView()
                .environment(appDelegate.viewModel)

        }
        // Blazing lives in the menu bar: don't pop the window on launch or after an
        // update relaunch. AppDelegate opens it only while onboarding is unfinished.
        .defaultLaunchBehavior(.suppressed)
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
