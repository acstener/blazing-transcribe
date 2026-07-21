import AppKit
import Foundation
import Observation
import Transcription

struct CustomVocabularyCodec {
    struct ParsedEntry: Equatable {
        let canonical: String
        let aliases: [String]
    }

    static let template = """
    # Custom Vocabulary — Blazing Fast Transcription
    # Format: CanonicalForm: alias1, alias2, ...
    # Lines starting with # are comments.
    #
    # Examples:
    # MyCompany: my company, my comp
    # Alex Christou: alex christu, alex chris too
    #
    # Save from the app to reload the regex dictionary immediately.

    """

    static func parse(_ content: String) -> [ParsedEntry] {
        content
            .components(separatedBy: .newlines)
            .compactMap(parseLine(_:))
    }

    static func serialize(entries: [CustomVocabularyStore.Entry]) -> String {
        let normalizedLines = entries.compactMap { entry -> String? in
            let canonical = normalizeCanonical(entry.canonical)
            guard !canonical.isEmpty else { return nil }

            let aliases = aliases(from: entry.aliasesText, canonical: canonical)
            if aliases.isEmpty {
                return canonical
            }

            return "\(canonical): \(aliases.joined(separator: ", "))"
        }

        if normalizedLines.isEmpty {
            return template
        }

        return template + normalizedLines.joined(separator: "\n") + "\n"
    }

    static func aliases(from raw: String, canonical: String) -> [String] {
        let normalizedCanonical = normalizeCanonical(canonical).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var seen = Set<String>()
        var ordered: [String] = []

        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let alias = normalizeAlias(String(part))
            guard !alias.isEmpty else { continue }

            let folded = alias.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard folded != normalizedCanonical else { continue }
            guard seen.insert(folded).inserted else { continue }
            ordered.append(alias)
        }

        return ordered
    }

    static func normalizeCanonical(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeAlias(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseLine(_ rawLine: String) -> ParsedEntry? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if let colonIndex = trimmed.firstIndex(of: ":") {
            let canonical = normalizeCanonical(String(trimmed[..<colonIndex]))
            guard !canonical.isEmpty else { return nil }

            let aliasText = String(trimmed[trimmed.index(after: colonIndex)...])
            let aliases = aliases(from: aliasText, canonical: canonical)
            return ParsedEntry(canonical: canonical, aliases: aliases)
        }

        let canonical = normalizeCanonical(trimmed)
        guard !canonical.isEmpty else { return nil }
        return ParsedEntry(canonical: canonical, aliases: [])
    }
}

@MainActor
@Observable
final class CustomVocabularyStore {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        var canonical: String
        var aliasesText: String

