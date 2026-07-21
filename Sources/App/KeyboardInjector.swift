import AppKit
import ApplicationServices
import CoreGraphics

/// Injects text into the focused application via CGEvent keyboard events.
/// Requires Accessibility permission.
final class KeyboardInjector {
    private let maxAXValueReplacementUTF16Count = 8_192

    /// Type a string into the currently focused app using CGEvent unicode injection.
    func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }

        // CGEvent supports up to 20 UTF-16 code units per event
        let chunkSize = 20
        let source = CGEventSource(stateID: .hidSystemState)

        for chunkStart in stride(from: 0, to: utf16.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, utf16.count)
            let chunk = Array(utf16[chunkStart..<chunkEnd])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []

            chunk.withUnsafeBufferPointer { ptr in
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr.baseAddress!)
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr.baseAddress!)
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Small delay between chunks to avoid dropped events
            if chunkEnd < utf16.count {
                usleep(2000) // 2ms
            }
        }
    }

    /// Apply a streaming delta in apps that don't expose an editable AX text range,
    /// such as terminals. This assumes the cursor is still at the end of the text
    /// we previously injected for the active utterance.
    func applyStreamingDelta(from currentText: String, to newText: String) -> Bool {
        if currentText == newText {
            return true
        }

        let currentCharacters = Array(currentText)
        let newCharacters = Array(newText)
        let prefixCount = sharedCharacterPrefixCount(currentCharacters, newCharacters)
        let deleteCount = currentCharacters.count - prefixCount
        let suffix = String(newCharacters.dropFirst(prefixCount))

        guard sendDeleteBackward(count: deleteCount) else {
            return false
        }

        // Settle delay: let the terminal process deletes before retyping
        if deleteCount > 0, !suffix.isEmpty {
            usleep(1000) // 1ms
        }

        if !suffix.isEmpty {
            typeText(suffix)
        }

        return true
    }

    /// Public wrapper for deleting backward (e.g. for terminal inline corrections).
    @discardableResult
    func deleteBackward(count: Int) -> Bool {
        sendDeleteBackward(count: count)
    }

    /// Send Cmd+V (paste) via CGEvent.
    @discardableResult
    func sendCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        // Virtual key 9 = 'v'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func typeTrailingSpace() -> Bool {
        sendKeyPress(virtualKey: 49)
    }

    /// Send Ctrl+U (kill line) to clear text from cursor to beginning of line.
    /// Used for large terminal corrections where backspacing many chars would be slow.
    @discardableResult
    func sendKillLine() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        // Virtual key 32 = 'u'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 32, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 32, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskControl
        keyUp.flags = .maskControl
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Whether the app has Accessibility permission.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user for Accessibility permission if not already granted.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Capture the currently focused UI element for an app (for origin field restoration).
    func captureOriginElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard result == .success, let element = focusedObject else { return nil }
        return (element as! AXUIElement)
    }

    /// Capture the window containing a focused element.
    func captureOriginWindow(for element: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef)
        guard result == .success, let window = windowRef else { return nil }
        return (window as! AXUIElement)
    }

    /// Raise a previously captured window to front (for same-app, different-window switches).
    @discardableResult
    func raiseOriginWindow(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    /// Restore focus to a previously captured UI element.
    @discardableResult
    func restoreOriginElement(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    func beginProvisionalSession() -> ProvisionalTextSession? {
        guard Self.hasAccessibilityPermission,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              let focusedElement = focusedEditableElement(for: frontmost.processIdentifier),
              let selectedRange = selectedTextRange(for: focusedElement),
              selectedRange.length == 0 else {
            return nil
        }

        return ProvisionalTextSession(
            appPID: frontmost.processIdentifier,
            element: focusedElement,
            anchorLocation: selectedRange.location
        )
    }

    func updateProvisionalText(_ text: String, session: ProvisionalTextSession) -> ProvisionalTextUpdateOutcome {
        guard text != session.currentText else { return .unchanged }
        guard validateFocus(for: session) else {
            return handleSessionFailure(
                session,
                reason: "focusChanged",
                suppressFinalCommit: session.typedText
            )
        }

        let mutation = ProvisionalTextMutationPlan.build(from: session.currentText, to: text)
        guard mutation.replacedUTF16Count > 0 || !mutation.replacementSuffix.isEmpty else {
            return .unchanged
        }

        guard replaceOwnedText(
            in: session,
            fromUTF16Offset: mutation.commonPrefixUTF16Count,
            replacedUTF16Count: mutation.replacedUTF16Count,
            replacement: mutation.replacementSuffix
        ) else {
            return handleSessionFailure(
                session,
                reason: "replaceFailed",
                suppressFinalCommit: session.typedText
            )
        }

        session.currentText = text
        session.typedText = !text.isEmpty
        session.consecutiveFailures = 0
        return .updated
    }

    func commitFinalText(_ text: String, session: ProvisionalTextSession) -> ProvisionalTextUpdateOutcome {
        guard validateFocus(for: session) else {
            return handleSessionFailure(
                session,
                reason: "focusChanged",
                suppressFinalCommit: session.typedText
            )
        }

        let mutation = ProvisionalTextMutationPlan.build(from: session.currentText, to: text)
        guard mutation.replacedUTF16Count > 0 || !mutation.replacementSuffix.isEmpty else {
            return .unchanged
        }

        guard replaceOwnedText(
            in: session,
            fromUTF16Offset: mutation.commonPrefixUTF16Count,
            replacedUTF16Count: mutation.replacedUTF16Count,
            replacement: mutation.replacementSuffix
        ) else {
            return handleSessionFailure(
                session,
                reason: "replaceFailed",
                suppressFinalCommit: session.typedText
            )
        }

        session.currentText = text
        session.typedText = !text.isEmpty
        session.consecutiveFailures = 0
        return text.isEmpty ? .unchanged : .updated
    }

    func cancelProvisionalSession(_ session: ProvisionalTextSession) {
        if validateFocus(for: session) {
            collapseSelection(
                toUTF16Offset: session.currentText.utf16.count,
                in: session
            )
        }
        session.currentText = ""
        session.typedText = false
        session.consecutiveFailures = 0
    }

    private func focusedEditableElement(for processIdentifier: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedResult == .success, let focusedElement = focusedObject else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        guard isEditableTextElement(element) else { return nil }
        return element
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute as CFString, for: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, for: element) ?? ""

        if subrole == "AXSecureTextField" {
            return false
        }

        let supportedRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXSearchFieldSubrole as String,
            kAXComboBoxRole as String,
        ]

        if supportedRoles.contains(role) {
            return true
        }

        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private func validateFocus(for session: ProvisionalTextSession) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == session.appPID,
              let focusedElement = focusedEditableElement(for: session.appPID) else {
            return false
        }

        return CFEqual(focusedElement, session.element)
    }

    private func replaceOwnedText(
        in session: ProvisionalTextSession,
        fromUTF16Offset utf16Offset: Int,
        replacedUTF16Count: Int,
        replacement: String
    ) -> Bool {
        if replaceOwnedTextViaAXValue(
            in: session,
            fromUTF16Offset: utf16Offset,
            replacedUTF16Count: replacedUTF16Count,
            replacement: replacement
        ) {
            return true
        }

        let selectedRange = CFRange(
            location: session.anchorLocation + utf16Offset,
            length: replacedUTF16Count
        )

        guard setSelectedTextRange(selectedRange, for: session.element) else {
            return false
        }

        if replacement.isEmpty {
            guard replacedUTF16Count == 0 || sendDeleteBackward(count: replacedUTF16Count) else {
                return false
            }
        } else {
            typeText(replacement)
        }

        return true
    }

    private func replaceOwnedTextViaAXValue(
        in session: ProvisionalTextSession,
        fromUTF16Offset utf16Offset: Int,
        replacedUTF16Count: Int,
        replacement: String
    ) -> Bool {
        guard let currentValue = stringAttribute(kAXValueAttribute as CFString, for: session.element) else {
            return false
        }

        let nsCurrentValue = currentValue as NSString
        guard nsCurrentValue.length <= maxAXValueReplacementUTF16Count else {
            return false
        }

        let absoluteLocation = session.anchorLocation + utf16Offset
        guard absoluteLocation >= 0,
              replacedUTF16Count >= 0,
              absoluteLocation <= nsCurrentValue.length,
              absoluteLocation + replacedUTF16Count <= nsCurrentValue.length else {
            return false
        }

        let replacementRange = NSRange(location: absoluteLocation, length: replacedUTF16Count)
        let updatedValue = nsCurrentValue.replacingCharacters(in: replacementRange, with: replacement)
        guard AXUIElementSetAttributeValue(
            session.element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        ) == .success else {
            return false
        }

        let insertionLocation = absoluteLocation + (replacement as NSString).length
        _ = setSelectedTextRange(CFRange(location: insertionLocation, length: 0), for: session.element)
        return true
    }

    private func handleSessionFailure(
        _ session: ProvisionalTextSession,
        reason: String,
        suppressFinalCommit: Bool
    ) -> ProvisionalTextUpdateOutcome {
        session.consecutiveFailures += 1
        if session.consecutiveFailures >= 2 {
            return .fallback(reason: reason, suppressFinalCommit: suppressFinalCommit)
        }
        return .fallback(reason: "\(reason)-retry", suppressFinalCommit: false)
    }

    @discardableResult
    private func collapseSelection(toUTF16Offset utf16Offset: Int, in session: ProvisionalTextSession) -> Bool {
        let insertionPoint = CFRange(location: session.anchorLocation + utf16Offset, length: 0)
        return setSelectedTextRange(insertionPoint, for: session.element)
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value as? String
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func setSelectedTextRange(_ range: CFRange, for element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private func sendDeleteBackward(count: Int = 1) -> Bool {
        guard count >= 0 else { return false }
        guard count > 0 else { return true }

        for _ in 0..<count {
            guard sendKeyPress(virtualKey: 51) else {
                return false
            }
        }
        return true
    }

    private func sendKeyPress(virtualKey: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }

        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Public accessor for shared prefix length (used by terminal shadow cleanup).
    func sharedPrefixCount(_ lhs: [Character], _ rhs: [Character]) -> Int {
        sharedCharacterPrefixCount(lhs, rhs)
    }

    private func sharedCharacterPrefixCount(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }
}
