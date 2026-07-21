import XCTest
@testable import AudioEngine

final class RingBufferTests: XCTestCase {

    func testWriteAndReadBack() {
        let buffer = RingBuffer(capacity: 10)
        buffer.write([1.0, 2.0, 3.0, 4.0, 5.0])

        let result = buffer.readLast(sampleCount: 5)
        XCTAssertEqual(result, [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    func testReadLastPartial() {
        let buffer = RingBuffer(capacity: 10)
        buffer.write([1.0, 2.0, 3.0, 4.0, 5.0])

        let result = buffer.readLast(sampleCount: 3)
        XCTAssertEqual(result, [3.0, 4.0, 5.0])
    }

    func testWrapAround() {
        let buffer = RingBuffer(capacity: 5)
        buffer.write([1.0, 2.0, 3.0, 4.0, 5.0])
        buffer.write([6.0, 7.0])

        let result = buffer.readLast(sampleCount: 5)
        XCTAssertEqual(result, [3.0, 4.0, 5.0, 6.0, 7.0])
    }

    func testReadMoreThanAvailable() {
        let buffer = RingBuffer(capacity: 10)
        buffer.write([1.0, 2.0, 3.0])

        let result = buffer.readLast(sampleCount: 10)
        XCTAssertEqual(result, [1.0, 2.0, 3.0])
    }

    func testClear() {
        let buffer = RingBuffer(capacity: 10)
        buffer.write([1.0, 2.0, 3.0])
        buffer.clear()

        let result = buffer.readLast(sampleCount: 10)
        XCTAssertEqual(result, [])
    }

    func testAvailableSamples() {
        let buffer = RingBuffer(capacity: 5)
        XCTAssertEqual(buffer.availableSamples, 0)

        buffer.write([1.0, 2.0, 3.0])
        XCTAssertEqual(buffer.availableSamples, 3)

        buffer.write([4.0, 5.0, 6.0])
        XCTAssertEqual(buffer.availableSamples, 5) // capacity-limited
    }

    func testReadLastSeconds() {
        let sampleRate = 16000
        let buffer = RingBuffer(capacity: sampleRate * 5) // 5 seconds
        let oneSecond = [Float](repeating: 0.5, count: sampleRate)
        buffer.write(oneSecond)
        buffer.write(oneSecond)

        let result = buffer.readLast(seconds: 1.0, sampleRate: sampleRate)
        XCTAssertEqual(result.count, sampleRate)
    }

    func testEmptyRead() {
        let buffer = RingBuffer(capacity: 10)
        let result = buffer.readLast(sampleCount: 5)
        XCTAssertEqual(result, [])
    }

    func testFullOverwrite() {
        let buffer = RingBuffer(capacity: 3)
        buffer.write([1.0, 2.0, 3.0])
        buffer.write([4.0, 5.0, 6.0])
        buffer.write([7.0, 8.0, 9.0])

        let result = buffer.readLast(sampleCount: 3)
        XCTAssertEqual(result, [7.0, 8.0, 9.0])
    }
}
