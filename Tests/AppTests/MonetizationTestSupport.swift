import Foundation
@testable import App

struct KeyedStorageHarness {
    let suiteName: String
    let defaults: UserDefaults
    let keychainService: String

    func reset() {
        defaults.removePersistentDomain(forName: suiteName)
        [
            "freeTier.wordsUsed",
            "freeTier.periodStart",
            "com.blazing.fast-transcription.licenseKey",
            "com.blazing.fast-transcription.instanceId",
            "com.blazing.fast-transcription.trialStartDate",
            "com.blazing.fast-transcription.monetizationResetVersion",
        ].forEach { key in
            AppKeychainStore.delete(key: key, service: keychainService)
        }
    }
}

final class TestNotificationCounter {
    var count = 0
}
