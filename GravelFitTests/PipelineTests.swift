import XCTest
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO

final class PipelineTests: XCTestCase {
    func testTrimWritesSelectedRangeWithoutChangingOriginal() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank-h264.mov")
        let original = try Data(contentsOf: source)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await OfflineAnalyzer().trim(source: source, destination: destination, range: VideoTimeRange(start: 0.2, end: 0.8))
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.6, accuracy: 1 / 30)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let timeRange = try await track.load(.timeRange)
        XCTAssertEqual(timeRange.start.seconds, 0, accuracy: 1 / 30)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTrimRejectsInvalidRangesBeforeWritingVideo() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank.mov")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        for range in [VideoTimeRange(start: 0.7, end: 0.2), VideoTimeRange(start: -1, end: 0.5), VideoTimeRange(start: 0, end: 2)] {
            do {
                try await OfflineAnalyzer().trim(source: source, destination: destination, range: range)
                XCTFail("Invalid ranges must be rejected")
            } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        }
        XCTAssertFalse(VideoTimeRange(start: .nan, end: 1).isValid(for: 1))
        XCTAssertFalse(VideoTimeRange(start: 0, end: .infinity).isValid(for: 1))
        XCTAssertFalse(VideoTimeRange(start: 0, end: 0).isValid(for: 1))
    }

    func testTrimPreservesPortraitTrackOrientation() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank-h264-portrait.mov")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await OfflineAnalyzer().trim(source: source, destination: destination, range: VideoTimeRange(start: 0.2, end: 0.8))
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = CGRect(origin: .zero, size: size).applying(transform).size
        XCTAssertEqual(abs(displaySize.width), 240, accuracy: 0.001)
        XCTAssertEqual(abs(displaySize.height), 320, accuracy: 0.001)
    }

    func testMeasurementJournalPreservesAllRecordsAndIncompleteTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try SessionRecorder(directory: directory,id: UUID(),onFailure: { _ in })
        for i in 0..<100 {
            recorder.append(sample: MetricSample(time: Double(i) * 0.5,values: [.kneeFlexion:Double(i)],confidence: 0.9))
            // Simulate the 2 Hz producer without filling the bounded 32-write queue.
            if i % 10 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        recorder.append(stroke: PedalStroke(start: 0,end: 1,minimumKneeFlexion: 35,maximumKneeFlexion: 95,confidence: 0.9))
        let (samples,strokes) = try await recorder.finish()
        XCTAssertEqual(samples.count,100)
        XCTAssertEqual(samples.last?.time,49.5)
        XCTAssertEqual(strokes.count,1)
        let handle = try FileHandle(forWritingTo: recorder.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{incomplete".utf8)); try handle.close()
        let recovered = try SessionRecorder.read(url: recorder.url)
        XCTAssertEqual(recovered.0.count,100)
    }

    func testLocalVideoImportAnalysisAndExactFrameInspection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank.mov")
        try FileManager.default.copyItem(at: fixture, to: url)
        let analyzer = OfflineAnalyzer()
        let result: ([MetricSample], [PedalStroke], Double, [MetricKind: MetricStatistics])
        do {
            result = try await analyzer.analyze(url: url,settings: FitSettings(),progress: { _ in })
        } catch {
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            if ns.domain == AVFoundationErrorDomain, underlying?.domain == NSOSStatusErrorDomain, underlying?.code == -6662 {
                throw XCTSkip("This runner denies IOSurface/CoreVideo access (-6662); run the video/Vision integration test locally in Xcode.")
            }
            throw error
        }
        let (samples,strokes,duration,statistics) = result
        XCTAssertGreaterThan(duration,0.8)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(strokes.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.values[.kneeFlexion] == nil })
        XCTAssertNil(statistics[.kneeFlexion]?.minimum)
        let (image,pose) = try await analyzer.frame(url: url,time: 0.5)
        XCTAssertEqual(image.width,320)
        XCTAssertEqual(image.height,240)
        XCTAssertEqual(pose.timestamp,0.5,accuracy: 1.0 / 30)
        XCTAssertEqual(pose.peopleCount,0)
        XCTAssertTrue(pose.joints.isEmpty)
    }

    func testUnsupportedVideoThrowsWithoutFabricatingMeasurements() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not a movie".utf8).write(to: url)
        do {
            _ = try await OfflineAnalyzer().analyze(url: url,settings: FitSettings(),progress: { _ in })
            XCTFail("Invalid video must be rejected")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testVideoFixtureMetadataIsReadableWithoutHardwareDecoding() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blank.mov")
        let asset = AVURLAsset(url: fixture)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds,1,accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width,320)
        XCTAssertEqual(size.height,240)
    }

    func testVisionDetectsPartialCyclistWithoutInventingLegMeasurements() throws {
        let image = try photograph("partial-cyclist")
        let pose = try PoseDetectionService.detect(image: image, time: 0)
        XCTAssertEqual(pose.peopleCount, 1)
        XCTAssertNotNil(pose.joints[.leftElbow])
        XCTAssertNil(pose.pixelPoint(.leftAnkle, threshold: 0.6))
        let metrics = BiomechanicsEngine.measure(pose, settings: FitSettings())
        XCTAssertNil(metrics[.kneeFlexion])
        XCTAssertNil(metrics[.hipAngle])
    }

    func testVisionRejectsAmbiguousMultipleCyclists() throws {
        let pose = try PoseDetectionService.detect(image: photograph("multiple-cyclists"), time: 0)
        XCTAssertGreaterThan(pose.peopleCount, 1)
        XCTAssertTrue(pose.joints.isEmpty)
        XCTAssertNil(BiomechanicsEngine.measure(pose, settings: FitSettings())[.elbowAngle])
    }

    private func photograph(_ name: String) throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

}
