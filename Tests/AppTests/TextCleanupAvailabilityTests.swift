import XCTest
@testable import App

final class TextCleanupAvailabilityTests: XCTestCase {
    func testTurboPresetDisablesLLMCleanup() {
        XCTAssertFalse(AppDelegate.isLLMCleanupAvailable(for: .powerUserFastest))
    }

    func testStablePresetAllowsLLMCleanup() {
        XCTAssertTrue(AppDelegate.isLLMCleanupAvailable(for: .stable))
    }

    func testTurboPresetForcesLLMCleanupModeToOff() {
        XCTAssertEqual(
            AppDelegate.effectiveTextCleanupMode(
                requestedMode: .llm,
                transcriptionPreset: .powerUserFastest
            ),
            .off
        )
    }

    func testStablePresetKeepsLLMCleanupModeAvailable() {
        XCTAssertEqual(
            AppDelegate.effectiveTextCleanupMode(
                requestedMode: .llm,
                transcriptionPreset: .stable
            ),
            .llm
        )
    }

    func testLLMCleanupShortcutTurnsOffIntoLLMInStablePreset() {
        XCTAssertEqual(
            AppDelegate.toggledLLMCleanupMode(
                currentMode: .off,
                transcriptionPreset: .stable
            ),
            .llm
        )
    }

    func testLLMCleanupShortcutTurnsLLMIntoOffInStablePreset() {
        XCTAssertEqual(
            AppDelegate.toggledLLMCleanupMode(
                currentMode: .llm,
                transcriptionPreset: .stable
            ),
            .off
        )
    }

    func testLLMCleanupShortcutIsUnavailableInTurboPreset() {
        XCTAssertNil(
            AppDelegate.toggledLLMCleanupMode(
                currentMode: .off,
                transcriptionPreset: .powerUserFastest
            )
        )
    }

    func testLLMCleanupPrewarmIsDisabledWhenCleanupIsOffEvenWithAPIModelSelected() {
        XCTAssertFalse(
            AppDelegate.shouldPrewarmLLMCleanupConnection(
                isCleanupEnabled: false,
                cleanupModelID: LLMCleanupService.defaultAPIModelID
            )
        )
    }

    func testLLMCleanupPrewarmIsDisabledForRegexMode() {
        XCTAssertFalse(
            AppDelegate.shouldPrewarmLLMCleanupConnection(
                isCleanupEnabled: true,
                cleanupModelID: "regex"
            )
        )
    }

    func testLLMCleanupPrewarmIsDisabledForLocalModel() {
        XCTAssertFalse(
            AppDelegate.shouldPrewarmLLMCleanupConnection(
                isCleanupEnabled: true,
                cleanupModelID: "qwen3.5-0.8b-q6_k"
            )
        )
    }

    func testLLMCleanupPrewarmIsEnabledForActiveAPIModel() {
        XCTAssertTrue(
            AppDelegate.shouldPrewarmLLMCleanupConnection(
                isCleanupEnabled: true,
                cleanupModelID: LLMCleanupService.defaultAPIModelID
            )
        )
    }
}
