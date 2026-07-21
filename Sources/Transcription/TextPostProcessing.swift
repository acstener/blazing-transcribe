import Foundation

// MARK: - Vocabulary Corrections

/// Core corrections — just the essentials. Add more as needed.
private let builtInCorrections: [(pattern: String, replacement: String)] = [
    // Claude Code (multi-word first)
    ("claw code", "Claude Code"),
    ("clawed code", "Claude Code"),
    ("cloud code", "Claude Code"),
    ("clod code", "Claude Code"),
    ("claude coat", "Claude Code"),
    ("claud code", "Claude Code"),
    // Claude (single word)
    ("clawed", "Claude"),
    ("claw", "Claude"),
    ("clod", "Claude"),
    // Alex Christou
    ("alex christie", "Alex Christou"),
    ("alex christy", "Alex Christou"),
    ("alex christu", "Alex Christou"),
    ("alex christo", "Alex Christou"),
    ("alex kristou", "Alex Christou"),
    ("alex kristo", "Alex Christou"),
    ("alex christow", "Alex Christou"),
    ("alex chris too", "Alex Christou"),
    ("Christie", "Christou"),
    ("Christy", "Christou"),
    ("Christu", "Christou"),
    ("christu", "Christou"),
    ("chris too", "Christou"),
    // Codex
    ("code x", "Codex"),
    ("kodex", "Codex"),
    ("codecs", "Codex"),
    ("code ex", "Codex"),
    // BlazingFastTranscription.com (multi-word → single domain)
    ("blazing fast transcription dot com", "BlazingFastTranscription.com"),
    ("blazing fast transcription.com", "BlazingFastTranscription.com"),
    ("blazing fast transcription com", "BlazingFastTranscription.com"),
]

/// User custom dictionary terms loaded from ~/Library/Application Support/.../custom-vocabulary.txt.
/// Format: CanonicalForm: alias1, alias2, ...
/// All entries trusted — no filtering.
private var _cachedUserTerms: [(pattern: String, replacement: String)]?
private func loadUserCustomTerms() -> [(pattern: String, replacement: String)] {
    if let cached = _cachedUserTerms { return cached }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let customFile = appSupport.appendingPathComponent("BlazingFastTranscription/custom-vocabulary.txt")
    guard let content = try? String(contentsOf: customFile, encoding: .utf8) else {
        _cachedUserTerms = []
        return []
    }
    var patterns: [(String, String)] = []
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
        let canonical = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
        guard !canonical.isEmpty else { continue }
        let aliasStr = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        for alias in aliasStr.components(separatedBy: ",") {
            let a = alias.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, a.lowercased() != canonical.lowercased() else { continue }
            patterns.append((a, canonical))
        }
    }
    _cachedUserTerms = patterns
    if !patterns.isEmpty {
        print("[Vocab] Loaded \(patterns.count) user custom patterns")
    }
    return patterns
}

/// Invalidate cached user terms (call when custom dictionary file changes).
public func reloadUserCustomTerms() {
    _cachedUserTerms = nil
    _compiledPatterns = nil
}

/// Load raw user custom term names (canonical forms) for CTC biasing.
/// Returns just the canonical names, not the alias patterns.
public func loadUserCustomTermNames() -> [String] {
    return loadUserCustomTermsStructured().map(\.canonical)
}

/// Load user custom terms with aliases for CTC vocabulary boosting.
/// Returns canonical form + all aliases from the custom-vocabulary.txt file.
public func loadUserCustomTermsStructured() -> [(canonical: String, aliases: [String])] {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let customFile = appSupport.appendingPathComponent("BlazingFastTranscription/custom-vocabulary.txt")
    guard let content = try? String(contentsOf: customFile, encoding: .utf8) else { return [] }
    var terms: [(canonical: String, aliases: [String])] = []
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let canonical = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            let aliasStr = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            let aliases = aliasStr.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != canonical.lowercased() }
            terms.append((canonical: canonical, aliases: aliases))
        } else {
            if !trimmed.isEmpty { terms.append((canonical: trimmed, aliases: [])) }
        }
    }
    return terms
}

