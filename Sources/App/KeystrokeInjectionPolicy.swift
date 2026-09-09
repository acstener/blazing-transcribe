import Foundation

enum FocusedElementKind: Equatable {
    case none
    case editableText
    case searchField
    case webArea
    case other
}

/// Gates synthetic keystrokes so always-on dictation cannot drive browser
/// page shortcuts (Firefox/Safari Find-as-you-type is the same UI as Cmd+F).
enum KeystrokeInjectionPolicy {
    static func classify(role: String?, subrole: String?, valueIsSettable: Bool) -> FocusedElementKind {
        let role = role ?? ""
        let subrole = subrole ?? ""

        if subrole == "AXSecureTextField" {
            return .other
        }
        if role == "AXSearchField" || subrole == "AXSearchField" {
            return .searchField
        }
        if role == "AXWebArea" {
            return .webArea
        }
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return .editableText
        }
        if valueIsSettable {
            return .editableText
        }
        if role.isEmpty && subrole.isEmpty {
            return .none
        }
        return .other
    }

    static func shouldInjectKeystrokes(
        bundleIdentifier: String?,
        appName: String?,
        focused: FocusedElementKind
    ) -> Bool {
        guard BrowserHostPolicy.isBrowser(bundleIdentifier: bundleIdentifier, appName: appName) else {
            return true
        }
        switch focused {
        case .editableText, .searchField:
            return true
        case .none, .webArea, .other:
            return false
        }
    }
}
