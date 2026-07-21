import Foundation

enum GeminiVocabularySuggestionError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case noSuggestions

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Gemini API key is missing."
        case .invalidResponse:
            return "Gemini returned an invalid response."
        case .noSuggestions:
            return "Gemini returned no usable alias suggestions."
        }
    }
}

actor GeminiVocabularySuggestionService {
    struct GeneratedEntry: Equatable {
        let canonical: String
        let aliases: [String]
    }

    static let shared = GeminiVocabularySuggestionService()

    private let model = "gemini-2.5-flash"

    func suggestAliases(for canonical: String) async throws -> [String] {
        let key = LLMCleanupService.geminiAPIKey
        guard !key.isEmpty else { throw GeminiVocabularySuggestionError.apiKeyMissing }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [[
                    "text": """
                    You generate ASR error aliases for a speech-to-text custom dictionary.
                    Return JSON only in the exact shape {"aliases":["alias 1","alias 2"]}.
                    """
                ]]
            ],
            "contents": [[
                "role": "user",
                "parts": [[
                    "text": prompt(for: canonical)
                ]]
            ]],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 512,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GeminiVocabularySuggestionError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GeminiVocabularySuggestionError.invalidResponse
        }

        let aliases = try parseAliases(from: text, canonical: canonical)
        guard !aliases.isEmpty else { throw GeminiVocabularySuggestionError.noSuggestions }
        return aliases
    }

    func generateEntries(from input: String) async throws -> [GeneratedEntry] {
        let key = LLMCleanupService.geminiAPIKey
        guard !key.isEmpty else { throw GeminiVocabularySuggestionError.apiKeyMissing }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [[
                    "text": """
                    You generate ASR error aliases for a speech-to-text custom dictionary.
                    Return JSON only in the exact shape {"entries":[{"canonical":"Term","aliases":["alias 1","alias 2"]}]}.
                    """
                ]]
            ],
            "contents": [[
                "role": "user",
                "parts": [[
                    "text": generationPrompt(for: input)
                ]]
            ]],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 1024,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GeminiVocabularySuggestionError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GeminiVocabularySuggestionError.invalidResponse
        }

        let entries = try parseGeneratedEntries(from: text)
        guard !entries.isEmpty else { throw GeminiVocabularySuggestionError.noSuggestions }
        return entries
    }

    private func prompt(for canonical: String) -> String {
        """
        Canonical term: \(canonical)

        Generate 8 to 15 aliases that a neural ASR model (Parakeet TDT with BPE tokenization) would realistically output when a speaker says this term. These aliases become regex word-boundary replacements, so each must be an exact string the ASR could produce.

        ASR error patterns to cover (in priority order):
        1. WORD BOUNDARY ERRORS — the model splits or merges words wrong. E.g. "Christou" → "chris too", "chris to"; "Codex" → "code x", "code ex"
        2. HOMOPHONE SUBSTITUTIONS — phonetically identical words. E.g. "Claude" → "clawed", "claw", "clod"; "write" → "right"
        3. LOWERCASED VERSIONS — ASR often doesn't capitalize proper nouns. Include the all-lowercase version of the canonical and key variants.
        4. DROPPED/ADDED SOUNDS — minor phonetic differences. E.g. "Christou" → "Christu", "Christo"; "Denby" → "Denbe", "Denbi"
        5. SIMILAR CONSONANTS — common confusions: ch/k, b/p, d/t, g/k. E.g. "Christou" → "Kristou"
        6. For MULTI-WORD terms: include variations where spacing or punctuation differs. E.g. "Claude Code" → "claw code", "cloud code"
        7. For DOMAIN NAMES or URLS: include the spoken-out version. E.g. "example.com" → "example dot com"

        Rules:
        - Every alias must be a plausible literal ASR text output — not a creative misspelling a human would make.
        - Do NOT generate context phrases (e.g. "denby music" for "Denby") — only the term itself, misheard.
        - Do NOT generate rhyming words or creative substitutions (e.g. "big yawn" for "Big John" is wrong).
        - Do not include the canonical term itself.
        - No regex, no explanations.
        - Return JSON only: {"aliases":["alias 1","alias 2"]}
        """
    }

    private func generationPrompt(for input: String) -> String {
        """
        Build speech-to-text custom dictionary entries from this user input.

        Input:
        \(input)

        For each term, generate 8 to 15 aliases that a neural ASR model (Parakeet TDT with BPE tokenization) would realistically output. These become regex word-boundary replacements.

        ASR error patterns to cover per term (priority order):
        1. WORD BOUNDARY ERRORS — model splits/merges words. "Christou" → "chris too"; "Codex" → "code x"
        2. HOMOPHONE SUBSTITUTIONS — "Claude" → "clawed", "claw"; phonetically identical words
        3. LOWERCASED VERSIONS — ASR often drops capitalization on proper nouns
        4. DROPPED/ADDED SOUNDS — "Christou" → "Christu", "Christo"
        5. SIMILAR CONSONANTS — ch/k, b/p, d/t confusions
        6. MULTI-WORD spacing variants and DOMAIN NAMES spoken out ("dot com")

        Rules:
        - Every alias must be a plausible literal ASR output — not creative misspelling.
        - Do NOT add context words (e.g. "denby music" for "Denby" is wrong — just misheard forms of the word itself).
        - Do NOT generate rhyming or creative substitutions.
        - If the input is already a list of terms, keep those as canonicals.
        - Do not include canonical strings in their own aliases.
        - No explanations.
        - Return JSON only: {"entries":[{"canonical":"Term","aliases":["alias 1","alias 2"]}]}
        """
    }

    private func parseAliases(from raw: String, canonical: String) throws -> [String] {
        let trimmed = stripCodeFences(from: raw)

        if let objectData = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: objectData) as? [String: Any],
           let aliases = object["aliases"] as? [String] {
            return normalizeAliases(aliases, canonical: canonical)
        }

        if let arrayStart = trimmed.firstIndex(of: "["),
           let arrayEnd = trimmed.lastIndex(of: "]"),
           arrayStart <= arrayEnd {
            let arrayString = String(trimmed[arrayStart...arrayEnd])
            if let arrayData = arrayString.data(using: .utf8),
               let aliases = try? JSONSerialization.jsonObject(with: arrayData) as? [String] {
                return normalizeAliases(aliases, canonical: canonical)
            }
        }

        let lineFallback = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                line
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "* ", with: "")
                    .replacingOccurrences(of: "\"", with: "")
            }
            .filter { !$0.isEmpty }

        let aliases = lineFallback.flatMap { line in
            line.split(separator: ",").map { String($0) }
        }

        let normalized = normalizeAliases(aliases, canonical: canonical)
        guard !normalized.isEmpty else { throw GeminiVocabularySuggestionError.invalidResponse }
        return normalized
    }

    private func stripCodeFences(from value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseGeneratedEntries(from raw: String) throws -> [GeneratedEntry] {
        let trimmed = stripCodeFences(from: raw)

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parsedEntries = object["entries"] as? [[String: Any]] {
            return normalizeGeneratedEntries(parsedEntries)
        }

        if let arrayStart = trimmed.firstIndex(of: "["),
           let arrayEnd = trimmed.lastIndex(of: "]"),
           arrayStart <= arrayEnd {
            let arrayString = String(trimmed[arrayStart...arrayEnd])
            if let data = arrayString.data(using: .utf8),
               let parsedEntries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return normalizeGeneratedEntries(parsedEntries)
            }
        }

        throw GeminiVocabularySuggestionError.invalidResponse
    }

    private func normalizeGeneratedEntries(_ rawEntries: [[String: Any]]) -> [GeneratedEntry] {
        var seenCanonicals = Set<String>()
        var entries: [GeneratedEntry] = []

        for raw in rawEntries {
            guard let canonicalRaw = raw["canonical"] as? String else { continue }
            let canonical = canonicalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }

            let canonicalFolded = canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenCanonicals.insert(canonicalFolded).inserted else { continue }

            let aliases = normalizeAliases(raw["aliases"] as? [String] ?? [], canonical: canonical)
            entries.append(GeneratedEntry(canonical: canonical, aliases: aliases))
        }

        return entries
    }

    private func normalizeAliases(_ aliases: [String], canonical: String) -> [String] {
        let canonicalFolded = canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var seen = Set<String>()
        var normalized: [String] = []

        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard folded != canonicalFolded else { continue }
            guard seen.insert(folded).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }
}
