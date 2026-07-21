import Foundation

enum TextDeliveryMethod: Equatable {
    case typing
    case clipboardPaste
}

enum TextDeliveryPolicy {
    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func method(
        for text: String,
        bundleIdentifier: String?,
        appName: String?
    ) -> TextDeliveryMethod {
        let normalizedText = normalizedText(text)
        guard normalizedText.contains(where: \.isNewline) else {
            return .typing
        }

        if TerminalHostPolicy.isPasteUnsafeTarget(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        ) {
            return .typing
        }

        return .clipboardPaste
    }
}
