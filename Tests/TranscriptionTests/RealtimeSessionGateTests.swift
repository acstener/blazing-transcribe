import XCTest
@testable import Transcription

final class RealtimeSessionGateTests: XCTestCase {
    func testStartBeginFinishCycleAcceptsOnlyCurrentSession() throws {
        var gate = RealtimeSessionGate()

        let sessionID = try gate.startSession()
        XCTAssertEqual(sessionID, 1)
        XCTAssertEqual(gate.activeStreamingSessionID, sessionID)
        XCTAssertTrue(gate.acceptsUpdate(for: sessionID))
        XCTAssertFalse(gate.acceptsUpdate(for: sessionID + 1))

        let finishingID = try gate.beginFinishing()
        XCTAssertEqual(finishingID, sessionID)
        XCTAssertNil(gate.activeStreamingSessionID)
        XCTAssertEqual(gate.currentSessionID, sessionID)
        XCTAssertTrue(gate.acceptsUpdate(for: sessionID))

        gate.complete(sessionID: sessionID)
        XCTAssertNil(gate.currentSessionID)
        XCTAssertFalse(gate.acceptsUpdate(for: sessionID))
    }

    func testStartingSecondSessionWithoutCompletingFirstThrows() throws {
        var gate = RealtimeSessionGate()
        _ = try gate.startSession()

        XCTAssertThrowsError(try gate.startSession()) { error in
            XCTAssertEqual(
                (error as? RealtimeParakeetServiceError)?.errorDescription,
                RealtimeParakeetServiceError.utteranceAlreadyActive.errorDescription
            )
        }
    }

    func testCancelCurrentResetsGateAndAdvancesNextSession() throws {
        var gate = RealtimeSessionGate()
        let firstSession = try gate.startSession()

        XCTAssertEqual(gate.cancelCurrent(), firstSession)
        XCTAssertNil(gate.currentSessionID)

        let secondSession = try gate.startSession()
        XCTAssertEqual(secondSession, firstSession + 1)
    }
}