        init(id: UUID = UUID(), canonical: String, aliasesText: String) {
            self.id = id
            self.canonical = canonical
            self.aliasesText = aliasesText
        }
    }

    private struct MergeSummary {
        var insertedCount = 0
        var updatedCount = 0
        var newAliasCount = 0

        var madeChanges: Bool {
            insertedCount > 0 || updatedCount > 0
        }

        func statusMessage(totalTerms: Int) -> String {
            if insertedCount > 0, updatedCount == 0 {
                return "Added \(insertedCount) term\(insertedCount == 1 ? "" : "s")."
            }

            if insertedCount == 0, updatedCount > 0 {
                if newAliasCount > 0 {
                    return "Updated \(updatedCount) term\(updatedCount == 1 ? "" : "s") with \(newAliasCount) new alias\(newAliasCount == 1 ? "" : "es")."
                }

                return "Updated \(updatedCount) term\(updatedCount == 1 ? "" : "s")."
            }

            return "Saved \(totalTerms) term\(totalTerms == 1 ? "" : "s")."
        }
    }

    static let directoryName = "BlazingFastTranscription"
    static let fileName = "custom-vocabulary.txt"

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var entries: [Entry] = []
    var newTermInput: String = ""
    var statusMessage: String?
    var warningMessage: String?
    var errorMessage: String?
    var isGenerating: Bool = false
    private var ignoresNextChangeNotification = false

    init() {
        load()
    }

    var activeTermCount: Int {
        entries
            .map { CustomVocabularyCodec.normalizeCanonical($0.canonical) }
            .filter { !$0.isEmpty }
            .count
    }

    var isGeminiConfigured: Bool {
        !LLMCleanupService.geminiAPIKey.isEmpty
    }

    var canAddTerm: Bool {
        !newTermInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    func load() {
        clearMessages()

        do {
            try Self.ensureFileExists()
            let content = try String(contentsOf: Self.fileURL, encoding: .utf8)
            applyParsedEntries(CustomVocabularyCodec.parse(content))
        } catch {
            errorMessage = "Could not load dictionary: \(error.localizedDescription)"
        }
    }

    func addTerm() async {
        let pendingInput = newTermInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingInput.isEmpty else { return }

        clearMessages()
        isGenerating = true
        defer { isGenerating = false }

        do {
            // Gemini generates thorough ASR aliases, deterministic rules as fallback
            var generatedEntries: [GeminiVocabularySuggestionService.GeneratedEntry]
            var generationWarning: String?

            if isGeminiConfigured {
                do {
                    let geminiEntries = try await GeminiVocabularySuggestionService.shared.generateEntries(from: pendingInput)
                    let deterministicResults = deterministicEntries(from: pendingInput)
                    generatedEntries = mergeEntrySets(base: geminiEntries, overlay: deterministicResults)
                    generationWarning = nil
                } catch {
                    generatedEntries = deterministicEntries(from: pendingInput)
                    generationWarning = "Gemini unavailable — using local alias generation."
                }
            } else {
                generatedEntries = deterministicEntries(from: pendingInput)
                generationWarning = nil
            }

            guard !generatedEntries.isEmpty else {
                errorMessage = "Could not add to dictionary."
                return
            }

            let summary = mergeGeneratedEntries(generatedEntries)
            newTermInput = ""

            guard summary.madeChanges else {
                statusMessage = "Everything you added is already in your dictionary."
                return
            }

            try persistEntries()
            statusMessage = summary.statusMessage(totalTerms: activeTermCount)
            warningMessage = generationWarning
            errorMessage = nil
        } catch {
            let message = "Could not save dictionary: \(error.localizedDescription)"
            load()
            newTermInput = pendingInput
            errorMessage = message
        }
    }

    private func deterministicEntries(from input: String) -> [GeminiVocabularySuggestionService.GeneratedEntry] {
        let separators = CharacterSet(charactersIn: ",\n")
        let rawTerms = input
            .components(separatedBy: separators)
            .map { CustomVocabularyCodec.normalizeCanonical($0) }
            .filter { !$0.isEmpty }

        let terms = rawTerms.isEmpty ? [input] : rawTerms
        var seen = Set<String>()
        var entries: [GeminiVocabularySuggestionService.GeneratedEntry] = []

        for term in terms {
            let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(folded).inserted else { continue }
            let aliases = DeterministicAliasGenerator.generateAliases(for: term)
            entries.append(.init(canonical: term, aliases: aliases))
        }

        return entries
    }

    private func mergeEntrySets(
        base: [GeminiVocabularySuggestionService.GeneratedEntry],
        overlay: [GeminiVocabularySuggestionService.GeneratedEntry]
    ) -> [GeminiVocabularySuggestionService.GeneratedEntry] {
        var merged = base
        for overlayEntry in overlay {
            let canonicalFolded = overlayEntry.canonical.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            if let idx = merged.firstIndex(where: {
                $0.canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == canonicalFolded
            }) {
                // Merge aliases
                var existingAliases = Set(merged[idx].aliases.map {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                })
                var combinedAliases = merged[idx].aliases
                for alias in overlayEntry.aliases {
                    let folded = alias.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    if existingAliases.insert(folded).inserted {
                        combinedAliases.append(alias)
                    }
                }
                merged[idx] = .init(canonical: overlayEntry.canonical, aliases: combinedAliases)
            } else {
                merged.append(overlayEntry)
            }
        }
        return merged
    }

    func removeEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        clearMessages()
        let removedCanonical = CustomVocabularyCodec.normalizeCanonical(entries[index].canonical)
        entries.remove(at: index)

        do {
            try persistEntries()
            statusMessage = entries.isEmpty
                ? "Removed \(removedCanonical). The custom dictionary is now empty."
                : "Removed \(removedCanonical)."
            errorMessage = nil
        } catch {
            let message = "Could not save dictionary: \(error.localizedDescription)"
            load()
            errorMessage = message
        }
    }

    func openRawFile() {
        do {
            try Self.ensureFileExists()
            NSWorkspace.shared.open(Self.fileURL)
        } catch {
            errorMessage = "Could not open dictionary file: \(error.localizedDescription)"
        }
    }

    private func clearMessages() {
        statusMessage = nil
        warningMessage = nil
        errorMessage = nil
    }

    func consumeLocalChangeNotification() -> Bool {
        guard ignoresNextChangeNotification else { return false }
        ignoresNextChangeNotification = false
        return true
    }

    private func applyParsedEntries(_ parsedEntries: [CustomVocabularyCodec.ParsedEntry]) {
        entries = parsedEntries.map { parsed in
            Entry(
                canonical: parsed.canonical,
                aliasesText: parsed.aliases.joined(separator: ", ")
            )
        }
    }

    private func mergeAliases(existing: [String], suggested: [String], canonical: String) -> [String] {
        let existingFolded = Set(existing.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        var seen = existingFolded
        var merged = existing

        for alias in suggested {
            let normalizedAlias = CustomVocabularyCodec.normalizeAlias(alias)
            guard !normalizedAlias.isEmpty else { continue }
            let folded = normalizedAlias.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let canonicalFolded = canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard folded != canonicalFolded else { continue }
            guard seen.insert(folded).inserted else { continue }
            merged.append(normalizedAlias)
        }

        return merged
    }

    private func fallbackEntries(from input: String) -> [GeminiVocabularySuggestionService.GeneratedEntry] {
        let separators = CharacterSet(charactersIn: ",\n")
        let rawTerms = input
            .components(separatedBy: separators)
            .map { CustomVocabularyCodec.normalizeCanonical($0) }
            .filter { !$0.isEmpty }

        let terms = rawTerms.isEmpty ? [input] : rawTerms
        var seen = Set<String>()
        var entries: [GeminiVocabularySuggestionService.GeneratedEntry] = []

        for term in terms {
            let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(folded).inserted else { continue }
            entries.append(.init(canonical: term, aliases: []))
        }

        return entries
    }

    private func mergeGeneratedEntries(_ generatedEntries: [GeminiVocabularySuggestionService.GeneratedEntry]) -> MergeSummary {
        var summary = MergeSummary()

        for generated in generatedEntries {
            let canonicalFolded = generated.canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            if let existingIndex = entries.firstIndex(where: {
                CustomVocabularyCodec.normalizeCanonical($0.canonical)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == canonicalFolded
            }) {
                let existingAliases = CustomVocabularyCodec.aliases(
                    from: entries[existingIndex].aliasesText,
                    canonical: generated.canonical
                )
                let mergedAliases = mergeAliases(
                    existing: existingAliases,
                    suggested: generated.aliases,
                    canonical: generated.canonical
                )
                let newAliasCount = max(0, mergedAliases.count - existingAliases.count)
                let canonicalChanged = entries[existingIndex].canonical != generated.canonical

                if canonicalChanged || newAliasCount > 0 {
                    entries[existingIndex].canonical = generated.canonical
                    entries[existingIndex].aliasesText = mergedAliases.joined(separator: ", ")
                    summary.updatedCount += 1
                    summary.newAliasCount += newAliasCount
                }
            } else {
                entries.append(
                    Entry(
                        canonical: generated.canonical,
                        aliasesText: generated.aliases.joined(separator: ", ")
                    )
                )
                summary.insertedCount += 1
                summary.newAliasCount += generated.aliases.count
            }
        }

        return summary
    }

    private func persistEntries() throws {
        try Self.ensureFileExists()
        let serialized = CustomVocabularyCodec.serialize(entries: entries)
        try serialized.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        reloadUserCustomTerms()
        ignoresNextChangeNotification = true
        NotificationCenter.default.post(name: .customVocabularyDidChange, object: nil)
    }

    static func ensureFileExists() throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            try CustomVocabularyCodec.template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
