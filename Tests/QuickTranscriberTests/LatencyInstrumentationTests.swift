import XCTest
@testable import QuickTranscriberLib

final class LatencyInstrumentationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LatencyInstrumentation.reset()
        LatencyInstrumentation.isEnabled = true
    }

    override func tearDown() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
        super.tearDown()
    }

    func test_mark_whenDisabled_recordsNothing() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        XCTAssertTrue(LatencyInstrumentation.drain().isEmpty)
    }

    func test_mark_whenEnabled_recordsTimestampInOrder() async throws {
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        try await Task.sleep(nanoseconds: 1_000_000)
        LatencyInstrumentation.mark(.inferenceStart, utteranceId: "u1")
        try await Task.sleep(nanoseconds: 1_000_000)
        LatencyInstrumentation.mark(.inferenceEnd, utteranceId: "u1")

        let records = LatencyInstrumentation.drain()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].stage, .vadOnset)
        XCTAssertEqual(records[1].stage, .inferenceStart)
        XCTAssertEqual(records[2].stage, .inferenceEnd)
        XCTAssertLessThan(records[0].timestampNanos, records[1].timestampNanos)
        XCTAssertLessThan(records[1].timestampNanos, records[2].timestampNanos)
    }

    func test_drain_clearsBuffer() {
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        _ = LatencyInstrumentation.drain()
        XCTAssertTrue(LatencyInstrumentation.drain().isEmpty)
    }

    func test_ringBuffer_dropsOldestWhenFull() {
        for i in 0..<(LatencyInstrumentation.bufferCapacity + 10) {
            LatencyInstrumentation.mark(.vadOnset, utteranceId: "u\(i)")
        }
        let records = LatencyInstrumentation.drain()
        XCTAssertEqual(records.count, LatencyInstrumentation.bufferCapacity)
        XCTAssertEqual(records.first?.utteranceId, "u10")
    }
}
