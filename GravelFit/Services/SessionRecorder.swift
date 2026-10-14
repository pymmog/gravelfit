import Foundation

/// Journals small measurement records to disk while AVFoundation writes video directly to disk.
/// At most 32 journal writes can be pending; disk errors stop the recording instead of growing a queue.
final class SessionRecorder: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        var sample: MetricSample?
        var stroke: PedalStroke?
    }
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "GravelFit.session-journal", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingWrites = 0
    private var acceptingWrites = true
    private let onFailure: @Sendable (String) -> Void
    private var failure: String?
    private var writes = 0
    init(directory: URL, id: UUID, onFailure: @escaping @Sendable (String) -> Void) throws {
        url = directory.appendingPathComponent("journal-\(id).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        self.onFailure = onFailure
    }
    func append(sample: MetricSample) { append(Entry(sample: sample)) }
    func append(stroke: PedalStroke) { append(Entry(stroke: stroke)) }
    private func append(_ entry: Entry) {
        let accepted = pendingLock.withLock {
            guard acceptingWrites, pendingWrites < 32 else { return false }
            pendingWrites += 1
            return true
        }
        guard accepted else { onFailure("The measurement journal is closed or its disk queue is full. Recording stopped to preserve responsiveness."); return }
        queue.async { [self] in
            defer { pendingLock.withLock { pendingWrites -= 1 } }
            guard failure == nil else { return }
            do {
                var data = try JSONEncoder().encode(entry); data.append(10)
                try handle.write(contentsOf: data)
                writes += 1
                if writes % 10 == 0 { try handle.synchronize() }
            } catch { failure = error.localizedDescription; onFailure("Could not write session measurements: \(error.localizedDescription)") }
        }
    }
    func finish() async throws -> ([MetricSample], [PedalStroke]) {
        pendingLock.withLock { acceptingWrites = false }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try handle.synchronize(); try handle.close()
                    let result = try Self.read(url: url)
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func read(url: URL) throws -> ([MetricSample], [PedalStroke]) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var pending = Data()
        var samples: [MetricSample] = [], strokes: [PedalStroke] = []
        let decoder = JSONDecoder()
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                let entry = try decoder.decode(Entry.self, from: line)
                if let sample = entry.sample { samples.append(sample) }
                if let stroke = entry.stroke { strokes.append(stroke) }
                pending.removeSubrange(...end)
            }
        }
        // An interrupted final write may leave an incomplete trailing record; completed lines survive.
        return (samples, strokes)
    }
}
