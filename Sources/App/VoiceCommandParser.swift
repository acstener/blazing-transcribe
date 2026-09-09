import Foundation

enum VoiceCommand: Equatable {
    case deleteThat
    case copy
    case paste
}

enum VoiceCommandEffect: Equatable {
    case deleteCharacters(Int)
    case copyToClipboard(String)
    case pressCopy
    case pressPaste
    case none
}

/// Whole-utterance commands, matching macOS Voice Control's basic phrases.
enum VoiceCommandParser {
    static func parse(_ raw: String) -> VoiceCommand? {
        switch normalize(raw) {
        case "delete that", "scratch that":
            return .deleteThat
        case "copy that", "copy":
            return .copy
        case "paste that", "paste":
            return .paste
        default:
            return nil
        }
    }

    static func effect(for command: VoiceCommand, lastDictatedText: String) -> VoiceCommandEffect {
        switch command {
        case .deleteThat:
            return lastDictatedText.isEmpty ? .none : .deleteCharacters(lastDictatedText.count)
        case .copy:
            let trimmed = lastDictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .pressCopy : .copyToClipboard(trimmed)
        case .paste:
            return .pressPaste
        }
    }

    static func streamedTextLooksLikeCommand(_ streamed: String, commandText: String) -> Bool {
        let streamedNorm = normalize(streamed)
        let commandNorm = normalize(commandText)
        guard !streamedNorm.isEmpty, !commandNorm.isEmpty else { return false }
        // Only retract in-progress typing of this command, not a previous utterance
        // that happens to start with "copy" / "paste".
        return commandNorm.hasPrefix(streamedNorm)
    }

    static func normalize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = String(raw.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return filtered
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
