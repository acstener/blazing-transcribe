import XCTest
@testable import App

final class ShortcutCaptureCoordinatorTests: XCTestCase {
    @MainActor
    func testCoordinatorPublishesOnlyActiveRecorder() {
        let coordinator = ShortcutCaptureCoordinator.shared
        let firstSession = UUID()
        let secondSession = UUID()

        coordinator.end(firstSession)
        coordinator.end(secondSession)

        coordinator.begin(firstSession)
        XCTAssertEqual(coordinator.activeSessionID, firstSession)
        XCTAssertTrue(coordinator.isCapturing)

        coordinator.begin(secondSession)
        XCTAssertEqual(coordinator.activeSessionID, secondSession)
        XCTAssertTrue(coordinator.isCapturing)

        coordinator.end(firstSession)
        XCTAssertEqual(coordinator.activeSessionID, secondSession)
        XCTAssertTrue(coordinator.isCapturing)

        coordinator.end(secondSession)
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertFalse(coordinator.isCapturing)
    }
}
