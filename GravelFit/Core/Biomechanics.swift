import Foundation

enum BiomechanicsEngine {
    static func interiorAngle(_ a: Point2D, _ vertex: Point2D, _ b: Point2D) -> Double? {
        let ax = a.x - vertex.x, ay = a.y - vertex.y
        let bx = b.x - vertex.x, by = b.y - vertex.y
        let magnitude = hypot(ax, ay) * hypot(bx, by)
        guard magnitude > 0.000001 else { return nil }
        return acos(max(-1, min(1, (ax * bx + ay * by) / magnitude))) * 180 / .pi
    }
    static func kneeFlexion(hip: Point2D, knee: Point2D, ankle: Point2D) -> Double? {
        interiorAngle(hip, knee, ankle).map { 180 - $0 }
    }
    static func torsoAngle(hip: Point2D, shoulder: Point2D, floorAngle: Double) -> Double? {
        guard hip.distance(to: shoulder) > 0.000001 else { return nil }
        let direction = atan2(shoulder.y - hip.y, shoulder.x - hip.x) * 180 / .pi
        var relative = (direction - floorAngle).truncatingRemainder(dividingBy: 180)
        if relative < 0 { relative += 180 }
        return min(relative, 180 - relative)
    }
    static func measure(_ frame: PoseFrame, settings: FitSettings) -> [MetricKind: Double] {
        var result: [MetricKind: Double] = [.confidence: frame.confidence * 100]
        guard frame.peopleCount == 1 else { return result }
        let names = JointName.limb(settings.side)
        let point: (JointName) -> Point2D? = { frame.pixelPoint($0, threshold: settings.confidenceThreshold) }
        if let hip = point(names.hip), let knee = point(names.knee), let ankle = point(names.ankle) {
            result[.kneeFlexion] = kneeFlexion(hip: hip, knee: knee, ankle: ankle)
        }
        if let shoulder = point(names.shoulder), let hip = point(names.hip) {
            result[.torsoAngle] = torsoAngle(hip: hip, shoulder: shoulder, floorAngle: settings.floorAngle)
            if let knee = point(names.knee) { result[.hipAngle] = interiorAngle(shoulder, hip, knee) }
        }
        if let shoulder = point(names.shoulder), let elbow = point(names.elbow), let wrist = point(names.wrist) {
            result[.elbowAngle] = interiorAngle(shoulder, elbow, wrist)
        }
        return result
    }
}

struct JointTrackingEngine {
    private var previous: [JointName: TrackedJoint] = [:]
    private var lastSeen: [JointName: Double] = [:]
    private var lastTimestamp: Double?
    mutating func reset() { previous.removeAll(); lastSeen.removeAll(); lastTimestamp = nil }
    mutating func filter(_ frame: PoseFrame, alpha: Double, threshold: Double) -> PoseFrame {
        if let lastTimestamp, frame.timestamp <= lastTimestamp || frame.timestamp - lastTimestamp > 0.5 { reset() }
        lastTimestamp = frame.timestamp
        guard frame.peopleCount == 1 else { reset(); return PoseFrame(timestamp: frame.timestamp, width: frame.width, height: frame.height, joints: [:], peopleCount: frame.peopleCount, processingMilliseconds: frame.processingMilliseconds) }
        var output = frame
        output.joints = [:]
        let weight = max(0.05, min(1, alpha))
        for name in JointName.allCases {
            if var joint = frame.joints[name], joint.confidence >= threshold {
                if let old = previous[name], !old.isPredicted {
                    joint.point = Point2D(x: old.point.x + weight * (joint.point.x - old.point.x), y: old.point.y + weight * (joint.point.y - old.point.y))
                }
                joint.isPredicted = false
                output.joints[name] = joint; previous[name] = joint; lastSeen[name] = frame.timestamp
            } else if var old = previous[name], frame.timestamp - (lastSeen[name] ?? -.infinity) <= 0.2 {
                old.isPredicted = true
                old.confidence *= 0.7
                output.joints[name] = old
            } else { previous[name] = nil; lastSeen[name] = nil }
        }
        return output
    }
}

