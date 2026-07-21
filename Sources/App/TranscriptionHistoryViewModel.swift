import AppKit
import Foundation

@Observable
final class TranscriptionHistoryViewModel {
    var entries: [TranscriptionRecord] = []
    var searchText: String = ""

    var onRetryTranscription: ((UUID) -> Void)?
    var onNavigateToStats: (() -> Void)?

    func loadRecent(limit: Int = 50) {
        entries = TranscriptionHistoryStore.shared.recentEntries(limit: limit)
        rebuildGroupedEntries()
    }

    func search(_ query: String) {
        if query.isEmpty {
            loadRecent()
        } else {
            entries = Array(TranscriptionHistoryStore.shared.search(query: query).prefix(50))
            rebuildGroupedEntries()
        }
    }

    func copyToClipboard(_ entry: TranscriptionRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    func copyDayTranscriptions(_ entries: [TranscriptionRecord]) {
        let texts = entries
            .filter { $0.succeeded && !$0.dismissed }
            .map { $0.text }
            .joined(separator: "\n\n")
        guard !texts.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(texts, forType: .string)
    }

    func retryTranscription(_ entry: TranscriptionRecord) {
        #if DEBUG
        print("[History] Retry tapped for \(entry.id) — callback \(onRetryTranscription == nil ? "NOT SET" : "ok")")
        #endif
        onRetryTranscription?(entry.id)
    }

    func dismissEntry(_ entry: TranscriptionRecord) {
        TranscriptionHistoryStore.shared.dismissEntry(id: entry.id)
        refresh()
    }

    func recoverEntry(_ entry: TranscriptionRecord) {
        TranscriptionHistoryStore.shared.recoverEntry(id: entry.id)
        refresh()
    }

    func deleteEntry(_ entry: TranscriptionRecord) {
        TranscriptionHistoryStore.shared.deleteEntry(id: entry.id)
        refresh()
    }

    func downloadAudio(_ entry: TranscriptionRecord) {
        guard let audioFile = entry.audioFileName else { return }
        let sourceURL = TranscriptionHistoryStore.shared.audioFileURL(fileName: audioFile)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "recording_\(entry.id.uuidString.prefix(8)).wav"
        panel.allowedContentTypes = [.wav]
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            // Convert raw PCM to WAV
            Self.writePCMAsWAV(source: sourceURL, destination: destURL)
        }
    }

    // MARK: - Grouping

    struct DayGroup: Identifiable {
        let id: String // date string key
        let label: String
        let entries: [TranscriptionRecord]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private(set) var groupedEntries: [DayGroup] = []

    private func rebuildGroupedEntries() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [String: [TranscriptionRecord]] = [:]
        var groupOrder: [String] = []

        for entry in entries {
            let entryDay = calendar.startOfDay(for: entry.timestamp)
            let key: String
            if entryDay == today {
                key = "TODAY"
            } else if entryDay == yesterday {
                key = "YESTERDAY"
            } else {
                key = Self.dayFormatter.string(from: entry.timestamp).uppercased()
            }

            if groups[key] == nil {
                groupOrder.append(key)
            }
            groups[key, default: []].append(entry)
        }

        groupedEntries = groupOrder.compactMap { key in
            guard let entries = groups[key] else { return nil }
            return DayGroup(id: key, label: key, entries: entries)
        }
    }

    // MARK: - Private

    private func refresh() {
        if searchText.isEmpty {
            loadRecent()
        } else {
            search(searchText)
        }
    }

    private static func writePCMAsWAV(source: URL, destination: URL) {
        guard let pcmData = try? Data(contentsOf: source) else { return }
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 32 // Float32
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) }) // IEEE float
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var wavData = header
        wavData.append(pcmData)
        try? wavData.write(to: destination)
    }
}
