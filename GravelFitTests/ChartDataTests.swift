import XCTest

final class ChartDataTests: XCTestCase {
    func testUnavailableReadingBreaksTheLine() {
        let samples = [
            MetricSample(time: 0,values: [.kneeFlexion:35],confidence: 0.9),
            MetricSample(time: 0.1,values: [:],confidence: 0),
            MetricSample(time: 0.2,values: [.kneeFlexion:40],confidence: 0.9)]
        let points = chartData(samples,metric: .kneeFlexion)
        XCTAssertEqual(points.count,2)
        XCTAssertNotEqual(points[0].segment,points[1].segment)
    }
    func testLongChartReductionRetainsExtremaAndBoundsDrawingWork() {
        let samples = (0..<10000).map { index in MetricSample(time: Double(index) / 10,values: [.kneeFlexion:index == 1234 ? 140 : index == 7654 ? 10 : 40],confidence: 0.9) }
        let points = chartData(samples,metric: .kneeFlexion)
        XCTAssertLessThanOrEqual(points.count,1200)
        XCTAssertEqual(points.map(\.value).min(),10)
        XCTAssertEqual(points.map(\.value).max(),140)
        XCTAssertEqual(points.first?.time,0)
        XCTAssertEqual(points.last?.time,999.9)
    }
}
