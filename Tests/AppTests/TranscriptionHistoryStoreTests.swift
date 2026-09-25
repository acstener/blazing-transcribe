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

    func testDecodesLegacyRecordWithoutCleanupFields() throws {
        let json = """
        [{
          "id": "0F8E3C57-8A8B-4D0B-9C1B-2F6E6D8A9B11",
          "text": "Hello world.",
          "timestamp": "2026-01-02T03:04:05Z",
          "speechDuration": 1.5,
          "transcriptionDuration": 0.2,
          "recordingMode": "ptt",
          "source": "ptt",
          "wordCount": 2,
          "succeeded": true
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([TranscriptionRecord].self, from: Data(json.utf8))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, "Hello world.")
        XCTAssertNil(records[0].rawText)
        XCTAssertNil(records[0].cleanupKind)
        XCTAssertNil(records[0].errorMessage)
        XCTAssertNil(records[0].audioFileName)
        XCTAssertFalse(records[0].dismissed)
        XCTAssertNil(records[0].cleanupDiff)
    }

    func testLegacyHistoryFileLoadsIntoStore() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(baseDirectory)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let json = """
        [{"id":"0F8E3C57-8A8B-4D0B-9C1B-2F6E6D8A9B11","text":"Hi","timestamp":"2026-01-02T03:04:05Z",
          "speechDuration":1,"transcriptionDuration":0.1,"recordingMode":"ptt","source":"ptt",
          "wordCount":1,"succeeded":true,"dismissed":false}]
        """
        try Data(json.utf8).write(to: baseDirectory.appendingPathComponent("history.json"))

        let store = TranscriptionHistoryStore(baseDirectory: baseDirectory)
        XCTAssertEqual(store.allEntries().map(\.text), ["Hi"])
    }

    func testFlushPendingSaveWritesImmediatelyForQuit() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(baseDirectory)
        let store = TranscriptionHistoryStore(baseDirectory: baseDirectory)
        store.insert(makeRecord(text: "Said just before quitting"))

        // No run-loop turn: the debounced save hasn't fired yet, as when the app quits.
        store.flushPendingSave()

        let reloaded = TranscriptionHistoryStore(baseDirectory: baseDirectory)
        XCTAssertEqual(reloaded.allEntries().map(\.text), ["Said just before quitting"])
    }

    func testCleanupFieldsRoundTripAndProduceDiff() throws {
        var record = makeRecord(text: "So we ship it.")
        record.rawText = "um so we ship it"
        record.cleanupKind = .llm

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptionRecord.self, from: encoder.encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.cleanupKind, .llm)
        XCTAssertEqual(decoded.cleanupDiff?.fixCount, 2)
    }

    func testUnknownCleanupKindDropsDiffInsteadOfFailingDecode() throws {
        let json = """
        {"id":"0F8E3C57-8A8B-4D0B-9C1B-2F6E6D8A9B11","text":"Hi","timestamp":"2026-01-02T03:04:05Z",
         "speechDuration":1,"transcriptionDuration":0.1,"recordingMode":"ptt","source":"ptt",
         "wordCount":1,"succeeded":true,"rawText":"um hi","cleanupKind":"somethingNew"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TranscriptionRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.rawText)
        XCTAssertNil(record.cleanupKind)
    }

    func testCleanupDiffIsNilWhenRawMatchesText() {
        var record = makeRecord(text: "Same text")
        record.rawText = "Same   text"
        record.cleanupKind = .fillerRemoval
        XCTAssertNil(record.cleanupDiff)
    }

    func testMarkRetrySucceededStoresAndClearsRawText() {
        let store = makeStore()
        let record = makeRecord(text: "", succeeded: false)
        store.insert(record)

        store.markRetrySucceeded(
            id: record.id, text: "Hello.", wordCount: 1, transcriptionDuration: 0.1,
            rawText: "um hello", cleanupKind: .fillerRemoval
        )
        XCTAssertEqual(store.entry(for: record.id)?.rawText, "um hello")
        XCTAssertEqual(store.entry(for: record.id)?.cleanupKind, .fillerRemoval)

        store.markRetrySucceeded(id: record.id, text: "hello", wordCount: 1, transcriptionDuration: 0.1)
        XCTAssertNil(store.entry(for: record.id)?.rawText)
        XCTAssertNil(store.entry(for: record.id)?.cleanupKind)
    }

    private func makeRecord(text: String, succeeded: Bool = true) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            text: text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            speechDuration: 1,
            transcriptionDuration: 0.1,
            recordingMode: "ptt",
            source: "ptt",
            wordCount: 2,
            succeeded: succeeded
        )
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
