import XCTest
@testable import App

final class AnalyticsThrottleTests: XCTestCase {
    func testFirstEventIsSentAndRepeatsInsideWindowAreDropped() {
        var throttle = AnalyticsThrottle(window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(throttle.admit("deviceSwitchFailed|x", now: t0), 0)
        XCTAssertNil(throttle.admit("deviceSwitchFailed|x", now: t0.addingTimeInterval(2)))
        XCTAssertNil(throttle.admit("deviceSwitchFailed|x", now: t0.addingTimeInterval(4)))
    }

    func testAfterWindowReportsSuppressedCount() {
        var throttle = AnalyticsThrottle(window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = throttle.admit("k", now: t0)
        for i in 1...1_650 { _ = throttle.admit("k", now: t0.addingTimeInterval(Double(i) * 0.3)) }
        XCTAssertEqual(throttle.admit("k", now: t0.addingTimeInterval(601)), 1_650)
        XCTAssertNil(throttle.admit("k", now: t0.addingTimeInterval(602)))
    }

    func testKeysAreIndependent() {
        var throttle = AnalyticsThrottle(window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(throttle.admit("a", now: t0), 0)
        XCTAssertEqual(throttle.admit("b", now: t0), 0)
    }
}
