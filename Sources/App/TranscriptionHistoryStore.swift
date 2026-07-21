import Foundation

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let timestamp: Date
    let speechDuration: Double
    var transcriptionDuration: Double
    let recordingMode: String
    let source: String
    var wordCount: Int
    var succeeded: Bool
    var errorMessage: String?
    var audioFileName: String?
    var dismissed: Bool = false
}

final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()

    private var records: [TranscriptionRecord] = []
    private let maxEntries = 500
    private let audioRetentionInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private let audioCacheMaxFileCount = 24
    private let audioCacheMaxTotalBytes = 256 * 1_024 * 1_024

    private let historyURL: URL
    let audioCacheURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(baseDirectory: URL = TranscriptionHistoryStore.defaultBaseDirectory()) {
        historyURL = baseDirectory.appendingPathComponent("history.json")
        audioCacheURL = baseDirectory.appendingPathComponent("AudioCache")

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioCacheURL, withIntermediateDirectories: true)

        loadFromDisk()
    }

    // MARK: - Public API

    func insert(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        pruneToLimit(maxEntries)
        scheduleSave()
        NotificationCenter.default.post(name: .transcriptionHistoryDidChange, object: nil)
    }

    func recentEntries(limit: Int = 50) -> [TranscriptionRecord] {
        Array(records.prefix(limit))
    }

    func allEntries() -> [TranscriptionRecord] {
        records
    }

    func search(query: String) -> [TranscriptionRecord] {
        guard !query.isEmpty else { return records }
        let lowered = query.lowercased()
        return records.filter { $0.text.lowercased().contains(lowered) }
    }

    func deleteEntry(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        if let audioFile = record.audioFileName {
            let audioURL = audioCacheURL.appendingPathComponent(audioFile)
            try? FileManager.default.removeItem(at: audioURL)
        }
        records.remove(at: index)
        scheduleSave()
    }

    func entry(for id: UUID) -> TranscriptionRecord? {
        records.first(where: { $0.id == id })
    }

    @discardableResult
    func markRetrySucceeded(id: UUID, text: String, wordCount: Int, transcriptionDuration: Double) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        if let audioFile = records[index].audioFileName {
            removeAudioFile(fileName: audioFile)
        }
        records[index].text = text
        records[index].wordCount = wordCount
        records[index].transcriptionDuration = transcriptionDuration
        records[index].succeeded = true
        records[index].errorMessage = nil
        records[index].audioFileName = nil
        records[index].dismissed = false
        scheduleSave()
        NotificationCenter.default.post(name: .transcriptionHistoryDidChange, object: nil)
        return true
    }

    func updateFailure(id: UUID, errorMessage: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].errorMessage = errorMessage
        records[index].succeeded = false
        scheduleSave()
        NotificationCenter.default.post(name: .transcriptionHistoryDidChange, object: nil)
    }

    // MARK: - Dismiss / Recover

    func dismissEntry(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].dismissed = true
        scheduleSave()
    }

    func recoverEntry(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].dismissed = false
        scheduleSave()
    }

    // MARK: - Audio Cache

    func saveAudio(samples: [Float], id: UUID) -> String? {
        let fileName = "\(id.uuidString).pcm"
        let fileURL = audioCacheURL.appendingPathComponent(fileName)
        let data = samples.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: fileURL)
            return fileName
        } catch {
            #if DEBUG
            print("[History] Failed to save audio cache: \(error)")
            #endif
            return nil
        }
    }

    func adoptAudioFile(from sourceURL: URL, id: UUID) -> String? {
        let fileName = "\(id.uuidString).pcm"
        let destinationURL = audioCacheURL.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try? FileManager.default.removeItem(at: sourceURL)
            }
            return fileName
        } catch {
            #if DEBUG
            print("[History] Failed to adopt audio file: \(error)")
            #endif
            return nil
        }
    }

    func loadAudio(fileName: String) -> [Float]? {
        let fileURL = audioCacheURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest)
        }
        return samples
    }

    /// Audio file URL for a given filename (for download/export).
    func audioFileURL(fileName: String) -> URL {
        audioCacheURL.appendingPathComponent(fileName)
    }

    func removeAudioFile(fileName: String) {
        let fileURL = audioCacheURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clean up audio files older than 24 hours. Call on app launch.
    func cleanupExpiredAudio() {
        let cutoff = Date().addingTimeInterval(-audioRetentionInterval)
        let fm = FileManager.default

        // Remove old audio files
        guard let files = try? fm.contentsOfDirectory(at: audioCacheURL, includingPropertiesForKeys: [.creationDateKey]) else { return }
        struct AudioFileMetadata {
            let url: URL
            let fileName: String
            let createdAt: Date
            let sizeBytes: Int64
        }

        let metadata = files.compactMap { file -> AudioFileMetadata? in
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let created = attrs[.creationDate] as? Date else { return nil }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return AudioFileMetadata(url: file, fileName: file.lastPathComponent, createdAt: created, sizeBytes: size)
        }

        var removedFileNames = Set<String>()

        for file in metadata where file.createdAt < cutoff {
            try? fm.removeItem(at: file.url)
            removedFileNames.insert(file.fileName)
        }

        let freshFiles = metadata
            .filter { !removedFileNames.contains($0.fileName) }
            .sorted { $0.createdAt > $1.createdAt }

        var keptCount = 0
        var keptBytes: Int64 = 0

        for file in freshFiles {
            let wouldExceedCount = keptCount >= audioCacheMaxFileCount
            let wouldExceedBytes = keptCount > 0 && (keptBytes + file.sizeBytes) > Int64(audioCacheMaxTotalBytes)
            if wouldExceedCount || wouldExceedBytes {
                try? fm.removeItem(at: file.url)
                removedFileNames.insert(file.fileName)
                continue
            }
            keptCount += 1
            keptBytes += file.sizeBytes
        }

        guard !removedFileNames.isEmpty else { return }

        for fileName in removedFileNames {
            if let index = records.firstIndex(where: { $0.audioFileName == fileName }) {
                records[index].audioFileName = nil
            }
        }
        scheduleSave()
        NotificationCenter.default.post(name: .transcriptionHistoryDidChange, object: nil)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([TranscriptionRecord].self, from: data)) ?? []
    }

    private static let saveQueue = DispatchQueue(label: "com.blazingtranscribe.history-save", qos: .utility)

    private static func defaultBaseDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlazingTranscribe")
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        let url = historyURL
        Self.saveQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func pruneToLimit(_ max: Int) {
        guard records.count > max else { return }
        let removed = records.suffix(from: max)
        for record in removed {
            if let audioFile = record.audioFileName {
                let audioURL = audioCacheURL.appendingPathComponent(audioFile)
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        records = Array(records.prefix(max))
    }
}
