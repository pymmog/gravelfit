import XCTest
import SwiftUI
import AppKit

/// Renders production SwiftUI views in native windows; never opens or records a camera.
final class InterfaceTests: XCTestCase {
    @MainActor func testDecodedFrameCanBeMarkedWhenPoseAnalysisFails() async throws {
        let frame = try decodedFrame(time: 0.433)
        let inspector = VideoInspector(decode: { _, _ in frame }, analyze: { _ in throw CocoaError(.featureUnsupported) })
        defer { inspector.close() }
        inspector.open(url: fixtureURL, settings: FitSettings(), duration: 1)
        inspector.inspect(at: 0.45)
        try await waitForInspection(inspector)
        XCTAssertNotNil(inspector.image)
        XCTAssertNil(inspector.pose)
        XCTAssertNotNil(inspector.error)
        let annotation = try XCTUnwrap(inspector.annotation(.bottomDeadCenter))
        XCTAssertEqual(annotation.time, 0.433, accuracy: 0.0001)
        XCTAssertEqual(annotation.position, .bottomDeadCenter)
        XCTAssertNil(annotation.kneeFlexion)
        XCTAssertNil(annotation.hipAngle)
        XCTAssertEqual(annotation.confidence, 0)
        inspector.beginScrubbing()
        XCTAssertNil(inspector.annotation(.topDeadCenter))
    }

    @MainActor func testFrameInspectionTimeoutClearsLoadingAndAllowsManualMarking() async throws {
        let frame = try decodedFrame(time: 0.5)
        let inspector = VideoInspector(decode: { _, _ in frame }, analyze: { _ in
            try await Task.sleep(for: .seconds(60))
            return PoseFrame(timestamp: 0.5, width: 32, height: 32, joints: [:], peopleCount: 0)
        }, timeout: .milliseconds(30))
        defer { inspector.close() }
        inspector.open(url: fixtureURL, settings: FitSettings(), duration: 1)
        inspector.inspect(at: 0.5)
        try await waitForInspection(inspector)
        XCTAssertTrue(inspector.error?.contains("timed out") == true)
        XCTAssertNotNil(inspector.annotation(.topDeadCenter))
        XCTAssertNil(inspector.pose)
    }

    @MainActor func testDecodeTimeoutAndCloseDoNotLeaveInspectionLoading() async throws {
        let frame = try decodedFrame(time: 0.5)
        let inspector = VideoInspector(decode: { _, _ in try await Task.sleep(for: .seconds(60)); return frame }, timeout: .milliseconds(30))
        defer { inspector.close() }
        inspector.open(url: fixtureURL, settings: FitSettings(), duration: 1)
        inspector.inspect(at: 0.5)
        try await waitForInspection(inspector)
        XCTAssertNil(inspector.image)
        XCTAssertTrue(inspector.error?.contains("timed out") == true)
        XCTAssertNil(inspector.annotation(.bottomDeadCenter))
        inspector.inspect(at: 0.7)
        inspector.close()
        XCTAssertFalse(inspector.loading)
        XCTAssertFalse(inspector.analyzing)
        XCTAssertNil(inspector.error)
    }

    @MainActor func testSupersededFrameCannotReplaceCurrentFrame() async throws {
        let first = try decodedFrame(time: 0.2)
        let second = try decodedFrame(time: 0.8)
        let gate = PendingDecodedFrame()
        let inspector = VideoInspector(decode: { _, time in time < 0.5 ? await gate.request() : second }, analyze: { frame in
            PoseFrame(timestamp: frame.time, width: 32, height: 32, joints: [:], peopleCount: 0)
        })
        defer { inspector.close() }
        inspector.open(url: fixtureURL, settings: FitSettings(), duration: 1)
        inspector.inspect(at: 0.2)
        await gate.waitForRequest()
        inspector.inspect(at: 0.8)
        try await waitForInspection(inspector)
        await gate.resolve(first)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(inspector.inspectedTime, 0.8)
        XCTAssertEqual(inspector.annotation(.topDeadCenter)?.time, 0.8)
        XCTAssertFalse(inspector.loading)
    }

