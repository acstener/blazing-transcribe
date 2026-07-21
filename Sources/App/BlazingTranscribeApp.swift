import SwiftUI

@main
struct BlazingTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Blazing Transcribe", id: "main") {
            MainWindowView()
                .environment(appDelegate.viewModel)
                // Keep the main app window on a fixed light appearance for now.
                // Avoid NSApp.appearance here: the recording overlay manages its own look.
                .btWindowAppearance(.aqua)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
    }
}
