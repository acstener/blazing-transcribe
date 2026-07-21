import XCTest
@testable import Transcription

final class EncoderWindowSplitTests: XCTestCase {
    private let sampleRate = 16_000

    private func seconds(_ s: Double) -> Int { Int(s * Double(sampleRate)) }

    /// Loud pseudo-speech with a quiet gap at a known position.
    private func makeAudio(totalSeconds: Double, quietGaps: [(start: Double, duration: Double)]) -> [Float] {
        var samples = [Float](repeating: 0.5, count: seconds(totalSeconds))
        for gap in quietGaps {
            let start = seconds(gap.start)
            let end = min(samples.count, start + seconds(gap.duration))
            for i in start..<end { samples[i] = 0.001 }
        }
        return samples
    }

    func testShortAudioPassesThroughUnchanged() {
        let samples = makeAudio(totalSeconds: 10, quietGaps: [])
        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, samples.count)
    }

    func testExactlyOneWindowPassesThroughUnchanged() {
        let samples = [Float](repeating: 0.5, count: TranscriptionService.encoderWindowLimitSamples)
        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)
        XCTAssertEqual(chunks.count, 1)
    }

    func testLongAudioSplitsAtQuietGap() {
        // 22s of speech with a clear pause at 12.0–12.4s: the split should land
        // inside that pause, not at the hard 14s boundary.
        let samples = makeAudio(totalSeconds: 22, quietGaps: [(start: 12.0, duration: 0.4)])
        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)

        XCTAssertEqual(chunks.count, 2)
        let splitPoint = chunks[0].count
        XCTAssertGreaterThan(splitPoint, seconds(12.0))
        XCTAssertLessThan(splitPoint, seconds(12.4))
        // No samples lost or duplicated.
        XCTAssertEqual(chunks.map(\.count).reduce(0, +), samples.count)
    }

    func testEveryChunkFitsOneEncoderWindow() {
        // 65s of continuous loud speech — worst case, no quiet gaps at all.
        let samples = makeAudio(totalSeconds: 65, quietGaps: [])
        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, TranscriptionService.encoderWindowLimitSamples)
            XCTAssertGreaterThanOrEqual(chunk.count, TranscriptionService.minimumChunkSamples)
        }
        XCTAssertEqual(chunks.map(\.count).reduce(0, +), samples.count)
    }

    func testFinalTailAlwaysMeetsASRMinimumAcrossAdversarialLengths() {
        // The earliest split (10.1s) and latest split (13.9s) bound the tail:
        // it can never fall below the 1s ASR minimum with current constants,
        // and the defensive pad guarantees it even if constants change. Sweep
        // lengths just past each window boundary to probe the worst cases.
        for extraSeconds in [0.01, 0.2, 0.9, 1.0, 7.0] {
            let total = TranscriptionService.encoderWindowLimitSamples + seconds(extraSeconds)
            let samples = [Float](repeating: 0.5, count: total)
            let chunks = TranscriptionService.splitIntoEncoderWindows(samples)

            guard let last = chunks.last else { return XCTFail("no chunks") }
            XCTAssertGreaterThanOrEqual(
                last.count,
                TranscriptionService.minimumChunkSamples,
                "tail below ASR minimum for total=\(total)"
            )
        }
    }

    func testSplitPointsPreferQuietestOfSeveralGaps() {
        // Two pauses in the search range (10s–14s); the deeper one at 13s
        // should win over the shallower one at 11s.
        var samples = makeAudio(totalSeconds: 20, quietGaps: [])
        for i in seconds(11.0)..<seconds(11.3) { samples[i] = 0.05 }   // shallow pause
        for i in seconds(13.0)..<seconds(13.3) { samples[i] = 0.0005 } // deep pause

        let chunks = TranscriptionService.splitIntoEncoderWindows(samples)
        XCTAssertEqual(chunks.count, 2)
        let splitPoint = chunks[0].count
        XCTAssertGreaterThan(splitPoint, seconds(13.0))
        XCTAssertLessThan(splitPoint, seconds(13.3))
    }
}
