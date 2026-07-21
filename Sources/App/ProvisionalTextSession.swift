import ApplicationServices
import Foundation

struct ProvisionalTextMutationPlan: Equatable {
    let commonPrefixUTF16Count: Int
    let replacedUTF16Count: Int
    let replacementSuffix: String

    static func build(from currentText: String, to newText: String) -> ProvisionalTextMutationPlan {
        let commonPrefixUTF16Count = sharedUTF16PrefixCount(currentText, newText)
        let replacedUTF16Count = currentText.utf16.count - commonPrefixUTF16Count
        let replacementSuffix = utf16Suffix(of: newText, dropping: commonPrefixUTF16Count)
        return ProvisionalTextMutationPlan(
            commonPrefixUTF16Count: commonPrefixUTF16Count,
            replacedUTF16Count: replacedUTF16Count,
            replacementSuffix: replacementSuffix
        )
    }

    private static func sharedUTF16PrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var lhsIndex = lhs.utf16.startIndex
        var rhsIndex = rhs.utf16.startIndex

        while lhsIndex < lhs.utf16.endIndex, rhsIndex < rhs.utf16.endIndex,
              lhs.utf16[lhsIndex] == rhs.utf16[rhsIndex] {
            count += 1
            lhs.utf16.formIndex(after: &lhsIndex)
            rhs.utf16.formIndex(after: &rhsIndex)
        }

        return count
    }

    private static func utf16Suffix(of text: String, dropping utf16Count: Int) -> String {
        guard utf16Count > 0 else { return text }
        guard utf16Count < text.utf16.count else { return "" }

        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Count)
        guard let stringIndex = String.Index(utf16Index, within: text) else {
            return text
        }
        return String(text[stringIndex...])
    }
}

final class ProvisionalTextSession {
    let appPID: pid_t
    let element: AXUIElement
    let anchorLocation: Int

    var currentText: String
    var typedText: Bool
    var consecutiveFailures: Int

    init(
        appPID: pid_t,
        element: AXUIElement,
        anchorLocation: Int,
        currentText: String = "",
        typedText: Bool = false,
        consecutiveFailures: Int = 0
    ) {
        self.appPID = appPID
        self.element = element
        self.anchorLocation = anchorLocation
        self.currentText = currentText
        self.typedText = typedText
        self.consecutiveFailures = consecutiveFailures
    }
}

enum ProvisionalTextUpdateOutcome: Equatable {
    case updated
    case unchanged
    case fallback(reason: String, suppressFinalCommit: Bool)
}
