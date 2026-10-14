import Foundation

struct ChartDatum: Identifiable {
    var id: UUID
    var time: Double
    var value: Double
    var segment: Int
}

/// Break lines at unavailable observations and reduce long timelines while retaining bucket extrema.
func chartData(_ samples: [MetricSample], metric: MetricKind, maxPoints: Int = 1200) -> [ChartDatum] {
    var points: [ChartDatum] = []
    var segment = 0
    var previousTime: Double?
    for sample in samples {
        guard let value = sample.values[metric], value.isFinite else { previousTime = nil; continue }
        if previousTime == nil || sample.time - (previousTime ?? sample.time) > 1 { segment += 1 }
        points.append(ChartDatum(id: sample.id, time: sample.time, value: value, segment: segment))
        previousTime = sample.time
    }
    guard points.count > maxPoints else { return points }
    let bucket = max(4, Int(ceil(Double(points.count) / Double(maxPoints / 4))))
    var reduced: [ChartDatum] = []
    for start in stride(from: 0, to: points.count, by: bucket) {
        let end = min(points.count, start + bucket)
        let indices = Array(start..<end)
        let minimum = indices.min(by: { points[$0].value < points[$1].value }) ?? start
        let maximum = indices.max(by: { points[$0].value < points[$1].value }) ?? start
        for index in Set([start, minimum, maximum, end - 1]).sorted() { reduced.append(points[index]) }
    }
    return reduced
}
