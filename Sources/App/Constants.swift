import Foundation

enum Constants {
    static let appName = "Blazing Transcribe"
    static let bundleIdentifier = "com.blazingtranscribe.app"

    // Audio
    static let sampleRate: Double = 16000
    static let ringBufferSeconds: Double = 30
    static let ringBufferCapacity: Int = Int(sampleRate * ringBufferSeconds)
    static let defaultCaptureSeconds: Double = 5

    // Analytics keys live in AnalyticsSecrets.swift (gitignored), not here.
}
