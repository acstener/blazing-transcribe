import Foundation

/// Rule-based alias generator for ASR custom dictionaries.
/// Produces realistic Parakeet TDT error patterns: word boundary splits,
/// homophones, consonant swaps, voiced/voiceless pairs, vowel confusions,
/// suffix trimming, and domain spoken forms.
/// 100% local, <1ms, no model or cloud dependency.
enum DeterministicAliasGenerator {

    // MARK: - Public API

    static func generateAliases(for canonical: String) -> [String] {
        var aliases = Set<String>()

        let words = canonical.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        // Always add full lowercase
        let lowered = words.map { $0.lowercased() }.joined(separator: " ")
        aliases.insert(lowered)

        // Domain handling (before word processing)
        addDomainVariants(canonical, words: words, into: &aliases)

        // Per-word variants → full phrase
        for (i, word) in words.enumerated() {
            for variant in wordVariants(word) {
                var modified = words.map { $0.lowercased() }
                modified[i] = variant.lowercased()
                aliases.insert(modified.joined(separator: " "))
            }

            for split in boundarySplits(word) {
                var modified = words.map { $0.lowercased() }
                modified[i] = split.lowercased()
                aliases.insert(modified.joined(separator: " "))
            }
        }

        // Multi-word homophones (check full phrase)
        for (phrase, replacements) in multiWordHomophones {
            if lowered == phrase {
                aliases.formUnion(replacements)
            }
        }

        let canonicalLower = canonical.lowercased()
        return aliases
            .filter { !$0.isEmpty && $0 != canonicalLower }
            .sorted()
    }

    // MARK: - Word Variants

    private static func wordVariants(_ word: String) -> [String] {
        var variants: [String] = []
        let lower = word.lowercased()

        // 1. Known homophones (highest priority)
        if let homophones = homophoneTable[lower] {
            variants.append(contentsOf: homophones)
        }

        // 2. Initial consonant cluster swaps
        for (prefix, replacements) in initialConsonantSwaps {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = String(lower.dropFirst(prefix.count))
            for r in replacements {
                let v = r + rest
                if v != lower { variants.append(v) }
            }
        }

        // 3. Hard "c" → "k" before a, o, u
        if lower.hasPrefix("c") && lower.count > 1 {
            let second = lower[lower.index(after: lower.startIndex)]
            if "aou".contains(second) {
                let v = "k" + String(lower.dropFirst())
                if v != lower { variants.append(v) }
            }
        }

        // 4. Voiced/voiceless consonant pairs — only on short words (≤10 chars)
        //    where a single swap is meaningful. On long words it produces noise.
        if lower.count <= 10 {
            for (voiced, voiceless) in voicedVoicelessPairs {
                if lower.contains(voiced) {
                    let v = lower.replacingOccurrences(of: voiced, with: voiceless)
                    if v != lower { variants.append(v) }
                }
                if lower.contains(voiceless) {
                    let v = lower.replacingOccurrences(of: voiceless, with: voiced)
                    if v != lower { variants.append(v) }
                }
            }
        }

        // 5. Word-final consonant devoicing (very common in fast speech)
        for (voiced, voiceless) in finalDevoicing {
            if lower.hasSuffix(voiced) {
                variants.append(String(lower.dropLast(voiced.count)) + voiceless)
            }
        }

        // 6. Vowel confusion patterns — only on short words where it's targeted
        if lower.count <= 12 {
            for (vowel, swaps) in vowelConfusions {
                guard lower.contains(vowel) else { continue }
                for swap in swaps {
                    let v = lower.replacingOccurrences(of: vowel, with: swap)
                    if v != lower { variants.append(v) }
                }
            }
        }

        // 7. L/R confusion — only on short words (≤8 chars)
        if lower.count <= 8 {
            if lower.contains("l") {
                variants.append(lower.replacingOccurrences(of: "l", with: "r"))
            }
            if lower.contains("r") && !lower.hasPrefix("chr") && !lower.hasPrefix("cr") {
                variants.append(lower.replacingOccurrences(of: "r", with: "l"))
            }
        }

        // 8. Suffix trimming (dropped final sounds)
        for (suffix, replacements) in suffixRules {
            guard lower.hasSuffix(suffix), lower.count > suffix.count + 1 else { continue }
            let stem = String(lower.dropLast(suffix.count))
            for r in replacements {
                let v = stem + r
                if v != lower && !v.isEmpty { variants.append(v) }
            }
        }

        // 9. Dropped final consonant clusters
        for cluster in droppedFinalClusters {
            guard lower.hasSuffix(cluster), lower.count > cluster.count + 1 else { continue }
            let simplified = String(lower.dropLast(cluster.count)) + String(cluster.first!)
            if simplified != lower { variants.append(simplified) }
        }

        return variants
    }

