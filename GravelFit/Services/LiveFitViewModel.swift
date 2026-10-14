import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor @Observable final class CalibrationManager {
    var step = 0
    var isPresented = false
    var startedAt: Date?
    var goodFrames = 0
    var totalFrames = 0
    var instructions: [String] { [
        "Select and connect your camera. An iPhone appears as a standard Continuity Camera device; no companion app is required.",
        "Place the camera perpendicular to the bicycle, around hip height. Keep it level and far enough away to reduce perspective distortion.",
        "Keep the visible shoulder, elbow, wrist, hip, knee and ankle fully in frame throughout the stroke.",
        "Use even lighting and fitted clothing. Tracking should show one cyclist with all six visible-side joints reliably detected.",
        "Align the horizontal reference with the floor. Enter the floor slope in degrees if the image is tilted. Positive slope rises to the right in the unmirrored image.",
        "Select the anatomical side facing the camera and your hand position. Mirroring changes display only; left and right still refer to your body.",
        "Pedal steadily for at least 10 seconds. We check tracking reliability and repeated knee-flexion cycles.",
        "Calibration is complete. References are working ranges; combine repeated measurements with comfort and direct setup checks."
    ] }
    func begin() { step = 0; goodFrames = 0; totalFrames = 0; startedAt = nil; isPresented = true }
    func collect(_ sample: MetricSample, threshold: Double) {
        guard isPresented, step == 6 else { return }
        if startedAt == nil { startedAt = Date() }
        totalFrames += 1
        if sample.confidence >= threshold && sample.values[.kneeFlexion] != nil { goodFrames += 1 }
    }
    var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var reliable: Bool { elapsed >= 10 && totalFrames >= 40 && Double(goodFrames) / Double(totalFrames) >= 0.8 }
}

@MainActor @Observable final class LiveFitViewModel {
    var camera = CameraManager()
    var repository: SessionRepository
    var calibration = CalibrationManager()
    let offline = OfflineAnalyzer()
    var settings: FitSettings
    var engine = BikeFitAnalysisEngine()
    var pose: PoseFrame?
    var sample: MetricSample?
    var trails: [PoseFrame] = []
    var trackingMessage = "Connect a camera to begin"
    var isRecording = false
    var isFinishing = false
    var importProgress: Double?
    var videoTrimRequest: VideoTrimRequest?
    var videoProcessingStage = "Analyzing video locally…"
    var error: String?
    var activeBikeID: UUID?
    var fitStep: FitStep = .cleats
    var adjustments: [Adjustment] = []
    var pendingAdjustmentID: UUID?
    var captureProgress: Double?
    var lastCapture: [MetricKind: Double] = [:]
    var observations = ""
    var sessionName = "Gravel fit"
    var recordingStarted: Date?
    @ObservationIgnored private var session: FitSession?
    @ObservationIgnored private var recorder: SessionRecorder?
    @ObservationIgnored private var lastRecordingSampleTime = -Double.infinity
    @ObservationIgnored private var recordingAccumulator = MeasurementAccumulator()
    @ObservationIgnored private var recordingOrigin: Double?
    @ObservationIgnored private var lastStrokeID: UUID?
    @ObservationIgnored private var captureStarted: Double?
    @ObservationIgnored private var captureSamples: [MetricSample] = []
    @ObservationIgnored private var lastReceived = Date.distantPast
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var poseTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var videoProcessingID: UUID?
    @ObservationIgnored private var terminationCompletion: (() -> Void)?

