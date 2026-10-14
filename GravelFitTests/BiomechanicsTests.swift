import XCTest
import Foundation

final class BiomechanicsTests: XCTestCase {
    func testInteriorAnglesAndDegenerateVectors() {
        XCTAssertEqual(BiomechanicsEngine.interiorAngle(Point2D(x: 1,y: 0), Point2D(x: 0,y: 0), Point2D(x: 0,y: 1))!, 90, accuracy: 0.0001)
        XCTAssertEqual(BiomechanicsEngine.interiorAngle(Point2D(x: -1,y: 0), Point2D(x: 0,y: 0), Point2D(x: 1,y: 0))!, 180, accuracy: 0.0001)
        XCTAssertNil(BiomechanicsEngine.interiorAngle(Point2D(x: 0,y: 0), Point2D(x: 0,y: 0), Point2D(x: 1,y: 0)))
    }
    func testKneeFlexionConversion() {
        let hip = Point2D(x: 0, y: 1), knee = Point2D(x: 0, y: 0)
        let ankle = Point2D(x: 0.5, y: -sqrt(3) / 2)
        XCTAssertEqual(BiomechanicsEngine.kneeFlexion(hip: hip, knee: knee, ankle: ankle)!, 30, accuracy: 0.0001)
    }
    func testTorsoGroundAndFacingDirections() {
        let hip = Point2D(x: 0,y: 0)
        XCTAssertEqual(BiomechanicsEngine.torsoAngle(hip: hip, shoulder: Point2D(x: 1,y: 1), floorAngle: 0)!, 45, accuracy: 0.001)
        XCTAssertEqual(BiomechanicsEngine.torsoAngle(hip: hip, shoulder: Point2D(x: -1,y: 1), floorAngle: 0)!, 45, accuracy: 0.001)
        XCTAssertEqual(BiomechanicsEngine.torsoAngle(hip: hip, shoulder: Point2D(x: 1,y: 1), floorAngle: 5)!, 40, accuracy: 0.001)
        XCTAssertNil(BiomechanicsEngine.torsoAngle(hip: hip, shoulder: hip, floorAngle: 0))
    }
    func testAspectFitAndVisionCoordinates() {
        let point = VideoOverlayRenderer.map(Point2D(x: 0.25,y: 0.75), imageWidth: 1920, imageHeight: 1080, viewWidth: 1000, viewHeight: 1000, mirrored: false)
        XCTAssertEqual(point.x, 250, accuracy: 0.001)
        XCTAssertEqual(point.y, 359.375, accuracy: 0.001)
        let portrait = VideoOverlayRenderer.map(Point2D(x: 0,y: 1), imageWidth: 1080, imageHeight: 1920, viewWidth: 1000, viewHeight: 1000, mirrored: false)
        XCTAssertEqual(portrait.x, 218.75, accuracy: 0.001)
        XCTAssertEqual(portrait.y, 0, accuracy: 0.001)
    }
    func testMirroringPreservesYAndReflectsX() {
        let p = Point2D(x: 0.2,y: 0.3)
        let normal = VideoOverlayRenderer.map(p, imageWidth: 1920,imageHeight: 1080,viewWidth: 1200,viewHeight: 800,mirrored: false)
        let mirror = VideoOverlayRenderer.map(p, imageWidth: 1920,imageHeight: 1080,viewWidth: 1200,viewHeight: 800,mirrored: true)
        XCTAssertEqual(normal.x + mirror.x, 1200, accuracy: 0.001)
        XCTAssertEqual(normal.y, mirror.y)
    }
    private func frame(_ t: Double, _ x: Double, confidence: Double = 0.9) -> PoseFrame {
        PoseFrame(timestamp: t,width: 1920,height: 1080,joints: [.leftHip: TrackedJoint(point: Point2D(x: x,y: 0.5),confidence: confidence)],peopleCount: 1)
    }
    func testTemporalSmoothing() {
        var tracker = JointTrackingEngine()
        _ = tracker.filter(frame(0,0.2),alpha: 0.25,threshold: 0.6)
        let smoothed = tracker.filter(frame(0.1,0.6),alpha: 0.25,threshold: 0.6)
        XCTAssertEqual(smoothed.joints[.leftHip]!.point.x, 0.3, accuracy: 0.0001)
    }
    func testMissingJointGraceIsVisualOnlyAndExpires() {
        var tracker = JointTrackingEngine()
        _ = tracker.filter(frame(0,0.2),alpha: 0.4,threshold: 0.6)
        let held = tracker.filter(frame(0.1,0.8,confidence: 0.2),alpha: 0.4,threshold: 0.6)
        XCTAssertTrue(held.joints[.leftHip]!.isPredicted)
        XCTAssertNil(held.pixelPoint(.leftHip, threshold: 0.6))
        let expired = tracker.filter(frame(0.3,0.8,confidence: 0.2),alpha: 0.4,threshold: 0.6)
        XCTAssertNil(expired.joints[.leftHip])
    }
    func testIncompletePoseAndMultiplePeopleNeverInventAngles() {
        let missing = frame(0,0.2)
        XCTAssertNil(BiomechanicsEngine.measure(missing,settings: FitSettings())[.kneeFlexion])
        var multi = missing; multi.peopleCount = 2
        var tracker = JointTrackingEngine()
        XCTAssertTrue(tracker.filter(multi,alpha: 0.5,threshold: 0.6).joints.isEmpty)
    }
    func testNormalizedCoordinatesAreScaledBeforeAngleCalculation() {
        let joints: [JointName:TrackedJoint] = [
            .leftHip: TrackedJoint(point: Point2D(x: 0.5,y: 0.8),confidence: 0.9),
            .leftKnee: TrackedJoint(point: Point2D(x: 0.5,y: 0.5),confidence: 0.9),
            .leftAnkle: TrackedJoint(point: Point2D(x: 0.65,y: 0.2),confidence: 0.9)]
        let pose = PoseFrame(timestamp: 0,width: 2000,height: 1000,joints: joints,peopleCount: 1)
        XCTAssertEqual(BiomechanicsEngine.measure(pose,settings: FitSettings())[.kneeFlexion]!,45,accuracy: 0.001)
    }
    func testPedalExtremaAndConsistencyRequireRepeatedStrokes() {
        var analyzer = PedalCycleAnalyzer()
        for i in 0..<180 {
            let time = Double(i) / 30
            let flexion = 65 - 30 * cos(2 * .pi * time)
            analyzer.append(MetricSample(time: time,values: [.kneeFlexion:flexion,.hipAngle:100 + 10 * cos(2 * .pi * time)],confidence: 0.9),threshold: 0.6)
        }
        XCTAssertGreaterThanOrEqual(analyzer.strokes.count,4)
        XCTAssertEqual(analyzer.maximumExtension!,35,accuracy: 1)
        XCTAssertLessThan(analyzer.extensionVariation!,1)
        XCTAssertEqual(analyzer.strokes.last!.maximumKneeFlexion,95,accuracy: 1)
        XCTAssertNotNil(analyzer.strokes.last!.minimumHipAngle)
    }
    func testTrackingGapCannotProducePedalStroke() {
        var analyzer = PedalCycleAnalyzer()
        analyzer.append(MetricSample(time: 0,values: [.kneeFlexion:30],confidence: 0.9),threshold: 0.6)
        analyzer.append(MetricSample(time: 0.1,values: [.kneeFlexion:90],confidence: 0.9),threshold: 0.6)
        analyzer.append(MetricSample(time: 1,values: [.kneeFlexion:30],confidence: 0.9),threshold: 0.6)
        XCTAssertTrue(analyzer.strokes.isEmpty)
    }
    func testReferenceRangesAndUnavailableReadings() {
        let range = ReferenceRange(lower: 30,upper: 40)
        XCTAssertEqual(range.evaluate(29,confidence: 0.9),.below)
        XCTAssertEqual(range.evaluate(30,confidence: 0.9),.within)
        XCTAssertEqual(range.evaluate(40,confidence: 0.9),.within)
        XCTAssertEqual(range.evaluate(41,confidence: 0.9),.above)
        XCTAssertEqual(range.evaluate(35,confidence: 0.2),.unavailable)
        XCTAssertEqual(range.evaluate(nil,confidence: 0.9),.unavailable)
        XCTAssertEqual(range.evaluate(.nan,confidence: 0.9),.unavailable)
    }
    func testRecommendationRequiresCalibrationAndReliableHistory() {
        let engine = BikeFitAnalysisEngine()
        XCTAssertTrue(BikeFitRecommendationEngine.guidance(step: .saddleHeight,engine: engine,settings: FitSettings()).contains("calibration"))
        var settings = FitSettings(); settings.calibrated = true
        XCTAssertTrue(BikeFitRecommendationEngine.guidance(step: .saddleHeight,engine: engine,settings: settings).contains("No adjustment"))
    }
    func testBoundedRollingHistoryAndCurrentUnavailable() {
        var engine = BikeFitAnalysisEngine()
        for i in 0..<1000 { _ = engine.process(frame(Double(i) / 10,0.5), settings: FitSettings()) }
        XCTAssertLessThanOrEqual(engine.history.count,301)
        XCTAssertNil(engine.statistics(.kneeFlexion).current)
    }
    func testFullRateAggregatesPreserveExtremaBetweenTimelineSamples() {
        var accumulator = MeasurementAccumulator()
        for value in [35.0, 27.0, 42.0] { accumulator.append(MetricSample(time: value,values: [.kneeFlexion:value],confidence: 0.9)) }
        let stats = accumulator.statistics[.kneeFlexion]!
        XCTAssertEqual(stats.minimum,27)
        XCTAssertEqual(stats.maximum,42)
        XCTAssertEqual(stats.average!,104 / 3,accuracy: 0.0001)
        accumulator.append(MetricSample(time: 50,values: [:],confidence: 0))
        XCTAssertNil(accumulator.statistics[.kneeFlexion]?.current)
        XCTAssertEqual(accumulator.statistics[.kneeFlexion]?.count,3)
    }
    func testInvalidReferenceRangeRemainsUnavailable() {
        XCTAssertEqual(ReferenceRange(lower: 45,upper: 30).evaluate(40,confidence: 0.9),.unavailable)
    }
    private func riderFrame(time: Double, flexion: Double) -> PoseFrame {
        let radians = flexion * .pi / 180
        let points: [JointName: Point2D] = [
            .leftHip: Point2D(x: 0.5,y: 0.75), .leftKnee: Point2D(x: 0.5,y: 0.45),
            .leftAnkle: Point2D(x: 0.5 + 0.3 * sin(radians),y: 0.45 - 0.3 * cos(radians)),
            .leftShoulder: Point2D(x: 0.8,y: 0.9), .leftElbow: Point2D(x: 0.83,y: 0.8), .leftWrist: Point2D(x: 0.9,y: 0.7)]
        return PoseFrame(timestamp: time,width: 1000,height: 1000,joints: points.mapValues { TrackedJoint(point: $0,confidence: 0.9) },peopleCount: 1)
    }
    func testSaddleGuidanceRequiresFreshReliableRepeatedStrokes() {
        var engine = BikeFitAnalysisEngine()
        var settings = FitSettings(); settings.calibrated = true; settings.smoothing = 1
        for i in 0..<180 {
            let time = Double(i) / 30
            _ = engine.process(riderFrame(time: time,flexion: 57 - 30 * cos(2 * .pi * time)),settings: settings)
        }
        XCTAssertTrue(BikeFitRecommendationEngine.guidance(step: .saddleHeight,engine: engine,settings: settings).contains("lower saddle"))
        var low = riderFrame(time: 6,flexion: 27); low.joints[.leftWrist]?.confidence = 0.1
        _ = engine.process(low,settings: settings)
        XCTAssertTrue(BikeFitRecommendationEngine.guidance(step: .saddleHeight,engine: engine,settings: settings).contains("No adjustment"))
        for i in 181..<330 { _ = engine.process(riderFrame(time: Double(i) / 30,flexion: 27),settings: settings) }
        XCTAssertTrue(BikeFitRecommendationEngine.guidance(step: .saddleHeight,engine: engine,settings: settings).contains("fresh"))
    }
}
