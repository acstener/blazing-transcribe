import XCTest
@testable import App

final class TranscriptionHistoryStoreTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDown() {
        createdDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        createdDirectories.removeAll()
        super.tearDown()
    }

    func testAdoptAudioFileMovesPCMIntoCache() {
        let store = makeStore()
        let id = UUID()
        let sourceURL = makePCMFile(samples: [0.1, 0.2, 0.3])

        let adoptedFileName = store.adoptAudioFile(from: sourceURL, id: id)

        XCTAssertEqual(adoptedFileName, "\(id.uuidString).pcm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))

        guard let adoptedFileName else {
            return XCTFail("Expected adopted audio file name")
        }

        let cachedURL = store.audioFileURL(fileName: adoptedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedURL.path))
        XCTAssertEqual(store.loadAudio(fileName: adoptedFileName), [0.1, 0.2, 0.3])
    }

    func testMarkRetrySucceededClearsRetainedAudioAndFailureState() {
        let store = makeStore()
        let id = UUID()
        let audioFileName = store.saveAudio(samples: [0.4, 0.5, 0.6], id: id)

        guard let audioFileName else {
            return XCTFail("Expected cached audio file")
        }

        store.insert(
            TranscriptionRecord(
                id: id,
                text: "",
                timestamp: Date(),
                speechDuration: 1.5,
                transcriptionDuration: 0,
                recordingMode: "manual",
                source: "retry",
                wordCount: 0,
                succeeded: false,
                errorMessage: "Engine still loading",
                audioFileName: audioFileName
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.audioFileURL(fileName: audioFileName).path
            )
        )

        XCTAssertTrue(
            store.markRetrySucceeded(
                id: id,
                text: "hello world",
                wordCount: 2,
                transcriptionDuration: 0.42
            )
        )

        guard let updatedRecord = store.entry(for: id) else {
            return XCTFail("Expected updated history record")
        }

        XCTAssertEqual(updatedRecord.text, "hello world")
        XCTAssertEqual(updatedRecord.wordCount, 2)
        XCTAssertEqual(updatedRecord.transcriptionDuration, 0.42, accuracy: 0.0001)
        XCTAssertTrue(updatedRecord.succeeded)
        XCTAssertNil(updatedRecord.errorMessage)
        XCTAssertNil(updatedRecord.audioFileName)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.audioFileURL(fileName: audioFileName).path
            )
        )
    }

    func testCleanupExpiredAudioClearsReferencesForRemovedOverflowFiles() {
        let store = makeStore()
        let totalEntries = 26

        for index in 0..<totalEntries {
            let id = UUID()
            let audioFileName = store.saveAudio(
                samples: Array(repeating: Float(index), count: 8_000),
                id: id
            )
            XCTAssertNotNil(audioFileName)

            store.insert(
                TranscriptionRecord(
                    id: id,
                    text: "",
                    timestamp: Date().addingTimeInterval(TimeInterval(index)),
                    speechDuration: 5,
                    transcriptionDuration: 0,
                    recordingMode: "manual",
                    source: "toggle",
                    wordCount: 0,
                    succeeded: false,
                    errorMessage: "Forced failure",
                    audioFileName: audioFileName
                )
            )
        }

        store.cleanupExpiredAudio()

        let remainingFiles = (try? FileManager.default.contentsOfDirectory(
            at: store.audioCacheURL,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(remainingFiles.count, 24)

        let clearedReferences = store.allEntries().filter { $0.audioFileName == nil }
        XCTAssertEqual(clearedReferences.count, totalEntries - 24)
    }

    private func makeStore() -> TranscriptionHistoryStore {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(baseDirectory)
        return TranscriptionHistoryStore(baseDirectory: baseDirectory)
    }

    private func makePCMFile(samples: [Float]) -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionHistoryStoreSource-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(baseDirectory)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent("source.pcm")
        let data = samples.withUnsafeBytes { Data($0) }
        try? data.write(to: url)
        return url
    }
}
