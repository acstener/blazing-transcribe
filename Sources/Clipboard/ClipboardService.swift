import AppKit

/// Simple wrapper around NSPasteboard for copying transcriptions to clipboard.
public final class ClipboardService {
    public init() {}

    /// Clear the system clipboard.
    public func clear() {
        NSPasteboard.general.clearContents()
    }

    /// Copy text to the system clipboard.
    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Read current clipboard contents.
    public func read() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