/// Pre-compiled word-boundary regex patterns. Lazy-loaded once.
private var _compiledPatterns: [(regex: NSRegularExpression, replacement: String)]?
private func compiledVocabPatterns() -> [(regex: NSRegularExpression, replacement: String)] {
    if let cached = _compiledPatterns { return cached }
    // Sort longer patterns first so "claw code" matches before "claw"
    let sorted = (builtInCorrections + loadUserCustomTerms())
        .sorted { $0.pattern.count > $1.pattern.count }
    let compiled = sorted.compactMap { (pattern, replacement) -> (NSRegularExpression, String)? in
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        return (regex, replacement)
    }
    _compiledPatterns = compiled
    print("[Vocab] Compiled \(compiled.count) vocab correction patterns")
    return compiled
}

/// Apply vocabulary corrections. <1ms.
func applyDevTermCorrections(_ text: String) -> String {
    let patterns = compiledVocabPatterns()
    guard !patterns.isEmpty else { return text }
    var result = text
    for (regex, replacement) in patterns {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
    }
    return result
}

// MARK: - Regex Filler Removal

private let fillerPattern: NSRegularExpression = {
    // Filler words (case-insensitive). Optional trailing comma to clean up "Um, hey" → "Hey".
    try! NSRegularExpression(pattern: "\\b(hmm|mm|mhm|mmm|uh|um|uhm)\\b[,]?\\s*", options: [.caseInsensitive])
}()

private let stutterPattern: NSRegularExpression = {
    // Stutter disfluencies: "th-", "o-", "wh-" (1-2 char prefix + dash + space)
    // Must be followed by whitespace or end-of-string to avoid stripping real hyphens (e.g. "hands-free")
    try! NSRegularExpression(pattern: "\\b[a-zA-Z]{1,2}-(?=\\s|$)", options: [])
}()

private let multiSpacePattern: NSRegularExpression = {
    try! NSRegularExpression(pattern: "\\s{2,}", options: [])
}()

private let sentenceCapPattern: NSRegularExpression = {
    try! NSRegularExpression(pattern: "([.!?])\\s+([a-z])", options: [])
}()

/// Lightweight regex-based filler removal. <1ms, no model loading.
/// Strips filler words (um, uh, hmm, etc.) and stutter disfluencies (th-, o-, wh-).
/// Preserves capitalization and punctuation.
public func applyRegexFillerCleanup(_ text: String) -> String {
    var result = text
    let fullRange = NSRange(result.startIndex..., in: result)

    // 1. Strip filler words + optional trailing comma/space
    result = fillerPattern.stringByReplacingMatches(in: result, range: fullRange, withTemplate: "")

    // 2. Strip stutter disfluencies
    let range2 = NSRange(result.startIndex..., in: result)
    result = stutterPattern.stringByReplacingMatches(in: result, range: range2, withTemplate: "")

    // 3. Collapse multiple spaces
    let range3 = NSRange(result.startIndex..., in: result)
    result = multiSpacePattern.stringByReplacingMatches(in: result, range: range3, withTemplate: " ")

    // 4. Re-capitalize after sentence-ending punctuation (. ! ?) where filler removal left lowercase
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    let range4 = NSRange(result.startIndex..., in: result)
    let mutableResult = NSMutableString(string: result)
    sentenceCapPattern.enumerateMatches(in: result, range: range4) { match, _, _ in
        guard let match = match, let letterRange = Range(match.range(at: 2), in: result) else { return }
        let upper = result[letterRange].uppercased()
        mutableResult.replaceCharacters(in: match.range(at: 2), with: upper)
    }
    result = mutableResult as String

    // 5. Capitalize first character if filler was at the very start
    if let first = result.first, first.isLowercase {
        result = first.uppercased() + result.dropFirst()
    }

    return result
}
