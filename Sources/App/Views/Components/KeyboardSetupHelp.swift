import SwiftUI
import AppKit

struct KeyboardSetupHelp: View {
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Does fn open Emoji or Apple Dictation?", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Open System Settings → Keyboard.\n2. Set ‘Press fn key to’ (or ‘Press 🌐 key to’) to ‘Do Nothing’.\n3. Under Dictation, choose a shortcut other than pressing fn twice.\n4. Return here and try your shortcut again.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Changing the Dictation shortcut can also change the fn setting. Check both. You can keep your Mac’s shortcuts and choose a different Blazing shortcut instead.")
                    .foregroundStyle(Color.btSecondaryText)
                Button("Open Keyboard Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }.font(.system(size: 13)).padding(.top, 12)
        }.font(.system(size: 13, weight: .medium))
    }
}