/// Detects repeated knee-flexion cycles; never infers a crank phase from leg extension.
struct PedalCycleAnalyzer {
    private var samples: [MetricSample] = []
    private var valleyTime: Double?
    private var valleyValue = Double.infinity
    private var rising = false
    private(set) var strokes: [PedalStroke] = []
    mutating func reset() { self = PedalCycleAnalyzer() }
    mutating func append(_ sample: MetricSample, threshold: Double) {
        guard let knee = sample.values[.kneeFlexion], sample.confidence >= threshold else {
            samples.removeAll(); valleyTime = nil; valleyValue = .infinity; rising = false; return
        }
        if let last = samples.last, sample.time - last.time > 0.4 {
            samples.removeAll(); valleyTime = nil; valleyValue = .infinity; rising = false
        }
        samples.append(sample)
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
        if valleyTime == nil { valleyTime = sample.time; valleyValue = knee; return }
        if !rising {
            if knee < valleyValue { valleyValue = knee; valleyTime = sample.time }
            if knee > valleyValue + 8 { rising = true }
        } else {
            let maxKnee = samples.filter { $0.time >= (valleyTime ?? 0) }.compactMap { $0.values[.kneeFlexion] }.max() ?? knee
            if knee < maxKnee - 8 && knee <= valleyValue + 5, let start = valleyTime {
                let duration = sample.time - start
                let cycle = samples.filter { $0.time >= start }
                let knees = cycle.compactMap { $0.values[.kneeFlexion] }
                let hips = cycle.compactMap { $0.values[.hipAngle] }
                if duration >= 0.35 && duration <= 3 && maxKnee - valleyValue >= 15 {
                    strokes.append(PedalStroke(start: start, end: sample.time, minimumKneeFlexion: knees.min() ?? knee, maximumKneeFlexion: maxKnee, minimumHipAngle: hips.min(), maximumHipAngle: hips.max(), confidence: cycle.map(\.confidence).min() ?? 0))
                    if strokes.count > 300 { strokes.removeFirst() }
                }
                valleyTime = sample.time; valleyValue = knee; rising = false
                samples = [sample]
            } else if let start = valleyTime, sample.time - start > 3 {
                valleyTime = sample.time; valleyValue = knee; rising = false; samples = [sample]
            }
        }
    }
    var maximumExtension: Double? {
        let values = strokes.suffix(8).map(\.minimumKneeFlexion).sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count / 2]
    }
    var extensionVariation: Double? {
        let values = strokes.suffix(8).map(\.minimumKneeFlexion)
        guard values.count >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count))
    }
}

struct BikeFitAnalysisEngine {
    private var tracker = JointTrackingEngine()
    private(set) var cycles = PedalCycleAnalyzer()
    private var hipHistory: [(time: Double, y: Double, leg: Double)] = []
    private(set) var history: [MetricSample] = []
    mutating func reset() { self = BikeFitAnalysisEngine() }
    mutating func process(_ raw: PoseFrame, settings: FitSettings) -> (PoseFrame, MetricSample) {
        let pose = tracker.filter(raw, alpha: settings.smoothing, threshold: settings.confidenceThreshold)
        var values = BiomechanicsEngine.measure(pose, settings: settings)
        let names = JointName.limb(settings.side)
        if let hip = pose.pixelPoint(names.hip, threshold: settings.confidenceThreshold),
           let knee = pose.pixelPoint(names.knee, threshold: settings.confidenceThreshold),
           let ankle = pose.pixelPoint(names.ankle, threshold: settings.confidenceThreshold) {
            hipHistory.append((raw.timestamp, hip.y, hip.distance(to: knee) + knee.distance(to: ankle)))
            hipHistory.removeAll { raw.timestamp - $0.time > 5 }
            if hipHistory.count >= 20, let first = hipHistory.first, raw.timestamp - first.time >= 2 {
                let ys = hipHistory.map(\.y).sorted()
                let excursion = ys[Int(Double(ys.count - 1) * 0.95)] - ys[Int(Double(ys.count - 1) * 0.05)]
                let length = hipHistory.map(\.leg).reduce(0, +) / Double(hipHistory.count)
                if length > 1 { values[.pelvicMovement] = 100 * excursion / length }
            }
        } else { hipHistory.removeAll() }
        let limb = [names.shoulder, names.elbow, names.wrist, names.hip, names.knee, names.ankle]
        let confidence = limb.map { pose.joints[$0].map { $0.isPredicted ? 0 : $0.confidence } ?? 0 }.min() ?? 0
        let sample = MetricSample(time: raw.timestamp, values: values, confidence: confidence)
        history.append(sample)
        history.removeAll { raw.timestamp - $0.time > 30 }
        cycles.append(sample, threshold: settings.confidenceThreshold)
        return (pose, sample)
    }
    func statistics(_ kind: MetricKind) -> MetricStatistics {
        MetricStatistics(values: history.compactMap { $0.values[kind] }, current: history.last?.values[kind])
    }
}

