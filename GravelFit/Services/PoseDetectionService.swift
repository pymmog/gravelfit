@preconcurrency import AVFoundation
import Vision
import CoreGraphics
import Foundation

/// AVCapture drops late frames; this serial delegate never enqueues a second Vision request.
final class PoseDetectionService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "GravelFit.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var targetFPS = 15.0
    private var lastTime = -Double.infinity
    private var adaptiveInterval = 1.0 / 15
    private var lastErrorTime = -Double.infinity
    private let onPose: @Sendable (PoseFrame) -> Void
    private let onError: @Sendable (String) -> Void

    init(onPose: @escaping @Sendable (PoseFrame) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onPose = onPose; self.onError = onError
    }
    func setFPS(_ fps: Double) { lock.withLock { targetFPS = max(5, min(30, fps)) } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let interval = lock.withLock { max(1 / targetFPS, adaptiveInterval) }
        guard time - lastTime >= interval || time < lastTime else { return }
        lastTime = time
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let pose = try Self.detect(buffer: buffer, time: time)
            adaptiveInterval = max(1 / lock.withLock { targetFPS }, pose.processingMilliseconds / 1000 * 1.15)
            if CFAbsoluteTimeGetCurrent() - start < 2 { onPose(pose) }
        } catch {
            if time - lastErrorTime > 1 { lastErrorTime = time; onError("Body tracking paused: \(error.localizedDescription)") }
        }
    }
    static func detect(buffer: CVPixelBuffer, time: Double) throws -> PoseFrame {
        try detect(handler: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), time: time)
    }
    private static func detect(handler: VNImageRequestHandler, width: Int, height: Int, time: Double) throws -> PoseFrame {
        let start = CFAbsoluteTimeGetCurrent()
        let request = VNDetectHumanBodyPoseRequest()
        try handler.perform([request])
        let observations = request.results ?? []
        let names: [(JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]
        var joints: [JointName: TrackedJoint] = [:]
        // Multiple people deliberately invalidate the pose instead of silently switching riders.
        if observations.count == 1, let observation = observations.first {
            let points = try observation.recognizedPoints(.all)
            for (name, visionName) in names {
                if let p = points[visionName], p.confidence > 0 {
                    joints[name] = TrackedJoint(point: Point2D(x: p.location.x, y: p.location.y), confidence: Double(p.confidence))
                }
            }
        }
        return PoseFrame(timestamp: time, width: Double(width), height: Double(height), joints: joints, peopleCount: observations.count, processingMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    static func detect(image: CGImage, time: Double) throws -> PoseFrame {
        try detect(handler: VNImageRequestHandler(cgImage: image, orientation: .up), width: image.width, height: image.height, time: time)
    }
}

actor OfflineAnalyzer {
    private var cancelled = false
    func cancel() { cancelled = true }
    func analyze(url: URL, settings: FitSettings, progress: @escaping @Sendable (Double) -> Void) async throws -> ([MetricSample], [PedalStroke], Double, [MetricKind: MetricStatistics]) {
        cancelled = false
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        // Video composition applies the track's preferred transform, matching AVPlayer rendering.
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnsupportedScheme) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var engine = BikeFitAnalysisEngine()
        var accumulator = MeasurementAccumulator()
        var results: [MetricSample] = []
        var strokes: [PedalStroke] = []
        var lastStrokeID: UUID?
        var last = -Double.infinity
        var lastProgress = -1.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if cancelled { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time - last < 1 / settings.analysisFPS { continue }
            last = time
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let raw = try PoseDetectionService.detect(buffer: buffer, time: time)
            let (_, metric) = engine.process(raw, settings: settings)
            accumulator.append(metric)
            // A 2 Hz persisted timeline bounds storage while stroke detection uses full analysis cadence.
            if time - (results.last?.time ?? -.infinity) >= 0.5 { results.append(metric) }
            if let stroke = engine.cycles.strokes.last, stroke.id != lastStrokeID { strokes.append(stroke); lastStrokeID = stroke.id }
            if time / duration - lastProgress > 0.01 { lastProgress = time / duration; progress(min(1, lastProgress)) }
            await Task.yield()
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        progress(1)
        return (results, strokes, duration, accumulator.statistics)
    }
    func frame(url: URL, time: Double) async throws -> (CGImage, PoseFrame) {
        let decoded = try await decodeFrame(url: url, time: time)
        try Task.checkCancellation()
        return (decoded.image, try PoseDetectionService.detect(image: decoded.image, time: decoded.time))
    }
    func decodeFrame(url: URL, time: Double) async throws -> DecodedVideoFrame {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let rate = try await track?.load(.nominalFrameRate) ?? 30
        let tolerance = CMTime(seconds: 1 / Double(max(1, rate)), preferredTimescale: 60000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return try await withTaskCancellationHandler {
            let result = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 60000))
            try Task.checkCancellation()
            return DecodedVideoFrame(image: result.image, time: result.actualTime.seconds)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
    func trim(source: URL, destination: URL, range: VideoTimeRange) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard range.isValid(for: duration) else {
            throw NSError(domain: "GravelFit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Choose a start and end within the video, with the end after the start."])
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.featureUnsupported) }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60000), duration: CMTime(seconds: range.duration, preferredTimescale: 60000))
        try await exporter.export(to: destination, as: .mov, isolation: self)
    }
}

struct DecodedVideoFrame: Sendable {
    let image: CGImage
    let time: Double
}

actor FramePoseAnalyzer {
    func analyze(_ frame: DecodedVideoFrame) throws -> PoseFrame {
        try Task.checkCancellation()
        let pose = try PoseDetectionService.detect(image: frame.image, time: frame.time)
        try Task.checkCancellation()
        return pose
    }
}