    init(repository: SessionRepository? = nil) {
        let repository = repository ?? SessionRepository()
        self.repository = repository
        var initialSettings = repository.settings
        // A persisted camera setup cannot prove today's physical camera alignment.
        initialSettings.calibrated = false
        settings = initialSettings
        camera.rotation = videoRotation
        let (stream, continuation) = AsyncStream<PoseFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        poseTask = Task { [weak self] in
            for await frame in stream { guard let self else { break }; self.receive(frame) }
        }
        camera.service = PoseDetectionService(onPose: { frame in
            continuation.yield(frame)
        }, onError: { [weak self] message in
            Task { @MainActor in self?.trackingMessage = message }
        })
        camera.service?.setFPS(settings.analysisFPS)
        camera.prepareConnection = { [weak self] in self?.updateSettings() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastReceived) > 0.8 else { return }
                self.pose = nil; self.sample = nil; self.trails.removeAll()
                self.trackingMessage = self.camera.state == .connected ? "Waiting for camera frames" : self.camera.state.title
                self.captureStarted = nil; self.captureSamples.removeAll(); self.captureProgress = nil
            }
        }
    }
    var busy: Bool { isRecording || isFinishing || importProgress != nil || videoTrimRequest != nil }
    var isIPhoneCameraSelected: Bool {
        camera.devices.first(where: { $0.id == camera.selectedID })?.continuity == true
    }
    var videoRotation: Double {
        // Keep the other cameras' configured orientation; iPhone capture is always portrait.
        isIPhoneCameraSelected ? (settings.rotation == 270 ? 270 : 90) : settings.rotation
    }
    func connectCamera() async {
        guard !busy else { return }
        updateSettings()
        await camera.connect()
    }
    var canChangeBike: Bool { !busy && adjustments.isEmpty && pendingAdjustmentID == nil && captureProgress == nil }
    func selectBike(_ id: UUID?) {
        guard canChangeBike, id == nil || repository.bikes.contains(where: { $0.id == id }), activeBikeID != id else { return }
        activeBikeID = id
        lastCapture = [:]
    }
    func canDeleteBike(_ id: UUID) -> Bool {
        !busy && repository.bikes.contains(where: { $0.id == id }) &&
        (id != activeBikeID || (adjustments.isEmpty && pendingAdjustmentID == nil && captureProgress == nil))
    }
    @discardableResult func deleteBike(_ id: UUID) -> Bool {
        guard canDeleteBike(id) else { return false }
        do {
            try repository.deleteBike(id)
            if activeBikeID == id {
                activeBikeID = nil
                beginNewFit()
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    var currentStatistics: [MetricKind: MetricStatistics] {
        Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { kind in
            var stats = engine.statistics(kind)
            stats.current = sample?.values[kind]
            return (kind, stats)
        })
    }
    private func receive(_ raw: PoseFrame) {
        guard camera.state == .connected || camera.state == .connecting else { return }
        lastReceived = Date()
        let (filtered, result) = engine.process(raw, settings: settings)
        pose = filtered; sample = result
        if settings.showTrails { trails.append(filtered); if trails.count > 24 { trails.removeFirst() } }
        else { trails.removeAll() }
        switch raw.peopleCount {
        case 0: trackingMessage = "No cyclist detected · check framing and lighting"
        case 1:
            trackingMessage = result.confidence >= settings.confidenceThreshold ? "Tracking cyclist · \(Int(1000 / max(1, raw.processingMilliseconds))) FPS capacity" : "Partial / low-confidence pose · check lighting and visible-side joints"
        default: trackingMessage = "Multiple people visible · keep only the cyclist in frame"
        }
        calibration.collect(result, threshold: settings.confidenceThreshold)
        if captureProgress != nil {
            if result.confidence < settings.confidenceThreshold { captureStarted = nil; captureSamples.removeAll(); captureProgress = 0 }
            else {
                if captureStarted == nil { captureStarted = result.time }
                captureSamples.append(result)
                captureProgress = min(1, (result.time - (captureStarted ?? result.time)) / 8)
                if (captureProgress ?? 0) >= 1 { finishMeasurement() }
            }
        }
        guard isRecording, var recording = session else { return }
        if recordingOrigin == nil { recordingOrigin = result.time }
        let relative = max(0, result.time - (recordingOrigin ?? result.time))
        var recorded = result; recorded.time = relative
        recordingAccumulator.append(recorded)
        if relative - lastRecordingSampleTime >= 0.5 { recorder?.append(sample: recorded); lastRecordingSampleTime = relative }
        if let stroke = engine.cycles.strokes.last, stroke.id != lastStrokeID {
            lastStrokeID = stroke.id
            if stroke.start >= (recordingOrigin ?? result.time) {
                var saved = stroke; saved.start -= recordingOrigin ?? 0; saved.end -= recordingOrigin ?? 0
                recorder?.append(stroke: saved)
            }
        }
        recording.duration = relative
        session = recording
    }
    func updateSettings(resetAnalysis: Bool = false) {
        let old = repository.settings
        let rotation = videoRotation
        let geometryChanged = old.side != settings.side || camera.rotation != rotation || old.floorAngle != settings.floorAngle
        let trackingChanged = old.smoothing != settings.smoothing || old.confidenceThreshold != settings.confidenceThreshold || old.handPosition != settings.handPosition
        if geometryChanged || resetAnalysis { settings.calibrated = false }
        repository.settings = settings
        camera.rotation = rotation
        camera.pipeline.setRotation(rotation)
        camera.service?.setFPS(settings.analysisFPS)
        if resetAnalysis || geometryChanged || trackingChanged { engine.reset(); pose = nil; sample = nil; trails.removeAll(); lastCapture = [:] }
        do { try repository.saveConfiguration() } catch { self.error = error.localizedDescription }
    }
    func beginNewFit() {
        guard !busy else { return }
        engine.reset(); adjustments = []; pendingAdjustmentID = nil; lastCapture = [:]
        fitStep = .cleats; observations = ""; cancelMeasurement()
    }
    /// Capture optional bike metadata once for metrics, recordings and video imports.
    func makeSession(name: String, id: UUID = UUID()) -> FitSession {
        let bike = repository.bikes.first { $0.id == activeBikeID }
        var result = FitSession(id: id, name: name, bikeID: bike?.id, settings: settings)
        result.settings.rotation = videoRotation
        result.bikeSnapshot = bike
        return result
    }
    func startRecording() {
        guard camera.state == .connected, !busy else { return }
        let newSession = makeSession(name: sessionName.isEmpty ? "Gravel fit" : sessionName)
        let filename = "video-\(newSession.id).mov"
        session = newSession; session?.videoFilename = filename
        do {
            recorder = try SessionRecorder(directory: repository.directory, id: newSession.id) { [weak self] message in
                Task { @MainActor in self?.error = message; self?.stopRecording() }
            }
            try repository.save(session!)
        } catch { self.error = error.localizedDescription; session = nil; return }
        lastRecordingSampleTime = -.infinity
        recordingAccumulator = MeasurementAccumulator()
        recordingOrigin = nil; lastStrokeID = nil; recordingStarted = Date(); isRecording = true
        camera.pipeline.record(url: repository.directory.appendingPathComponent(filename), rotation: newSession.settings.rotation) { [weak self] url, failure in
            Task { @MainActor in await self?.recordingCompleted(url: url, failure: failure) }
        }
    }
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; isFinishing = true
        camera.pipeline.finishRecording()
    }
    private func recordingCompleted(url: URL?, failure: String?) async {
        isRecording = false; isFinishing = true; recordingStarted = nil
        defer { isFinishing = false; recorder = nil; terminationCompletion?(); terminationCompletion = nil }
        guard var saved = session else { return }
        saved.adjustments = adjustments; saved.observations = observations
        saved.aggregateStatistics = recordingAccumulator.statistics
        if let url, let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite {
            saved.duration = duration.seconds
        }
        do {
            if let recorder { let (samples, strokes) = try await recorder.finish(); saved.samples = samples; saved.strokes = strokes }
        } catch { self.error = "Measurement journal could not be finalized: \(error.localizedDescription)" }
        if url == nil { saved.videoFilename = nil }
        do { try repository.save(saved); if let recorder { try? FileManager.default.removeItem(at: recorder.url) }; session = nil } catch { self.error = "Session could not be saved: \(error.localizedDescription)" }
        if let failure { error = failure }
    }
    func saveMeasurements() {
        guard !engine.history.isEmpty, !busy else { return }
        var saved = makeSession(name: sessionName)
        let start = engine.history.first?.time ?? 0
        saved.samples = engine.history.map { sample in var value = sample; value.time -= start; return value }
        saved.duration = (engine.history.last?.time ?? start) - start
        saved.strokes = engine.cycles.strokes.filter { $0.start >= start }.map { var value = $0; value.start -= start; value.end -= start; return value }
        saved.adjustments = adjustments; saved.observations = observations
        do { try repository.save(saved) } catch { self.error = error.localizedDescription }
    }
    func captureMeasurement() { captureSamples = []; captureStarted = nil; captureProgress = 0 }
    func cancelMeasurement() { captureProgress = nil; captureStarted = nil; captureSamples = [] }
    private func finishMeasurement() {
        let values = Dictionary(uniqueKeysWithValues: MetricKind.allCases.compactMap { kind -> (MetricKind, Double)? in
            let data = captureSamples.compactMap { $0.values[kind] }
            guard data.count >= 20 else { return nil }
            return (kind, data.reduce(0,+) / Double(data.count))
        })
        if let id = pendingAdjustmentID, let index = adjustments.firstIndex(where: { $0.id == id }) {
            adjustments[index].after = values; pendingAdjustmentID = nil
        }
        lastCapture = values; cancelMeasurement()
    }
    func confirmAdjustment(amount: Double, notes: String) {
        guard !lastCapture.isEmpty, pendingAdjustmentID == nil, amount.isFinite else { return }
        let adjustment = Adjustment(step: fitStep, amount: amount, unit: fitStep.unit, notes: notes, before: lastCapture)
        adjustments.append(adjustment); pendingAdjustmentID = adjustment.id
        engine.reset()
        captureMeasurement()
    }
    func importVideo() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        panel.message = "Import a local video for on-device pose analysis. A copy is stored with the session."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let accessible = source.startAccessingSecurityScopedResource()
        var template = makeSession(name: source.deletingPathExtension().lastPathComponent)
        template.imported = true
        stopLiveCapture()
        videoTrimRequest = VideoTrimRequest(source: source, template: template, securityScoped: accessible)
    }
    func prepareVideoTrim(_ session: FitSession) {
        guard !busy, let source = repository.videoURL(session) else { return }
        var template = session
        template.id = UUID(); template.created = Date(); template.name += " (trimmed)"; template.isBaseline = false
        template.samples = []; template.strokes = []; template.aggregateStatistics = nil; template.videoFilename = nil
        videoTrimRequest = VideoTrimRequest(source: source, template: template)
    }
    func cancelVideoTrim() {
        if let request = videoTrimRequest, request.securityScoped { request.source.stopAccessingSecurityScopedResource() }
        videoTrimRequest = nil
    }
    func analyzeTrimmedVideo(_ request: VideoTrimRequest, range: VideoTimeRange) {
        guard videoTrimRequest?.id == request.id, !isRecording, !isFinishing, importProgress == nil else { return }
        let destination = repository.directory.appendingPathComponent("video-\(request.template.id).mov")
        videoTrimRequest = nil
        importProgress = 0
        videoProcessingID = request.id
        videoProcessingStage = "Trimming video…"
        stopLiveCapture()
        let progressHandler: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.videoProcessingID == request.id else { return }
                self.importProgress = value
            }
        }
        importTask = Task {
            defer { if request.securityScoped { request.source.stopAccessingSecurityScopedResource() }; videoProcessingID = nil; importProgress = nil; importTask = nil; terminationCompletion?(); terminationCompletion = nil }
            do {
                try await offline.trim(source: request.source, destination: destination, range: range)
                try Task.checkCancellation()
                videoProcessingStage = "Analyzing trimmed video locally…"
                let (samples, strokes, duration, statistics) = try await offline.analyze(url: destination, settings: request.template.settings, progress: progressHandler)
                try Task.checkCancellation()
                var saved = request.template
                saved.applySourceRange(range)
                saved.videoFilename = destination.lastPathComponent
                saved.samples = samples; saved.strokes = strokes; saved.duration = duration
                saved.aggregateStatistics = statistics
                try repository.save(saved)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if !(error is CancellationError), !Task.isCancelled { self.error = "Video processing failed: \(error.localizedDescription)" }
            }
        }
    }
    func cancelImport() { videoProcessingID = nil; importTask?.cancel(); Task { await offline.cancel() } }
    func stopLiveCapture() {
        if isRecording { stopRecording() }
        cancelMeasurement()
        camera.stop()
        pose = nil; sample = nil; trails.removeAll()
        trackingMessage = camera.state.title
    }
    /// Explicit owner shutdown also releases timers and stream consumers in embedded/test instances.
    func shutdown() {
        healthTimer?.invalidate(); healthTimer = nil
        poseTask?.cancel(); poseTask = nil
        cancelVideoTrim()
        stopLiveCapture()
        camera.removeObservers()
    }
    func prepareToTerminate(completion: @escaping () -> Void) {
        terminationCompletion = completion
        cancelVideoTrim()
        cancelMeasurement()
        if isRecording { stopRecording() }
        else if importProgress != nil { cancelImport() }
        else if !isFinishing { terminationCompletion?(); terminationCompletion = nil }
    }
    func export(_ session: FitSession, format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GravelFit-\(session.created.formatted(.iso8601.year().month().day())) .\(format)".replacingOccurrences(of: " .", with: ".")
        panel.allowedContentTypes = [format == "json" ? .json : format == "csv" ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == "json" ? try repository.json(session) : Data((format == "csv" ? repository.csv(session) : repository.summary(session)).utf8)
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
