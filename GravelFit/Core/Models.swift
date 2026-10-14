import Foundation

enum RiderSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum HandPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case hoods, drops, tops
    var id: String { rawValue }
}

enum JointName: String, Codable, CaseIterable, Sendable {
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
    static let bones: [(JointName, JointName)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]
    static func limb(_ side: RiderSide) -> (shoulder: JointName, elbow: JointName, wrist: JointName, hip: JointName, knee: JointName, ankle: JointName) {
        side == .left ? (.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle)
            : (.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle)
    }
}

struct Point2D: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    func distance(to other: Point2D) -> Double { hypot(x - other.x, y - other.y) }
}

struct TrackedJoint: Codable, Sendable {
    var point: Point2D
    var confidence: Double
    var isPredicted = false
}

struct PoseFrame: Codable, Sendable {
    var timestamp: Double
    var width: Double
    var height: Double
    var joints: [JointName: TrackedJoint]
    var peopleCount: Int
    var processingMilliseconds: Double = 0
    var confidence: Double {
        let reliable = joints.values.filter { !$0.isPredicted }
        return reliable.isEmpty ? 0 : reliable.map(\.confidence).reduce(0, +) / Double(reliable.count)
    }
    func pixelPoint(_ name: JointName, threshold: Double) -> Point2D? {
        guard peopleCount == 1, let joint = joints[name], joint.confidence >= threshold, !joint.isPredicted else { return nil }
        return Point2D(x: joint.point.x * width, y: joint.point.y * height)
    }
}

enum MetricKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case kneeFlexion, hipAngle, torsoAngle, elbowAngle, pelvicMovement, confidence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kneeFlexion: "Knee flexion"
        case .hipAngle: "Shoulder–hip–knee"
        case .torsoAngle: "Torso to ground"
        case .elbowAngle: "Elbow angle"
        case .pelvicMovement: "Vertical hip motion"
        case .confidence: "Tracking confidence"
        }
    }
    var unit: String {
        switch self {
        case .confidence, .pelvicMovement: "%"
        default: "°"
        }
    }
    var note: String {
        switch self {
        case .hipAngle: "Video-derived torso/thigh angle; not anatomical hip flexion. No universal target."
        case .pelvicMovement: "Side-view vertical excursion as % of visible leg length. Rear view required to assess lateral rocking."
        case .kneeFlexion: "Live flexion is phase-dependent. Evaluate the selected range at repeated maximum extension."
        case .elbowAngle: "Repeated near-straight elbows may warrant a comfort/reach check; no universal target."
        case .torsoAngle: "Configurable working range for endurance gravel riding."
        case .confidence: "Vision detection confidence; not an angle accuracy estimate."
        }
    }
}

struct MetricSample: Codable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var values: [MetricKind: Double]
    var confidence: Double
}

struct MetricStatistics: Codable, Sendable {
    var current: Double?
    var minimum: Double?
    var maximum: Double?
    var average: Double?
    var count: Int = 0
    init(values: [Double] = [], current: Double? = nil) {
        self.current = current
        minimum = values.min()
        maximum = values.max()
        average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        count = values.count
    }
}

struct MeasurementAccumulator: Sendable {
    private(set) var statistics: [MetricKind: MetricStatistics] = [:]
    mutating func append(_ sample: MetricSample) {
        for kind in MetricKind.allCases {
            var stats = statistics[kind] ?? MetricStatistics()
            stats.current = sample.values[kind]
            if let value = sample.values[kind], value.isFinite {
                stats.minimum = min(stats.minimum ?? value, value)
                stats.maximum = max(stats.maximum ?? value, value)
                stats.count += 1
                stats.average = (stats.average ?? 0) + (value - (stats.average ?? 0)) / Double(stats.count)
            }
            statistics[kind] = stats
        }
    }
}

struct ReferenceRange: Codable, Equatable, Sendable {
    var lower: Double
    var upper: Double
    enum Evaluation: Equatable { case below, within, above, unavailable }
    func evaluate(_ value: Double?, confidence: Double, threshold: Double = 0.6) -> Evaluation {
        guard lower.isFinite, upper.isFinite, lower <= upper,
              let value, value.isFinite, confidence >= threshold else { return .unavailable }
        if value < lower { return .below }
        if value > upper { return .above }
        return .within
    }
}

