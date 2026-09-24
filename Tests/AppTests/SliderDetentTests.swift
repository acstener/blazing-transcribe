import XCTest
@testable import App

final class SliderDetentTests: XCTestCase {
    private let silence = AudioTuningDetents.silenceTimeout
    private let voice = AudioTuningDetents.voiceDetection

    func testExactValuesMatchNamedDetents() {
        XCTAssertEqual(BTSliderDetent.label(for: 0.35, in: silence), "Snappy")
        XCTAssertEqual(BTSliderDetent.label(for: 0.5, in: silence), "Balanced")
        XCTAssertEqual(BTSliderDetent.label(for: 1.0, in: silence), "Relaxed")
        XCTAssertEqual(BTSliderDetent.label(for: 0.25, in: voice), "Sensitive")
        XCTAssertEqual(BTSliderDetent.label(for: 0.35, in: voice), "Balanced")
        XCTAssertEqual(BTSliderDetent.label(for: 0.55, in: voice), "Strict")
    }

    func testSliderStepRoundingStillMatches() {
        // What a 0.05-step slider starting at 0.2 / 0.1 actually produces.
        XCTAssertEqual(BTSliderDetent.label(for: 0.2 + 3 * 0.05, in: silence), "Snappy")
        XCTAssertEqual(BTSliderDetent.label(for: 0.1 + 9 * 0.05, in: voice), "Strict")
    }

    func testValuesBetweenDetentsAreCustom() {
        XCTAssertEqual(BTSliderDetent.label(for: 0.4, in: silence), "Custom")
        XCTAssertEqual(BTSliderDetent.label(for: 0.75, in: silence), "Custom")
        XCTAssertEqual(BTSliderDetent.label(for: 2.0, in: silence), "Custom")
        XCTAssertEqual(BTSliderDetent.label(for: 0.3, in: voice), "Custom")
        XCTAssertNil(BTSliderDetent.matching(0.9, in: voice))
    }

    func testDefaultsLandOnBalanced() {
        // AudioSettingsView falls back to 0.5 / 0.35 when nothing is stored.
        XCTAssertEqual(BTSliderDetent.matching(0.5, in: silence)?.name, "Balanced")
        XCTAssertEqual(BTSliderDetent.matching(0.35, in: voice)?.name, "Balanced")
    }
}
