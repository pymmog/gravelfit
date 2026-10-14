import Foundation
import Observation

@MainActor @Observable final class SessionRepository {
    private(set) var sessions: [FitSession] = []
    var bikes: [BikeProfile] = []
    var settings = FitSettings()
    var error: String?
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GravelFit", isDirectory: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let config = self.directory.appendingPathComponent("configuration.json")
            if FileManager.default.fileExists(atPath: config.path) {
                let saved = try decoder.decode(Configuration.self, from: Data(contentsOf: config))
                bikes = saved.bikes; settings = saved.settings
            }
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("session-") && url.pathExtension == "json" {
                do { sessions.append(try decoder.decode(FitSession.self, from: Data(contentsOf: url))) }
                catch { self.error = "Could not load \(url.lastPathComponent): \(error.localizedDescription)" }
            }
            sessions.sort { $0.created > $1.created }
            // Restore completed measurement lines after a crash or power interruption.
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("journal-") && url.pathExtension == "jsonl" {
                let identifier = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "journal-", with: "")
                guard let id = UUID(uuidString: identifier), let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
                do {
                    let (samples, strokes) = try SessionRecorder.read(url: url)
                    var recovered = sessions[index]
                    if !samples.isEmpty {
                        recovered.samples = samples; recovered.strokes = strokes
                        recovered.duration = samples.last?.time ?? 0
                        recovered.observations += "\nRecovered measurements after an interrupted recording. The movie may be incomplete."
                        try save(recovered)
                    }
                    try FileManager.default.removeItem(at: url)
                } catch { self.error = "Could not recover interrupted recording: \(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription }
    }
    private struct Configuration: Codable { var bikes: [BikeProfile]; var settings: FitSettings }
    func saveConfiguration() throws {
        try saveConfiguration(bikes: bikes)
    }
    private func saveConfiguration(bikes: [BikeProfile]) throws {
        try encoder.encode(Configuration(bikes: bikes, settings: settings)).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
    }
    func saveBike(_ bike: BikeProfile) throws {
        var updated = bikes
        if let index = updated.firstIndex(where: { $0.id == bike.id }) { updated[index] = bike }
        else { updated.append(bike) }
        try saveConfiguration(bikes: updated)
        bikes = updated
    }
    func deleteBike(_ id: UUID) throws {
        guard bikes.contains(where: { $0.id == id }) else { return }
        let remaining = bikes.filter { $0.id != id }
        try saveConfiguration(bikes: remaining)
        bikes = remaining
    }
    func save(_ session: FitSession) throws {
        try encoder.encode(session).write(to: directory.appendingPathComponent("session-\(session.id).json"), options: .atomic)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.insert(session, at: 0) }
    }
    func videoURL(_ session: FitSession) -> URL? {
        guard let name = session.videoFilename, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        return directory.appendingPathComponent(name)
    }
    func delete(_ session: FitSession) throws {
        if let url = videoURL(session), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("session-\(session.id).json"))
        sessions.removeAll { $0.id == session.id }
    }
    func deleteAll() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
        sessions = []; bikes = []; settings = FitSettings()
        try saveConfiguration()
    }
    func setBaseline(_ id: UUID) throws {
        for var session in sessions { session.isBaseline = session.id == id; try save(session) }
    }
    func json(_ session: FitSession) throws -> Data { try encoder.encode(session) }
    func csv(_ session: FitSession) -> String {
        let kinds = MetricKind.allCases
        var lines = [(["time_seconds", "confidence"] + kinds.map { "\($0.rawValue)_\($0.unit == "°" ? "degrees" : "percent")" }).joined(separator: ",")]
        for sample in session.samples {
            lines.append(([String(format: "%.3f", sample.time), String(format: "%.3f", sample.confidence)] + kinds.map { sample.values[$0].map { String(format: "%.3f", $0) } ?? "" }).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
    func summary(_ session: FitSession) -> String {
        let bikeName = session.bikeSnapshot?.name ?? session.bikeID.map { id in bikes.first(where: { $0.id == id })?.name ?? "Archived bike" } ?? "No bike profile"
        var result = "GravelFit — \(session.name)\n\(session.created.formatted())\nBike: \(bikeName)\nVisible side: \(session.settings.side.title) · hands: \(session.settings.handPosition.rawValue)\nDuration: \(Int(session.duration)) s\n\n"
        if let range = session.sourceRange { result += "Selected source video: \(String(format: "%.3f", range.start))–\(String(format: "%.3f", range.end)) s. The trimmed video's timestamps start at zero.\n\n" }
        if let bike = session.bikeSnapshot {
            result += "Setup snapshot: crank \(bike.crankLength) mm; saddle height \(bike.saddleHeight) mm, setback \(bike.saddleSetback) mm, tilt \(bike.saddleTilt)°; bar drop \(bike.handlebarDrop) mm, reach \(bike.effectiveReach) mm, stem \(bike.stemLength) mm, width \(bike.handlebarWidth) mm.\nCleats: \(bike.cleatNotes)\nRider: \(bike.riderNotes)\n\n"
        }
        for kind in MetricKind.allCases {
            let stats = session.statistics[kind] ?? MetricStatistics()
            let format: (Double?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "Unavailable" }
            result += "\(kind.title): min \(format(stats.minimum)), max \(format(stats.maximum)), mean \(format(stats.average)) \(kind.unit)\n"
        }
        let extensions = session.strokes.map(\.minimumKneeFlexion)
        result += "\nDetected strokes: \(session.strokes.count)\nMean maximum-extension flexion: \(extensions.isEmpty ? "Unavailable" : String(format: "%.1f°", extensions.reduce(0,+) / Double(extensions.count)))\n"
        result += "\nManual crank annotations:\n"
        for item in session.annotations { result += "\(item.position.rawValue) at \(String(format: "%.3f", item.time)) s; knee \(item.kneeFlexion.map { String(format: "%.1f°", $0) } ?? "Unavailable"), hip \(item.hipAngle.map { String(format: "%.1f°", $0) } ?? "Unavailable")\n" }
        result += "\nConfirmed adjustments:\n"
        for adjustment in session.adjustments {
            result += "\(adjustment.step.title): \(adjustment.amount) \(adjustment.unit) — \(adjustment.notes)\n"
            for kind in MetricKind.allCases {
                if let before = adjustment.before[kind], let after = adjustment.after?[kind] { result += "  \(kind.title): \(String(format: "%.1f → %.1f (Δ %+.1f)", before, after, after - before)) \(kind.unit)\n" }
            }
        }
        result += "\nObservations:\n\(session.observations)\n\nUncertainty notes:\n2D side-view measurements depend on camera alignment, perspective, clothing, occlusion, and Vision tracking. Detection confidence is not a calibrated angular uncertainty. No anatomical hip flexion or lateral pelvic rocking is inferred. Maximum leg extension is not crank bottom dead center; crank-specific values require manually annotated frames. Reference ranges are working starting points, not prescriptions.\n"
        return result
    }
}