    // MARK: - Word Boundary Splits

    private static func boundarySplits(_ word: String) -> [String] {
        var splits: [String] = []
        let lower = word.lowercased()
        guard lower.count > 3 else { return splits }

        // Known splits (observed from Parakeet TDT)
        if let known = knownSplits[lower] {
            splits.append(contentsOf: known)
        }

        // Generic suffix-based splits
        if lower.hasSuffix("ou") || lower.hasSuffix("oo") {
            let stem = String(lower.dropLast(2))
            if stem.count >= 2 {
                splits.append(stem + " too")
                splits.append(stem + " to")
            }
        }
        if lower.hasSuffix("ex") {
            let stem = String(lower.dropLast(2))
            if stem.count >= 4 {
                splits.append(stem + "e x")
                splits.append(stem + " x")
            }
        }
        if lower.hasSuffix("er") && lower.count > 4 {
            splits.append(String(lower.dropLast(2)) + " er")
        }
        if lower.hasSuffix("or") && lower.count > 4 {
            splits.append(String(lower.dropLast(2)) + " or")
        }
        if lower.hasSuffix("al") && lower.count > 4 {
            splits.append(String(lower.dropLast(2)) + " all")
        }
        if lower.hasSuffix("ance") || lower.hasSuffix("ence") {
            let stem = String(lower.dropLast(4))
            if stem.count >= 2 {
                splits.append(stem + " " + String(lower.suffix(4)))
            }
        }
        if lower.hasSuffix("able") || lower.hasSuffix("ible") {
            let stem = String(lower.dropLast(4))
            if stem.count >= 2 {
                splits.append(stem + " " + String(lower.suffix(4)))
            }
        }
        if lower.hasSuffix("ment") && lower.count > 5 {
            splits.append(String(lower.dropLast(4)) + " ment")
        }

        // CamelCase splitting
        let camelWords = splitCamelCase(word)
        if camelWords.count > 1 {
            splits.append(camelWords.joined(separator: " ").lowercased())
        }

        return splits
    }

    // MARK: - Domain Handling

    private static func addDomainVariants(_ canonical: String, words: [String], into aliases: inout Set<String>) {
        let tlds: [(suffix: String, spoken: String)] = [
            (".com", "dot com"), (".org", "dot org"), (".net", "dot net"),
            (".io", "dot I O"), (".dev", "dot dev"), (".ai", "dot A I"),
            (".co", "dot co"),
        ]

        let lower = canonical.lowercased()
        for tld in tlds {
            guard lower.hasSuffix(tld.suffix) else { continue }
            let base = String(canonical.dropLast(tld.suffix.count))
            let baseLower = base.lowercased()
            let tldWord = String(tld.suffix.dropFirst())

            let camelWords = splitCamelCase(base)
            let spaced = camelWords.count > 1
                ? camelWords.joined(separator: " ").lowercased()
                : baseLower

            aliases.insert("\(spaced) \(tld.spoken)")
            aliases.insert("\(spaced)\(tld.suffix)")
            aliases.insert("\(spaced) \(tldWord)")
            aliases.insert(spaced)

            if !baseLower.contains(" ") {
                aliases.insert("\(baseLower) \(tld.spoken)")
                aliases.insert("\(baseLower) \(tldWord)")
            }
        }
    }

    // MARK: - CamelCase Splitter

