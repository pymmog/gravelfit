import XCTest
import Foundation

final class RepositoryTests: XCTestCase {
    @MainActor func testTrimPreparationAndManualAnnotationsPreserveOriginalSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        var session = model.makeSession(name: "Original recording")
        session.duration = 10
        session.videoFilename = "video-\(session.id).mov"
        session.isBaseline = true
        session.annotations = [FrameAnnotation(time: 3.433, position: .bottomDeadCenter, confidence: 0), FrameAnnotation(time: 7, position: .topDeadCenter, confidence: 0)]
        try repository.save(session)
        model.prepareVideoTrim(session)
        let request = try XCTUnwrap(model.videoTrimRequest)
        XCTAssertTrue(model.busy)
        XCTAssertNotEqual(request.template.id, session.id)
        XCTAssertFalse(request.template.isBaseline)
        XCTAssertEqual(request.template.annotations.first?.time, 3.433)
        XCTAssertEqual(repository.sessions.first?.id, session.id)
        XCTAssertEqual(repository.sessions.first?.videoFilename, session.videoFilename)
        var trimmed = request.template
        trimmed.applySourceRange(VideoTimeRange(start: 3, end: 5))
        try repository.save(trimmed)
        model.cancelVideoTrim()
        XCTAssertFalse(model.busy)
        let reloaded = SessionRepository(directory: directory)
        let original = try XCTUnwrap(reloaded.sessions.first(where: { $0.id == session.id }))
        let cut = try XCTUnwrap(reloaded.sessions.first(where: { $0.id == trimmed.id }))
        XCTAssertEqual(original.annotations.count, 2)
        XCTAssertEqual(original.annotations.first?.position, .bottomDeadCenter)
        XCTAssertEqual(original.annotations.first?.time, 3.433)
        XCTAssertNil(original.annotations.first?.kneeFlexion)
        XCTAssertNil(original.annotations.first?.hipAngle)
        XCTAssertTrue(original.isBaseline)
        XCTAssertEqual(cut.annotations.count, 1)
        XCTAssertEqual(try XCTUnwrap(cut.annotations.first?.time), 0.433, accuracy: 0.0001)
        XCTAssertEqual(cut.sourceRange, VideoTimeRange(start: 3, end: 5))
        XCTAssertTrue(reloaded.summary(cut).contains("3.000–5.000"))
    }

    @MainActor func testCameraOnlyFitSavesMeasurementsAndGuidedAdjustmentsWithoutBikeData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        XCTAssertTrue(repository.bikes.isEmpty)
        XCTAssertNil(model.activeBikeID)
        model.settings.calibrated = true
        model.sessionName = "Camera-only fit"
        let joints: [JointName: TrackedJoint] = [
            .leftShoulder: TrackedJoint(point: Point2D(x: 0.7, y: 0.8), confidence: 0.9),
            .leftElbow: TrackedJoint(point: Point2D(x: 0.8, y: 0.6), confidence: 0.9),
            .leftWrist: TrackedJoint(point: Point2D(x: 0.9, y: 0.5), confidence: 0.9),
            .leftHip: TrackedJoint(point: Point2D(x: 0.5, y: 0.5), confidence: 0.9),
            .leftKnee: TrackedJoint(point: Point2D(x: 0.6, y: 0.3), confidence: 0.9),
            .leftAnkle: TrackedJoint(point: Point2D(x: 0.5, y: 0.1), confidence: 0.9)
        ]
        for i in 0..<45 {
            let frame = PoseFrame(timestamp: Double(i) / 10, width: 1920, height: 1080, joints: joints, peopleCount: 1)
            model.sample = model.engine.process(frame, settings: model.settings).1
        }
        model.saveMeasurements()
        let saved = try XCTUnwrap(repository.sessions.first)
        XCTAssertNil(saved.bikeID)
        XCTAssertNil(saved.bikeSnapshot)
        XCTAssertEqual(saved.samples.count, 45)
        XCTAssertNotNil(saved.samples.last?.values[.kneeFlexion])
        XCTAssertNotNil(saved.samples.last?.values[.hipAngle])
        XCTAssertNotNil(saved.samples.last?.values[.torsoAngle])
        XCTAssertNotNil(saved.samples.last?.values[.elbowAngle])
        let reloaded = SessionRepository(directory: directory)
        XCTAssertNil(reloaded.error)
        XCTAssertTrue(reloaded.bikes.isEmpty)
        XCTAssertNil(reloaded.sessions.first?.bikeID)
        XCTAssertNil(reloaded.sessions.first?.bikeSnapshot)
        let summary = repository.summary(saved)
        XCTAssertTrue(summary.contains("Bike: No bike profile"))
        XCTAssertFalse(summary.contains("Setup snapshot:"))
        XCTAssertTrue(repository.csv(saved).contains("kneeFlexion_degrees"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: repository.json(saved)) as? [String: Any])
        XCTAssertNil(json["bikeID"])
        XCTAssertNil(json["bikeSnapshot"])

        let guidance = BikeFitRecommendationEngine.guidance(step: .saddleTilt, engine: model.engine, settings: model.settings)
        XCTAssertTrue(guidance.contains("Change one variable at a time"))
        model.fitStep = .saddleTilt
        model.lastCapture = model.sample?.values ?? [:]
        model.confirmAdjustment(amount: -1, notes: "Comfort check")
        XCTAssertEqual(model.adjustments.count, 1)
        XCTAssertNotNil(model.pendingAdjustmentID)
        XCTAssertNotNil(model.captureProgress)
        XCTAssertNil(model.activeBikeID)
    }

    @MainActor func testOptionalProfileSelectionAndSharedSessionMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let bike = BikeProfile(name: "Measured bike", saddleHeight: 765)
        try repository.saveBike(bike)
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        // Existing profiles also require an explicit selection.
        XCTAssertNil(model.activeBikeID)
        let cameraOnly = model.makeSession(name: "Without setup")
        XCTAssertNil(cameraOnly.bikeID)
        XCTAssertNil(cameraOnly.bikeSnapshot)
        model.selectBike(bike.id)
        let measured = model.makeSession(name: "With setup")
        XCTAssertEqual(measured.bikeID, bike.id)
        XCTAssertEqual(measured.bikeSnapshot, bike)
        model.isRecording = true
        model.selectBike(nil)
        XCTAssertEqual(model.activeBikeID, bike.id)
        model.isRecording = false
        model.captureProgress = 0.5
        model.selectBike(nil)
        XCTAssertEqual(model.activeBikeID, bike.id)
        model.cancelMeasurement()
        model.adjustments = [Adjustment(step: .saddleHeight, amount: 2, unit: "mm", notes: "", before: [:])]
        model.selectBike(nil)
        XCTAssertEqual(model.activeBikeID, bike.id)
        model.beginNewFit()
        model.selectBike(nil)
        XCTAssertNil(model.activeBikeID)
        XCTAssertNil(model.makeSession(name: "Without setup again").bikeSnapshot)
        XCTAssertEqual(measured.bikeSnapshot, bike)
        model.selectBike(UUID())
        XCTAssertNil(model.activeBikeID)
    }

    @MainActor func testLegacyBikeLinkedSessionStillLoadsAndExportsAsArchived() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let id = UUID()
        let legacy = FitSession(name: "Earlier fit", bikeID: id, settings: FitSettings())
        try repository.save(legacy)
        let reloaded = SessionRepository(directory: directory)
        XCTAssertNil(reloaded.error)
        XCTAssertEqual(reloaded.sessions.first?.bikeID, id)
        XCTAssertTrue(reloaded.summary(try XCTUnwrap(reloaded.sessions.first)).contains("Bike: Archived bike"))
    }

    @MainActor func testBikeEditsAndDeletionPreserveSavedSessionsAndVideos() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        try repository.saveBike(BikeProfile())
        let original = repository.bikes[0]
        var session = FitSession(name: "Original setup", bikeID: original.id, settings: FitSettings())
        session.bikeSnapshot = original
        session.videoFilename = "video-\(session.id).mov"
        let videoURL = try XCTUnwrap(repository.videoURL(session))
        let videoData = Data("saved video".utf8)
        try videoData.write(to: videoURL)
        try repository.save(session)

        var edited = original
        edited.name = "Road bike"
        edited.type = "Road"
        edited.saddleHeight = 755
        edited.saddleTilt = -1.5
        edited.cleatNotes = "Cleats moved back"
        edited.riderNotes = "Updated fit"
        try repository.saveBike(edited)
        let other = BikeProfile(name: "Second bike")
        try repository.saveBike(other)
        let reloaded = SessionRepository(directory: directory)
        XCTAssertEqual(reloaded.bikes, [edited, other])
        XCTAssertEqual(reloaded.sessions[0].bikeSnapshot, original)

        try reloaded.deleteBike(original.id)
        let afterDeletion = SessionRepository(directory: directory)
        XCTAssertEqual(afterDeletion.bikes, [other])
        XCTAssertEqual(afterDeletion.sessions.count, 1)
        XCTAssertEqual(afterDeletion.sessions[0].bikeID, original.id)
        XCTAssertEqual(afterDeletion.sessions[0].bikeSnapshot, original)
        XCTAssertEqual(try Data(contentsOf: videoURL), videoData)
        XCTAssertTrue(afterDeletion.summary(afterDeletion.sessions[0]).contains(original.name))
    }

    @MainActor func testDeletingActiveAndLastBikeAllowsFittingWithoutAProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        try repository.saveBike(BikeProfile())
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        model.selectBike(repository.bikes[0].id)
        let firstID = model.activeBikeID
        let other = BikeProfile(name: "Second bike")
        try repository.saveBike(other)

        // Removing an inactive profile does not switch the bike being fitted.
        XCTAssertTrue(model.deleteBike(other.id))
        XCTAssertEqual(model.activeBikeID, firstID)
        try repository.saveBike(other)
        model.lastCapture = [.kneeFlexion: 35]
        XCTAssertTrue(model.deleteBike(try XCTUnwrap(firstID)))
        XCTAssertNil(model.activeBikeID)
        XCTAssertEqual(repository.bikes, [other])
        XCTAssertTrue(model.lastCapture.isEmpty)
        model.selectBike(other.id)
        XCTAssertTrue(model.deleteBike(other.id))
        XCTAssertTrue(repository.bikes.isEmpty)
        XCTAssertNil(model.activeBikeID)
        XCTAssertEqual(SessionRepository(directory: directory).bikes, repository.bikes)
    }

    @MainActor func testBikeDeletionRespectsRecordingAndCurrentFit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        try repository.saveBike(BikeProfile())
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        let original = repository.bikes[0]
        model.selectBike(original.id)
        let other = BikeProfile(name: "Second bike")
        try repository.saveBike(other)
        model.isRecording = true
        XCTAssertFalse(model.deleteBike(original.id))
        XCTAssertFalse(model.deleteBike(other.id))
        model.isRecording = false
        model.adjustments = [Adjustment(step: .saddleHeight, amount: 2, unit: "mm", notes: "", before: [:])]
        XCTAssertFalse(model.deleteBike(original.id))
        XCTAssertTrue(model.deleteBike(other.id))
        model.beginNewFit()
        model.captureProgress = 0.5
        XCTAssertFalse(model.deleteBike(original.id))
        model.cancelMeasurement()
        XCTAssertTrue(model.deleteBike(original.id))
    }

    @MainActor func testFailedProfileWritesLeaveProfilesAndSelectionUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        try repository.saveBike(BikeProfile())
        let model = LiveFitViewModel(repository: repository)
        defer { model.shutdown() }
        let original = repository.bikes[0]
        model.selectBike(original.id)
        // Replace the storage directory with a file so both atomic writes fail.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        var edited = original
        edited.name = "Unsaved name"
        XCTAssertThrowsError(try repository.saveBike(edited))
        XCTAssertFalse(model.deleteBike(original.id))
        XCTAssertEqual(repository.bikes, [original])
        XCTAssertEqual(model.activeBikeID, original.id)
        XCTAssertNotNil(model.error)
    }

    @MainActor func testSessionPersistenceExportsBaselineAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SessionRepository(directory: directory)
        try repo.saveBike(BikeProfile())
        try repo.saveConfiguration()
        var session = FitSession(name: "Fit A",bikeID: repo.bikes[0].id,settings: FitSettings())
        session.samples = [MetricSample(time: 0,values: [.kneeFlexion:35],confidence: 0.9), MetricSample(time: 1,values: [:],confidence: 0.1)]
        session.adjustments = [Adjustment(step: .saddleHeight,amount: -2,unit: "mm",notes: "Comfort check",before: [.kneeFlexion:27],after: [.kneeFlexion:32])]
        try repo.save(session)
        try repo.setBaseline(session.id)
        let reloaded = SessionRepository(directory: directory)
        XCTAssertEqual(reloaded.sessions.count,1)
        XCTAssertTrue(reloaded.sessions[0].isBaseline)
        XCTAssertEqual(reloaded.sessions[0].samples.first?.values[.kneeFlexion],35)
        XCTAssertTrue(repo.csv(session).contains("kneeFlexion_degrees"))
        XCTAssertTrue(repo.csv(session).contains("35.000"))
        XCTAssertTrue(repo.summary(session).contains("Δ +5.0"))
        XCTAssertTrue(repo.summary(session).contains("Uncertainty notes"))
        XCTAssertFalse(try repo.json(session).isEmpty)
        try reloaded.delete(session)
        XCTAssertTrue(reloaded.sessions.isEmpty)
        try reloaded.deleteAll()
        XCTAssertTrue(reloaded.bikes.isEmpty)
    }
    @MainActor func testVideoPathCannotEscapeStorageDirectory() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SessionRepository(directory: directory)
        var session = FitSession(name: "Malformed",bikeID: UUID(),settings: FitSettings())
        session.videoFilename = "../../outside.mov"
        XCTAssertNil(repo.videoURL(session))
    }
    @MainActor func testInterruptedRecordingJournalIsRecoveredOnStartup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        let session = FitSession(name: "Interrupted",bikeID: nil,settings: FitSettings())
        try repository.save(session)
        let recorder = try SessionRecorder(directory: directory,id: session.id,onFailure: { _ in })
        recorder.append(sample: MetricSample(time: 1,values: [.kneeFlexion:36],confidence: 0.9))
        _ = try await recorder.finish()
        let recovered = SessionRepository(directory: directory)
        XCTAssertEqual(recovered.sessions[0].samples.count,1)
        XCTAssertNil(recovered.sessions[0].bikeID)
        XCTAssertNil(recovered.sessions[0].bikeSnapshot)
        XCTAssertTrue(recovered.sessions[0].observations.contains("Recovered"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }
}
