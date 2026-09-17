import SwiftUI

@main
struct BlazingTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Blazing Transcribe", id: "main") {
            MainWindowView()
                .environment(appDelegate.viewModel)
                // Appearance is applied on the window contents (system / light / dark).
                // Avoid NSApp.appearance here: the recording overlay manages its own look.
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
    }
}