    private static func splitCamelCase(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isUppercase && !current.isEmpty {
                words.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.count > 1 ? words : []
    }

    // MARK: - Lookup Tables

    /// Known homophones: words that sound identical but ASR picks the wrong spelling.
    private static let homophoneTable: [String: [String]] = [
        // Names — high-frequency ASR confusions
        "christou": ["christie", "christy", "christo", "christu"],
        "claude": ["claw", "clawed", "cloud", "clod"],
        "john": ["jon"],
        "sean": ["shawn", "shaun"],
        "shawn": ["sean", "shaun"],
        "stephen": ["steven"],
        "marc": ["mark"],
        "neil": ["neal"],
        "brian": ["bryan"],
        "leigh": ["lee"],
        "stuart": ["stewart"],
        "gene": ["jean"],
        "carl": ["karl"],
        "erik": ["eric"],
        "allan": ["alan", "allen"],
        "anne": ["ann"],
        "phil": ["fill"],
        "mike": ["mic"],
        "doug": ["dug"],
        "ross": ["russ"],
        // Common words ASR confuses
        "their": ["there", "they're"],
        "write": ["right", "rite"],
        "wright": ["right", "rite"],
        "queue": ["cue", "q"],
        "cache": ["cash"],
        "route": ["root"],
        "data": ["dada", "dater"],
        "live": ["life"],
        "use": ["ewes", "yews"],
    ]

    /// Multi-word phrases with known ASR alternatives
    private static let multiWordHomophones: [(String, [String])] = [
        ("claude code", ["claw code", "clawed code", "cloud code", "clod code", "claude coat"]),
    ]

    /// Initial consonant cluster swaps that ASR commonly confuses.
    private static let initialConsonantSwaps: [(String, [String])] = [
        ("chr", ["kr"]),         // Christou → Kristou
        ("ch", ["k", "sh"]),     // Chadwick → Kadwick / Shadwick
        ("ph", ["f"]),           // Phil → Fil
        ("th", ["d", "t", "f"]),  // Theodore → Deodore (th/d very common)
        ("kn", ["n"]),           // Knight → Night
        ("wr", ["r"]),           // Wright → Right
        ("wh", ["w"]),           // Whisper → Wisper
        ("gn", ["n"]),           // Gnome → Nome
        ("ps", ["s"]),           // Psychology → Sychology
        ("sch", ["sk", "sh"]),   // Schedule → Skedule
        ("qu", ["kw", "k"]),     // Quentin → Kwentin
    ]

    /// Voiced/voiceless consonant pairs — ASR swaps these frequently.
    /// Applied as substring replacements anywhere in the word.
    private static let voicedVoicelessPairs: [(String, String)] = [
        ("b", "p"),     // Obvious → opvious (less common but real)
        ("d", "t"),     // Denby → Tenby, code → coat
        ("g", "k"),     // Greg → Kreg
        ("v", "f"),     // Dave → Dafe, live → life
        ("z", "s"),     // Buzz → Buss
    ]

    /// Word-final consonant devoicing — very common in fast/connected speech.
    /// The final voiced consonant becomes voiceless.
    private static let finalDevoicing: [(String, String)] = [
        ("d", "t"),     // cloud → clout, code → coat
        ("b", "p"),     // Bob → Bop
        ("g", "k"),     // big → bik, Doug → duck
        ("v", "f"),     // live → life, Dave → Dafe
        ("z", "s"),     // buzz → bus, was → wass
        ("dge", "tch"), // edge → etch, bridge → britch
    ]

    /// Vowel confusion patterns — ASR commonly confuses these vowel sounds.
    private static let vowelConfusions: [(String, [String])] = [
        ("ou", ["oo", "ow"]),      // Christou → Christoo, Christow
        ("au", ["aw", "or", "a"]), // Claude → Clawed, Paul → Pawl
        ("ai", ["ay", "ei"]),      // Waitrose → Waytrose
        ("ea", ["ee", "e"]),       // Sean → Seen
        ("oa", ["o", "ow"]),       // Coat → Cot
        ("ie", ["ee", "y"]),       // Denbie → Denbee
        ("ei", ["ee", "ay"]),      // Reign → Reen
        ("oo", ["ou", "u"]),       // Pool → Poul
    ]

    /// Suffix rules: common endings that get dropped or altered.
    private static let suffixRules: [(String, [String])] = [
        ("ou", ["u", "o"]),      // Christou → Christu, Christo
        ("ow", ["o"]),           // Barlow → Barlo
        ("ew", ["u"]),           // Matthew → Matthu
        ("ue", [""]),            // Vague → Vag
        ("e", [""]),             // Claude → Claud (silent final e)
        ("ght", ["t"]),          // Wright → Writ
        ("tion", ["shun"]),      // Transcription → Transcripshun
        ("sion", ["shun"]),      // Vision → Vishun
    ]

    /// Final consonant clusters that get simplified in fast speech.
    private static let droppedFinalClusters: [String] = [
        "sts",  // costs → cos
        "nds",  // bands → bans
        "lts",  // bolts → bols
        "mps",  // bumps → bums
        "nts",  // ants → ans
        "cts",  // facts → facs
        "lks",  // walks → wals
        "sks",  // asks → ass
        "pts",  // scripts → scrips
    ]

    /// Known word boundary splits observed from Parakeet TDT.
    private static let knownSplits: [String: [String]] = [
        "christou": ["chris too", "chris to"],
        "codex": ["code x", "code ex"],
        "transcription": ["tran scription"],
        "into": ["in to"],
        "onto": ["on to"],
        "cannot": ["can not"],
        "maybe": ["may be"],
        "today": ["to day"],
        "tonight": ["to night"],
        "become": ["be come"],
        "before": ["be four", "be for"],
        "because": ["be cause", "be cos"],
        "someone": ["some one"],
        "something": ["some thing"],
        "everyone": ["every one"],
        "everything": ["every thing"],
        "yourself": ["your self"],
        "myself": ["my self"],
        "itself": ["it self"],
        "outside": ["out side"],
        "inside": ["in side"],
        "without": ["with out"],
        "within": ["with in"],
    ]
}