struct FitSettings: Codable, Equatable, Sendable {
    var side: RiderSide = .left
    var handPosition: HandPosition = .hoods
    var confidenceThreshold = 0.6
    var smoothing = 0.35
    var analysisFPS = 15.0
    var mirror = false
    var rotation = 0.0
    var floorAngle = 0.0
    var kneeExtensionRange = ReferenceRange(lower: 30, upper: 40)
    var bottomDeadCenterRange = ReferenceRange(lower: 33, upper: 43)
    var torsoRange = ReferenceRange(lower: 40, upper: 55)
    var showSkeleton = true
    var showJoints = true
    var showAngles = true
    var showArcs = true
    var showTrails = false
    var overlayMetrics: Set<MetricKind> = [.kneeFlexion, .hipAngle, .torsoAngle, .elbowAngle]
    var calibrated = false
}

struct BikeProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "My gravel bike"
    var type = "Gravel"
    var crankLength = 172.5
    var saddleHeight = 740.0
    var saddleSetback = 60.0
    var saddleTilt = -2.0
    var handlebarDrop = 60.0
    var effectiveReach = 550.0
    var stemLength = 90.0
    var handlebarWidth = 420.0
    var cleatNotes = ""
    var riderNotes = ""
}

enum FitStep: Int, Codable, CaseIterable, Identifiable, Sendable {
    case cleats, saddleHeight, saddleForeAft, saddleTilt, barHeight, barReach, hoods, validation
    var id: Int { rawValue }
    var title: String {
        ["Cleat position & foot alignment", "Saddle height", "Saddle fore-aft", "Saddle tilt", "Handlebar height", "Handlebar reach", "Hood positioning", "Final validation"][rawValue]
    }
    var unit: String { self == .saddleTilt || self == .hoods || self == .cleats ? "°" : "mm" }
    var explanation: String {
        switch self {
        case .cleats: "Check foot comfort and natural alignment. A side camera cannot determine cleat rotation or frontal knee tracking. Record observations and inspect your setup directly."
        case .saddleHeight: "Measure knee flexion at maximum dynamic extension across several strokes, then check vertical hip movement and comfort."
        case .saddleForeAft: "Compare reach, load on your hands and pedaling comfort. A side-view pose does not establish a universal saddle setback."
        case .saddleTilt: "Check support and sliding on the saddle. Use a level and record small changes in degrees."
        case .barHeight: "Compare torso-to-ground angle with your working range. Check comfort, breathing and pelvic stability."
        case .barReach: "Check sustained elbow extension, shoulder tension and hand pressure with hands in the selected position."
        case .hoods: "Check wrist comfort and access to the brake levers. Record small hood angle changes after measuring them directly."
        case .validation: "Pedal for several minutes in each intended hand position. Compare repeatability, comfort and stability with your baseline."
        }
    }
}

struct Adjustment: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var step: FitStep
    var amount: Double
    var unit: String
    var notes: String
    var before: [MetricKind: Double]
    var after: [MetricKind: Double]?
    var confirmed = true
}

enum CrankPosition: String, Codable, CaseIterable, Sendable { case topDeadCenter, bottomDeadCenter }
struct FrameAnnotation: Codable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var position: CrankPosition
    var kneeFlexion: Double?
    var hipAngle: Double?
    var confidence: Double
}

struct PedalStroke: Codable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var minimumKneeFlexion: Double
    var maximumKneeFlexion: Double
    var minimumHipAngle: Double?
    var maximumHipAngle: Double?
    var confidence: Double
}

struct FitSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var created = Date()
    var bikeID: UUID?
    var bikeSnapshot: BikeProfile?
    var settings: FitSettings
    var duration: Double = 0
    var videoFilename: String?
    var samples: [MetricSample] = []
    var aggregateStatistics: [MetricKind: MetricStatistics]?
    var strokes: [PedalStroke] = []
    var adjustments: [Adjustment] = []
    var annotations: [FrameAnnotation] = []
    var observations = ""
    var isBaseline = false
    var imported = false
    var sourceRange: VideoTimeRange?
    mutating func applySourceRange(_ range: VideoTimeRange) {
        sourceRange = range
        annotations = annotations.filter { $0.time >= range.start && $0.time < range.end }.map { var annotation = $0; annotation.time -= range.start; return annotation }
    }
    var statistics: [MetricKind: MetricStatistics] {
        if let aggregateStatistics { return aggregateStatistics }
        return Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { kind in
            (kind, MetricStatistics(values: samples.compactMap { $0.values[kind] }, current: samples.last?.values[kind]))
        })
    }
}

struct VideoTimeRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
    func isValid(for videoDuration: Double) -> Bool {
        videoDuration.isFinite && videoDuration > 0 && start.isFinite && end.isFinite && start >= 0 && end > start && end <= videoDuration
    }
}

struct VideoTrimRequest: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let template: FitSession
    var securityScoped = false
}