enum BikeFitRecommendationEngine {
    static func guidance(step: FitStep, engine: BikeFitAnalysisEngine, settings: FitSettings) -> String {
        guard settings.calibrated else { return "Complete camera calibration before evaluating adjustments." }
        let recent = engine.history.suffix(45)
        guard recent.count >= 30,
              Double(recent.filter({ $0.confidence >= settings.confidenceThreshold }).count) / Double(recent.count) >= 0.9,
              (recent.last?.confidence ?? 0) >= settings.confidenceThreshold else {
            return "Collect several seconds of clear, single-rider tracking before considering a change. No adjustment is suggested yet."
        }
        switch step {
        case .saddleHeight:
            guard let latestStroke = engine.cycles.strokes.last, let latestSample = recent.last,
                  latestSample.time - latestStroke.end <= 3 else { return "Keep pedaling steadily to collect fresh, repeated extension measurements before considering saddle height." }
            guard let extensionValue = engine.cycles.maximumExtension, let variation = engine.cycles.extensionVariation else { return "Pedal steadily for at least three complete detected strokes. Maximum extension and crank bottom dead center are different measurements." }
            guard variation <= 4 else { return "Extension varies between strokes. Check the camera position, tracking and cadence, then repeat before adjusting the saddle." }
            switch settings.kneeExtensionRange.evaluate(extensionValue, confidence: recent.last?.confidence ?? 0) {
            case .below: return "Repeated maximum-extension flexion is about \(Int(extensionValue.rounded()))°. A slightly lower saddle may be worth testing: measure a 2–3 mm change, confirm it, then pedal again and check stability and comfort."
            case .above: return "Repeated maximum-extension flexion is about \(Int(extensionValue.rounded()))°. A slightly higher saddle may be worth testing: measure a 2–3 mm change, confirm it, then check stability and comfort."
            case .within: return "Maximum extension falls within your working reference. Validate comfort and stability across hand positions before making a change."
            case .unavailable: return "The extension reference or measurement is unavailable. Check the selected range and tracking quality before making a change."
            }
        case .barHeight:
            let average = engine.statistics(.torsoAngle).average
            if settings.torsoRange.evaluate(average, confidence: recent.last?.confidence ?? 0) == .below {
                return "Your torso is below the selected working range. If comfort or breathing is limited, test a small increase in bar height within the component's adjustment limits, then remeasure."
            }
            return "Use the working torso range alongside comfort, breathing and control. Record small changes, then compare a fresh measurement."
        case .barReach:
            if (engine.statistics(.elbowAngle).average ?? 0) > 165 { return "Your elbows remain close to straight. Check shoulder tension and hand pressure; if uncomfortable, consider a small measured reach change and repeat the capture." }
            return "Assess shoulder and wrist comfort alongside elbow movement. There is no single correct elbow angle."
        default: return step.explanation + " Change one variable at a time and collect a fresh measurement after confirming the adjustment."
        }
    }
}

enum VideoOverlayRenderer {
    /// Vision uses bottom-left normalized coordinates; the view uses top-left points.
    static func map(_ point: Point2D, imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double, mirrored: Bool) -> Point2D {
        let scale = min(viewWidth / max(1, imageWidth), viewHeight / max(1, imageHeight))
        let w = imageWidth * scale, h = imageHeight * scale
        return Point2D(x: (viewWidth - w) / 2 + (mirrored ? 1 - point.x : point.x) * w,
                       y: (viewHeight - h) / 2 + (1 - point.y) * h)
    }
}
