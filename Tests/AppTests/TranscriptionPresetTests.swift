import XCTest
@testable import App
import AudioEngine
import Transcription

final class TranscriptionPresetTests: XCTestCase {
    func testStablePresetUsesProductionEngine() {
        XCTAssertEqual(TranscriptionPreset.stable.engineChoice, .parakeetV3)
        XCTAssertNil(TranscriptionPreset.stable.realtimeFinalizationMode)
        XCTAssertNil(TranscriptionPreset.stable.realtimeShadowCleanupMode)
        XCTAssertFalse(TranscriptionPreset.stable.usesRealtimeEngine)
    }

    func testStableExtraQuickLegacyAliasCanonicalizesToStable() {
        XCTAssertEqual(TranscriptionPreset.stableExtraQuick.engineChoice, .parakeetV3)
        XCTAssertNil(TranscriptionPreset.stableExtraQuick.realtimeFinalizationMode)
        XCTAssertNil(TranscriptionPreset.stableExtraQuick.realtimeShadowCleanupMode)
        XCTAssertFalse(TranscriptionPreset.stableExtraQuick.usesRealtimeEngine)
        XCTAssertEqual(TranscriptionPreset.stableExtraQuick.canonicalPreset, .stable)
        XCTAssertFalse(TranscriptionPreset.stableExtraQuick.isUserFacing)
    }

    func testStablePresetUsesMainStandardEndpointingProfile() {
        XCTAssertEqual(
            AppDelegate.endpointingProfile(
                for: .stable,
                engine: .parakeetV3
            ),
            .standard
        )
    }

    func testStableExtraQuickKeepsHiddenFastEndpointingProfile() {
        XCTAssertEqual(
            AppDelegate.endpointingProfile(
                for: .stableExtraQuick,
                engine: .parakeetV3
            ),
            .stableExtraQuick
        )
    }

    func testRealtimeEngineStillUsesRealtimeEndpointingProfile() {
        XCTAssertEqual(
            AppDelegate.endpointingProfile(
                for: .powerUserFastest,
                engine: .parakeetEou
            ),
            .realtimeParakeet
        )
    }

    func testHybridPresetMapsToOverlayOnlyCleanup() {
        XCTAssertEqual(TranscriptionPreset.realtimeCleanup.engineChoice, .parakeetEou)
        XCTAssertEqual(TranscriptionPreset.realtimeCleanup.realtimeFinalizationMode, .speedPlusCleanup)
        XCTAssertEqual(TranscriptionPreset.realtimeCleanup.realtimeShadowCleanupMode, .overlay)
    }

    func testPowerModePresetMapsToPureSpeed() {
        XCTAssertEqual(TranscriptionPreset.powerUserFastest.engineChoice, .parakeetEou)
        XCTAssertEqual(TranscriptionPreset.powerUserFastest.realtimeFinalizationMode, .pureSpeed)
        XCTAssertEqual(TranscriptionPreset.powerUserFastest.realtimeShadowCleanupMode, .off)
    }

    func testUserFacingPresetsExposeStableAndTurbo() {
        XCTAssertEqual(
            TranscriptionPreset.userFacingCases,
            [.stable, .powerUserFastest]
        )
    }

    func testUserFacingPresetDisplayNamesAreConsistent() {
        XCTAssertEqual(TranscriptionPreset.stable.displayName, "Stable")
        XCTAssertEqual(TranscriptionPreset.stableExtraQuick.displayName, "Stable")
        XCTAssertEqual(TranscriptionPreset.powerUserFastest.displayName, "Turbo")
    }

    func testMenuTitlesClarifyRealtimePreset() {
        XCTAssertEqual(TranscriptionPreset.stable.menuTitle, "Stable")
        XCTAssertEqual(TranscriptionPreset.stableExtraQuick.menuTitle, "Stable")
        XCTAssertEqual(TranscriptionPreset.powerUserFastest.menuTitle, "Turbo  Fastest realtime")
    }

    func testStableSubtitleReflectsProductionBatchPath() {
        XCTAssertEqual(
            TranscriptionPreset.stable.subtitle,
            "Current V1 production path. Stable, accurate, and no overlay-driven realtime behavior."
        )
    }

    func testLegacyNonExperimentalSettingsMigrateToStable() {
        let preset = TranscriptionPreset.migrateLegacy(
            experimentalMode: false,
            experimentalEngineRaw: TranscriptionEngineChoice.parakeetEou.rawValue,
            realtimeFinalizationRaw: RealtimeFinalizationMode.speedPlusCleanup.rawValue,
            realtimeCleanupRaw: RealtimeShadowCleanupMode.field.rawValue
        )

        XCTAssertEqual(preset, TranscriptionPreset.stable)
    }

    func testLegacyRealtimeCleanupSettingsMigrateToHybridPreset() {
        let preset = TranscriptionPreset.migrateLegacy(
            experimentalMode: true,
            experimentalEngineRaw: TranscriptionEngineChoice.parakeetEou.rawValue,
            realtimeFinalizationRaw: RealtimeFinalizationMode.speedPlusCleanup.rawValue,
            realtimeCleanupRaw: RealtimeShadowCleanupMode.field.rawValue
        )

        XCTAssertEqual(preset, TranscriptionPreset.realtimeCleanup)
    }

    func testLegacyPureSpeedSettingsMigrateToPowerModePreset() {
        let preset = TranscriptionPreset.migrateLegacy(
            experimentalMode: true,
            experimentalEngineRaw: TranscriptionEngineChoice.parakeetEou.rawValue,
            realtimeFinalizationRaw: RealtimeFinalizationMode.pureSpeed.rawValue,
            realtimeCleanupRaw: RealtimeShadowCleanupMode.off.rawValue
        )

        XCTAssertEqual(preset, TranscriptionPreset.powerUserFastest)
    }
}
