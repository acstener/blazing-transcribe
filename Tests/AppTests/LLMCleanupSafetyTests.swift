import XCTest
@testable import App

final class LLMCleanupSafetyTests: XCTestCase {
    private var originalCustomPrompt: String = ""
    private var originalAppendMode: Bool = false
    private var hadStoredAppendMode: Bool = false
    private var originalVoiceStyleFeatureOverride: Bool?

    override func setUp() {
        super.setUp()
        originalVoiceStyleFeatureOverride = LLMCleanupService.voiceStyleFeatureOverride
        LLMCleanupService.voiceStyleFeatureOverride = true
        originalCustomPrompt = LLMCleanupService.customPromptInstruction
        originalAppendMode = LLMCleanupService.customPromptAppendsToV20
        hadStoredAppendMode = UserDefaults.standard.object(forKey: "llmCustomPromptAppend") != nil
    }

    override func tearDown() {
        LLMCleanupService.customPromptInstruction = originalCustomPrompt
        if hadStoredAppendMode {
            LLMCleanupService.customPromptAppendsToV20 = originalAppendMode
        } else {
            UserDefaults.standard.removeObject(forKey: "llmCustomPromptAppend")
        }
        LLMCleanupService.voiceStyleFeatureOverride = originalVoiceStyleFeatureOverride
        super.tearDown()
    }

    func testResolveSelfCorrectionsDoesNotTruncateLongUtteranceAfterIMean() {
        let input = "Hey, it's been a while since I've done some work on the old golf swing and it got me into a rabbit hole where I was like shit the golf swing is like a sling and I'm so rigid in my golf swing and I think is is there similarities here? I mean I think there definitely is and I need to explore them."

        XCTAssertEqual(LLMCleanupService.resolveSelfCorrections(input), input)
    }

    func testResolveSelfCorrectionsDoesNotTreatYeahNoAsCorrection() {
        let input = "Yeah no it's fine."

        XCTAssertEqual(LLMCleanupService.resolveSelfCorrections(input), input)
    }

    func testResolveSelfCorrectionsKeepsExplicitShortRestatedCorrection() {
        let input = "Email it to Dave actually no email it to Rachel"

        XCTAssertEqual(
            LLMCleanupService.resolveSelfCorrections(input),
            "email it to Rachel"
        )
    }

    func testCleanupRejectionReasonRejectsOverCutMultiSentenceOutput() {
        let input = "Okay, this seems to be working pretty well. Um so yeah, I'll see you tomorrow. Oh no, I mean uh I'll see you Wednesday."
        let cleaned = "I'll see you Wednesday."

        XCTAssertEqual(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20LiteFewShot
            ),
            "19% overlap"
        )
    }

    func testCleanupRejectionReasonAllowsPreservedContextWithCorrection() {
        let input = "Okay, this seems to be working pretty well. Um so yeah, I'll see you tomorrow. Oh no, I mean uh I'll see you Wednesday."
        let cleaned = "Okay, this seems to be working pretty well. I'll see you Wednesday."

        XCTAssertNil(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20LiteFewShot
            )
        )
    }

    func testCleanupRejectionReasonRejectsTruncatedLongDictation() {
        // Simulates a token-cap truncation: a long dictation whose cleanup lost
        // its tail. The output is a verbatim prefix (high overlap), so only the
        // shrink guard can catch it.
        let sentence = "the quick brown fox jumps over the lazy dog near the river bank today"
        let input = Array(repeating: sentence, count: 5).joined(separator: " ")   // 70 words
        let cleaned = Array(repeating: sentence, count: 3).joined(separator: " ") // 42 words — tail lost

        XCTAssertEqual(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20FewShot
            ),
            "shrank 70→42 words"
        )
    }

    func testCleanupRejectionReasonAllowsFillerRemovalOnLongDictation() {
        // Legitimate cleanup of a long dictation: fillers removed (~15% of
        // words), everything else intact. Must not trip the shrink guard.
        let chunk = "um so the quick brown fox uh jumps over the you know lazy dog near the river bank"
        let cleanedChunk = "The quick brown fox jumps over the lazy dog near the river bank."
        let input = Array(repeating: chunk, count: 4).joined(separator: " ")          // 72 words
        let cleaned = Array(repeating: cleanedChunk, count: 4).joined(separator: " ") // 52 words

        XCTAssertNil(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20FewShot
            )
        )
    }

    func testCleanupRejectionReasonAllowsLayeredCustomPirateRewrite() {
        LLMCleanupService.customPromptInstruction = "Rewrite the cleaned transcript in light pirate diction while preserving the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        LLMCleanupService.customPromptAppendsToV20 = true

        let input = "Hello, how are you doing?"
        let cleaned = "Ahoy there, how be ye?"

        XCTAssertNil(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20LiteFewShot
            )
        )
    }

    func testCleanupRejectionReasonStillRejectsShortAnsweredQuestionWithCustomVoice() {
        LLMCleanupService.customPromptInstruction = "Rewrite the cleaned transcript in light pirate diction while preserving the speaker's original meaning, intent, and sentence type. Do not answer questions or add new information."
        LLMCleanupService.customPromptAppendsToV20 = true

        let input = "Hello, how are you doing?"
        let cleaned = "I'm doing well, thanks."

        XCTAssertEqual(
            LLMCleanupService.cleanupRejectionReason(
                cleaned: cleaned,
                rawText: input,
                inputText: input,
                promptContract: .v20LiteFewShot
            ),
            "20% overlap"
        )
    }
}
