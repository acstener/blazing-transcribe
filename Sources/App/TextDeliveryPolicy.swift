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

// MARK: - Focused text target (decision 6: no focused field → clipboard)

extension TextDeliveryPolicy {
    enum FocusedTextTarget: Equatable {
        /// A text field / text area / settable value has focus: type into it.
        case editable
        /// The app clearly has nothing to type into (no focused element, or a
        /// definite non-text control). Copy to the clipboard instead.
        case noTextField
        /// Can't tell (custom views, web content, apps with partial AX). Keep typing,
        /// which is the historic behaviour — a false "no field" would be worse.
        case unknown
    }

    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    /// Roles that can never accept typed text.
    static let nonTextRoles: Set<String> = [
        "AXWindow", "AXApplication", "AXButton", "AXList", "AXOutline", "AXTable",
        "AXBrowser", "AXImage", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXToolbar", "AXTabGroup", "AXRow", "AXCell", "AXSlider",
        "AXDisclosureTriangle", "AXStaticText", "AXSplitter", "AXMenuBar", "AXMenu",
        "AXMenuItem", "AXIncrementor", "AXColorWell", "AXLevelIndicator",
    ]

    /// Finder's desktop and window backgrounds report generic containers.
    static let finderNonTextRoles: Set<String> = ["AXScrollArea", "AXGroup", "AXSplitGroup"]

    /// - Parameter role: the focused element's role, or nil when the app reports
    ///   that *nothing* is focused.
    static func classifyFocusedElement(
        role: String?,
        subrole: String?,
        isValueSettable: Bool,
        hasSelectedTextRange: Bool,
        bundleIdentifier: String?
    ) -> FocusedTextTarget {
        guard let role else { return .noTextField }
        if editableRoles.contains(role) || subrole == "AXSecureTextField"
            || isValueSettable || hasSelectedTextRange {
            return .editable
        }
        if nonTextRoles.contains(role) {
            return .noTextField
        }
        if bundleIdentifier == "com.apple.finder", finderNonTextRoles.contains(role) {
            return .noTextField
        }
        return .unknown
    }

    /// Only native apps with dependable accessibility trees can prove there's no
    /// text field. Browsers, terminals and Electron apps often report a window or
    /// nothing at all while a text box is focused, so we never second-guess them.
    static func canTrustNoTextFieldSignal(
        bundleIdentifier: String?,
        appName: String?,
        isElectronApp: Bool
    ) -> Bool {
        if isElectronApp { return false }
        if BrowserHostPolicy.prefersDirectRealtimeTyping(bundleIdentifier: bundleIdentifier, appName: appName) {
            return false
        }
        if TerminalHostPolicy.isTerminalLike(bundleIdentifier: bundleIdentifier, appName: appName)
            || TerminalHostPolicy.isPasteUnsafeTarget(bundleIdentifier: bundleIdentifier, appName: appName) {
            return false
        }
        return true
    }

    static let noTextFieldClipboardMessage = "Copied — no text field was focused"
}
