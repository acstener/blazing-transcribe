import XCTest
@testable import Transcription

/// MANUAL end-to-end verification of the encoder-window split fix. Loads the
/// real FluidAudio Parakeet engine (cached models) and transcribes a >15s
/// synthesized speech file both ways:
///   A) whole blob → FluidAudio's internal chunk-merge (the seam-loss path)
///   B) via splitIntoEncoderWindows → single-window requests (the fix)
/// Run explicitly with a >15s 16kHz mono WAV containing the fixture script:
///   say -o /tmp/long.aiff "<script>" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/long.aiff /tmp/long.wav
///   SEAM_TEST_WAV=/tmp/long.wav swift test --filter ManualSeamVerificationTests
/// Skipped otherwise — it needs cached ASR models and takes ~45s.
final class ManualSeamVerificationTests: XCTestCase {
    func testChunkedPathKeepsTailOfLongRecording() async throws {
        guard let wavPath = ProcessInfo.processInfo.environment["SEAM_TEST_WAV"] else {
            throw XCTSkip("manual verification test — set SEAM_TEST_WAV=<path to 16kHz mono wav>")
        }
        let samples = try Self.loadWAV16kMonoInt16(path: wavPath)
        let seconds = Double(samples.count) / 16_000.0
        print("[SeamTest] loaded \(String(format: "%.1f", seconds))s (\(samples.count) samples)")
        XCTAssertGreaterThan(samples.count, TranscriptionService.encoderWindowLimitSamples, "fixture must exceed one encoder window")

        let engine = try await FluidAudioContext.create()

        // A: whole blob through FluidAudio's internal >15s chunk path
        let whole = engine.transcribe(samples: samples, context: nil).text
        print("[SeamTest] WHOLE-BLOB: \"\(whole)\"")

        // B: app-side split, sequential single-window requests
        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)
        print("[SeamTest] split into \(chunks.map { String(format: "%.1fs", Double($0.count) / 16_000.0) })")
        var texts: [String] = []
        var context: String? = nil
        for chunk in chunks {
            let t = engine.transcribe(samples: chunk, context: context).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { texts.append(t); context = t }
        }
        let chunked = texts.joined(separator: " ")
        print("[SeamTest] CHUNKED:    \"\(chunked)\"")

        // The script's final words — the part the seam bug eats.
        let tailMarkers = ["easy to answer", "phone"]
        for marker in tailMarkers {
            XCTAssertTrue(
                chunked.lowercased().contains(marker),
                "chunked path lost tail marker '\(marker)'"
            )
        }
        // Mid-script marker near the 10–14s seam region.
        XCTAssertTrue(chunked.lowercased().contains("concentration"), "chunked path lost mid marker")
    }

    private static func loadWAV16kMonoInt16(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Find the "data" subchunk rather than assuming a 44-byte header.
        guard let range = data.range(of: Data("data".utf8)) else {
            throw NSError(domain: "SeamTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "no data chunk"])
        }
        let payloadStart = range.upperBound + 4  // skip subchunk size field
        let payload = data[payloadStart...]
        var samples = [Float]()
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16s = raw.bindMemory(to: Int16.self)
            for value in int16s {
                samples.append(Float(Int16(littleEndian: value)) / 32768.0)
            }
        }
        return samples
    }
}