    @MainActor func testIPhoneCaptureAndSessionSettingsUsePortraitOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveFitViewModel(repository: SessionRepository(directory: directory))
        defer { model.shutdown() }
        model.camera.devices = [CameraDevice(id: "phone", name: "iPhone", continuity: true), CameraDevice(id: "webcam", name: "Webcam", continuity: false)]
        model.camera.selectedID = "phone"
        model.settings.rotation = 0
        model.settings.calibrated = true
        model.updateSettings()
        XCTAssertEqual(model.videoRotation, 90)
        XCTAssertEqual(model.camera.rotation, 90)
        XCTAssertFalse(model.settings.calibrated)
        XCTAssertEqual(model.settings.rotation, 0)
        let session = model.makeSession(name: "Portrait recording")
        XCTAssertEqual(session.settings.rotation, 90)
        try model.repository.save(session)
        XCTAssertEqual(SessionRepository(directory: directory).sessions.first?.settings.rotation, 90)
        model.camera.selectedID = "webcam"
        model.updateSettings()
        XCTAssertEqual(model.videoRotation, 0)
        XCTAssertEqual(model.camera.rotation, 0)
        model.settings.rotation = 180
        model.updateSettings()
        XCTAssertEqual(model.videoRotation, 180)
        model.camera.selectedID = "phone"
        model.updateSettings()
        XCTAssertEqual(model.videoRotation, 90)
        model.settings.rotation = 270
        model.updateSettings()
        XCTAssertEqual(model.camera.rotation, 270)
        XCTAssertEqual(model.makeSession(name: "Inverted portrait").settings.rotation, 270)
    }

    private var fixtureURL: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank.mov") }
    private func decodedFrame(time: Double) throws -> DecodedVideoFrame {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return DecodedVideoFrame(image: try XCTUnwrap(context.makeImage()), time: time)
    }
    @MainActor private func waitForInspection(_ inspector: VideoInspector) async throws {
        let deadline = Date().addingTimeInterval(2)
        while (inspector.loading || inspector.analyzing) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(inspector.loading)
        XCTAssertFalse(inspector.analyzing)
    }
    @MainActor func testLeavingLiveCaptureStopsCameraAndClearsCurrentMeasurements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveFitViewModel(repository: SessionRepository(directory: directory))
        defer { model.shutdown() }
        model.camera.state = .connected
        let pose = PoseFrame(timestamp: 1, width: 1920, height: 1080, joints: [:], peopleCount: 1)
        model.pose = pose
        model.sample = MetricSample(time: 1, values: [.kneeFlexion: 35], confidence: 0.9)
        model.trails = [pose]
        model.captureMeasurement()
        let adjustment = Adjustment(step: .saddleHeight, amount: 2, unit: "mm", notes: "Remeasure on return", before: [.kneeFlexion: 35])
        model.adjustments = [adjustment]
        model.pendingAdjustmentID = adjustment.id

        model.stopLiveCapture()

        XCTAssertEqual(model.camera.state, .idle)
        XCTAssertNil(model.pose)
        XCTAssertNil(model.sample)
        XCTAssertTrue(model.trails.isEmpty)
        XCTAssertNil(model.captureProgress)
        XCTAssertNil(model.currentStatistics[.kneeFlexion]?.current)
        XCTAssertEqual(model.trackingMessage, "Camera stopped")
        XCTAssertEqual(model.pendingAdjustmentID, adjustment.id)
        XCTAssertEqual(model.adjustments.count, 1)
    }

    @MainActor func testLeavingDuringRecordingRequestsFinalizationBeforeStoppingCapture() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveFitViewModel(repository: SessionRepository(directory: directory))
        defer { model.shutdown() }
        model.camera.state = .connected
        model.isRecording = true

        model.stopLiveCapture()

        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.isFinishing)
        XCTAssertEqual(model.camera.state, .idle)
        model.stopLiveCapture()
        XCTAssertTrue(model.isFinishing)
        XCTAssertEqual(model.camera.state, .idle)
    }

    @MainActor func testStoppingCameraWhilePermissionIsPendingKeepsItStopped() async {
        let permission = PendingCameraPermission()
        let camera = CameraManager(requestPermission: { await permission.request() })
        defer { camera.stop(); camera.removeObservers() }
        let connection = Task { await camera.connect() }
        await permission.waitForRequest()
        XCTAssertEqual(camera.state, .requestingPermission)

        camera.stop()
        await permission.resolve(true)
        await connection.value

        XCTAssertEqual(camera.state, .idle)
        XCTAssertFalse(camera.pipeline.session.isRunning)
    }

    @MainActor func testNativeWorkspacesRenderInLightAndDarkAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        let emptyModel = LiveFitViewModel(repository: SessionRepository(directory: directory.appendingPathComponent("empty")))
        defer { emptyModel.shutdown() }
        try repository.saveBike(BikeProfile(name: "Measured bike"))
        let phoneModel = LiveFitViewModel(repository: SessionRepository(directory: directory.appendingPathComponent("iphone")))
        defer { phoneModel.shutdown() }
        phoneModel.camera.devices = [CameraDevice(id: "phone", name: "Test iPhone", continuity: true)]
        phoneModel.camera.selectedID = "phone"
        phoneModel.updateSettings()
        let trimRequest = VideoTrimRequest(source: fixtureURL, template: model.makeSession(name: "Trimmed video"))
        let previousOnboarding = UserDefaults.standard.object(forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        defer {
            if let previousOnboarding { UserDefaults.standard.set(previousOnboarding, forKey: "hasSeenOnboarding") }
            else { UserDefaults.standard.removeObject(forKey: "hasSeenOnboarding") }
        }
        var before = FitSession(name: "Test baseline", bikeID: nil, settings: FitSettings())
        before.isBaseline = true
        before.duration = 10
        before.samples = (0..<20).map { MetricSample(time: Double($0) * 0.5, values: [.kneeFlexion: 35 + Double($0 % 4), .torsoAngle: 45], confidence: 0.9) }
        var after = before
        after.id = UUID(); after.name = "Test after"; after.isBaseline = false
        after.samples = before.samples.map { var result = $0; result.id = UUID(); result.values[.kneeFlexion] = (result.values[.kneeFlexion] ?? 0) + 2; return result }
        try repository.save(before); try repository.save(after)
        let frame = try decodedFrame(time: 0.5)
        let frameInspector = VideoInspector(decode: { _, _ in frame }, analyze: { _ in throw CocoaError(.featureUnsupported) })
        defer { frameInspector.close() }
        frameInspector.open(url: fixtureURL, settings: FitSettings(), duration: 1)
        frameInspector.inspect(at: 0.5)
        try await waitForInspection(frameInspector)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/verification/interface")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let views: [(String, AnyView)] = [
                ("shell", AnyView(ContentView(model: model))),
                ("dashboard", AnyView(DashboardView(model: model, navigate: { _ in }))),
                ("live", AnyView(LiveFitView(model: model))),
                ("live-iphone", AnyView(LiveFitView(model: phoneModel))),
                ("sessions", AnyView(SessionsView(model: model))),
                ("comparison", AnyView(ComparisonView(model: model))),
                ("profiles", AnyView(BikeProfilesView(model: model))),
                ("profiles-empty", AnyView(BikeProfilesView(model: emptyModel))),
                ("settings", AnyView(SettingsView(model: model))),
                ("settings-iphone", AnyView(SettingsView(model: phoneModel))),
                ("video-trim", AnyView(VideoTrimView(request: trimRequest, cancel: {}, analyze: { _ in }))),
                ("frame-inspection", AnyView(SessionVideoView(inspector: frameInspector, session: before, annotate: { _ in }))),
                ("onboarding", AnyView(OnboardingView(finish: {}))),
                ("calibration", AnyView(CalibrationView(model: model)))
            ]
            for (name, view) in views {
                let size = NSSize(width: name == "calibration" ? 800 : (name == "onboarding" || name == "frame-inspection") ? 720 : 1320, height: 900)
                let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.title = "GravelFit interface validation"
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(120))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                window.appearance?.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                // View caches contain alpha; composite onto the actual native window background.
                let image = try XCTUnwrap(bitmap.cgImage)
                let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                window.appearance?.performAsCurrentDrawingAppearance {
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 5000, "\(name) should render meaningful native content")
                try png.write(to: output.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
                window.orderOut(nil); window.close()
            }
        }
        XCTAssertNil(model.error)
    }
}

private actor PendingDecodedFrame {
    private var result: CheckedContinuation<DecodedVideoFrame, Never>?
    private var requestStarted: CheckedContinuation<Void, Never>?
    func request() async -> DecodedVideoFrame {
        await withCheckedContinuation { result = $0; requestStarted?.resume(); requestStarted = nil }
    }
    func waitForRequest() async {
        if result != nil { return }
        await withCheckedContinuation { requestStarted = $0 }
    }
    func resolve(_ frame: DecodedVideoFrame) { result?.resume(returning: frame); result = nil }
}

private actor PendingCameraPermission {
    private var result: CheckedContinuation<Bool, Never>?
    private var requestStarted: CheckedContinuation<Void, Never>?
    func request() async -> Bool {
        await withCheckedContinuation {
            result = $0
            requestStarted?.resume()
            requestStarted = nil
        }
    }
    func waitForRequest() async {
        if result != nil { return }
        await withCheckedContinuation { requestStarted = $0 }
    }
    func resolve(_ granted: Bool) {
        result?.resume(returning: granted)
        result = nil
    }
}
