import XCTest
@testable import App

final class TextCleanupDefaultsTests: XCTestCase {
    func testDefaultTextCleanupSelectionUsesRegexWhenNoChoiceExists() {
        let selection = AppDelegate.defaultTextCleanupSelection(
            existingCleanupEnabled: nil,
            existingCleanupModelID: nil
        )

        XCTAssertEqual(selection?.isEnabled, true)
        XCTAssertEqual(selection?.modelID, "regex")
    }

    func testDefaultTextCleanupSelectionDoesNotOverrideExistingOffChoice() {
        let selection = AppDelegate.defaultTextCleanupSelection(
            existingCleanupEnabled: false,
            existingCleanupModelID: nil
        )

        XCTAssertNil(selection)
    }

    func testDefaultTextCleanupSelectionDoesNotOverrideExistingModelChoice() {
        let selection = AppDelegate.defaultTextCleanupSelection(
            existingCleanupEnabled: true,
            existingCleanupModelID: "qwen3.5-0.8b-q6_k"
        )

        XCTAssertNil(selection)
    }

    func testDefaultTextCleanupSelectionDoesNotOverrideExistingRegexChoice() {
        let selection = AppDelegate.defaultTextCleanupSelection(
            existingCleanupEnabled: true,
            existingCleanupModelID: "regex"
        )

        XCTAssertNil(selection)
    }

    func testResolvedLLMCleanupModelIDFallsBackToGeminiForRegex() {
        XCTAssertEqual(
            LLMCleanupService.resolvedLLMCleanupModelID("regex"),
            LLMCleanupService.defaultAPIModelID
        )
    }

    func testResolvedLLMCleanupModelIDFallsBackToGeminiForUnknownModel() {
        XCTAssertEqual(
            LLMCleanupService.resolvedLLMCleanupModelID("api-unknown-model"),
            LLMCleanupService.defaultAPIModelID
        )
    }

    func testSelectedCloudCleanupModelIDFallsBackToGeminiForRegex() {
        XCTAssertEqual(
            LLMCleanupService.selectedCloudCleanupModelID("regex"),
            LLMCleanupService.defaultAPIModelID
        )
    }

    func testSelectedCloudCleanupModelIDKeepsGroqSelection() {
        XCTAssertEqual(
            LLMCleanupService.selectedCloudCleanupModelID(LLMCleanupService.groqAPIModelID),
            LLMCleanupService.groqAPIModelID
        )
    }

    func testMigratedLLMCleanupModelIDRepointsGeminiFlashToDefaultModel() {
        XCTAssertEqual(
            AppDelegate.migratedLLMCleanupModelID("api-gemini-2.5-flash"),
            LLMCleanupService.defaultAPIModelID
        )
    }

    func testMigratedLLMCleanupModelIDLeavesOtherModelsAlone() {
        XCTAssertEqual(
            AppDelegate.migratedLLMCleanupModelID("api-gemini-2.5-flash-lite"),
            "api-gemini-2.5-flash-lite"
        )
        XCTAssertNil(AppDelegate.migratedLLMCleanupModelID(nil))
    }
}
