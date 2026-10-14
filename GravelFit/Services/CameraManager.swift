@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let continuity: Bool
}

enum CameraState: Equatable {
    case idle, requestingPermission, denied, connecting, connected, disconnected, failed(String)
    var title: String {
        switch self {
        case .idle: "Camera stopped"
        case .requestingPermission: "Requesting camera access"
        case .denied: "Camera permission denied"
        case .connecting: "Connecting camera…"
        case .connected: "Camera connected"
        case .disconnected: "Camera disconnected · waiting to reconnect"
        case .failed(let reason): reason
        }
    }
}

/// The capture session and all of its mutations live on one dedicated serial queue.
final class CapturePipeline: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "GravelFit.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var poseService: PoseDetectionService?
    private var recordingCompletion: (@Sendable (URL?, String?) -> Void)?
    func configure(id: String, rotation: Double, poseService: PoseDetectionService, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            var configured = false
            do {
                if movieOutput.isRecording { throw NSError(domain: "GravelFit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish recording before changing cameras."]) }
                let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
                guard let device = discovery.devices.first(where: { $0.uniqueID == id }) else { throw NSError(domain: "GravelFit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected camera is unavailable."]) }
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.inputs.forEach { session.removeInput($0) }
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
                session.addInput(input)
                // Test the preset with the selected input installed, including lower-resolution webcams.
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                if !session.outputs.contains(videoOutput) {
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    guard session.canAddOutput(videoOutput) else { throw CocoaError(.featureUnsupported) }
                    session.addOutput(videoOutput)
                }
                if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
                self.poseService = poseService
                videoOutput.setSampleBufferDelegate(poseService, queue: poseService.queue)
                try device.lockForConfiguration()
                let ranges = device.activeFormat.videoSupportedFrameRateRanges
                if let range = ranges.first(where: { $0.maxFrameRate >= 30 && $0.minFrameRate <= 60 }) {
                    let fps = min(60, range.maxFrameRate)
                    device.activeVideoMinFrameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600000)
                    device.activeVideoMaxFrameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600000)
                }
                device.unlockForConfiguration()
                try applyRotation(rotation)
                configured = true
                completion(nil)
            } catch { completion(error.localizedDescription) }
            if configured, !session.inputs.isEmpty, !session.isRunning { session.startRunning() }
        }
    }
    private func applyRotation(_ rotation: Double) throws {
        let connections = [videoOutput as AVCaptureOutput, movieOutput as AVCaptureOutput].compactMap { $0.connection(with: .video) }
        guard connections.allSatisfy({ $0.isVideoRotationAngleSupported(rotation) }) else {
            throw NSError(domain: "GravelFit", code: 3, userInfo: [NSLocalizedDescriptionKey: "This camera cannot use the selected video orientation. Choose a supported orientation or another camera."])
        }
        for connection in connections {
            connection.videoRotationAngle = rotation
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
    }
    func setRotation(_ rotation: Double) { queue.async { try? self.applyRotation(rotation) } }
    func stop() { queue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() }; self.session.stopRunning() } }
    func record(url: URL, rotation: Double, completion: @escaping @Sendable (URL?, String?) -> Void) {
        queue.async {
            guard self.session.isRunning, self.movieOutput.connection(with: .video) != nil else { completion(nil, "Camera recording is unavailable."); return }
            do { try self.applyRotation(rotation) }
            catch { completion(nil, error.localizedDescription); return }
            self.recordingCompletion = completion
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }
    func finishRecording() { queue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } } }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let succeeded = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        queue.async {
            self.recordingCompletion?(succeeded ? outputFileURL : nil, succeeded ? nil : error?.localizedDescription)
            self.recordingCompletion = nil
        }
    }
}

@MainActor @Observable final class CameraManager {
    var devices: [CameraDevice] = []
    var selectedID = ""
    var state: CameraState = .idle
    let pipeline = CapturePipeline()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private let requestPermission: @Sendable () async -> Bool
    @ObservationIgnored var service: PoseDetectionService?
    @ObservationIgnored var prepareConnection: (@MainActor () -> Void)?
    var rotation = 0.0
    init(requestPermission: @escaping @Sendable () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }) {
        self.requestPermission = requestPermission
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification, AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let notificationName = note.name
                Task { @MainActor [weak self] in self?.handle(notificationName) }
            })
        }
    }
    func refresh() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        devices = discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, continuity: $0.deviceType == .continuityCamera) }
        if selectedID.isEmpty { selectedID = devices.first?.id ?? "" }
    }
    private func handle(_ name: Notification.Name) {
        refresh()
        guard wantsConnection else { return }
        if name == AVCaptureDevice.wasDisconnectedNotification, !devices.contains(where: { $0.id == selectedID }), state == .connected {
            pipeline.stop(); state = .disconnected
        } else if name == AVCaptureSession.wasInterruptedNotification {
            state = .disconnected
        } else if name == AVCaptureSession.runtimeErrorNotification {
            state = .failed("Camera interrupted. Reconnect the camera to resume.")
        } else if (state == .disconnected || name == AVCaptureSession.interruptionEndedNotification), devices.contains(where: { $0.id == selectedID }) {
            let id = connectionID
            Task { [weak self] in
                guard let self, self.wantsConnection, self.connectionID == id else { return }
                await self.connect()
            }
        }
    }
    func connect() async {
        wantsConnection = true
        let id = UUID()
        connectionID = id
        state = .requestingPermission
        let granted = await requestPermission()
        guard wantsConnection, connectionID == id else { return }
        guard granted else { state = .denied; return }
        refresh()
        guard !selectedID.isEmpty, let service else { state = .failed("No camera available. Connect an iPhone or webcam."); return }
        prepareConnection?()
        state = .connecting
        pipeline.configure(id: selectedID, rotation: rotation, poseService: service) { [weak self] error in
            Task { @MainActor in
                guard let self, self.wantsConnection, self.connectionID == id else { return }
                self.state = error.map { .failed($0) } ?? .connected
            }
        }
    }
    func stop() {
        wantsConnection = false
        connectionID = UUID()
        pipeline.stop()
        state = .idle
    }
    func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
}

final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        previewLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); previewLayer.frame = bounds; CATransaction.commit() }
}

struct CameraPreview: NSViewRepresentable {
    let pipeline: CapturePipeline
    var mirror: Bool
    var rotation: Double
    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView(frame: .zero)
        view.previewLayer.session = pipeline.session
        return view
    }
    func updateNSView(_ view: PreviewNSView, context: Context) {
        if let connection = view.previewLayer.connection {
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirror }
            if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        }
    }
}
