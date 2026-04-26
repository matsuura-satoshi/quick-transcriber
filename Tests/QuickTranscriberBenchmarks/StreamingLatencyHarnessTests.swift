import XCTest
@testable import QuickTranscriberLib

final class StreamingLatencyHarnessTests: XCTestCase {
    func test_concatenate_producesExpectedDurationAndBoundaries() {
        let u1 = [Float](repeating: 0.1, count: 16_000 * 2) // 2 s
        let u2 = [Float](repeating: 0.1, count: 16_000 * 3) // 3 s
        let harness = StreamingLatencyHarness(silenceGapSeconds: 1.2, sampleRate: 16_000)

        let stream = harness.concatenate(utterances: [u1, u2])

        let expectedSamples = (2 + 1.2 + 3) * 16_000
        XCTAssertEqual(Double(stream.samples.count), expectedSamples, accuracy: 1)
        XCTAssertEqual(stream.utteranceBoundaries.count, 2)
        XCTAssertEqual(stream.utteranceBoundaries[0].startSample, 0)
        XCTAssertEqual(stream.utteranceBoundaries[0].endSample, 16_000 * 2)
        XCTAssertEqual(
            stream.utteranceBoundaries[1].startSample,
            16_000 * 2 + Int(1.2 * 16_000)
        )
    }

    func test_concatenate_singleUtterance_hasNoTrailingSilence() {
        let u1 = [Float](repeating: 0.1, count: 16_000)
        let harness = StreamingLatencyHarness(silenceGapSeconds: 1.2, sampleRate: 16_000)

        let stream = harness.concatenate(utterances: [u1])

        XCTAssertEqual(stream.samples.count, 16_000)
        XCTAssertEqual(stream.utteranceBoundaries.count, 1)
    }

    func test_perUtteranceLatency_decomposesStagesCorrectly() {
        let records: [LatencyRecord] = [
            LatencyRecord(utteranceId: "u1", stage: .vadOnset,          timestampNanos:   800_000_000),
            LatencyRecord(utteranceId: "u1", stage: .vadConfirmSilence, timestampNanos: 1_000_000_000),
            LatencyRecord(utteranceId: "u1", stage: .inferenceStart,    timestampNanos: 1_050_000_000),
            LatencyRecord(utteranceId: "u1", stage: .inferenceEnd,      timestampNanos: 1_450_000_000),
            LatencyRecord(utteranceId: "u1", stage: .emitToUI,          timestampNanos: 1_480_000_000),
            LatencyRecord(utteranceId: "u2", stage: .inferenceStart,    timestampNanos: 2_000_000_000),
        ]

        let breakdown = StreamingLatencyHarness.perUtteranceLatency(
            from: records,
            utteranceId: "u1"
        )

        XCTAssertEqual(breakdown.tVadWaitSeconds, 0.2, accuracy: 0.001)
        XCTAssertEqual(breakdown.tInferenceSeconds, 0.4, accuracy: 0.001)
        XCTAssertEqual(breakdown.tEmitSeconds, 0.03, accuracy: 0.001)
        XCTAssertEqual(breakdown.tTotalSeconds, 0.48, accuracy: 0.001)
    }

    func test_perUtteranceLatency_returnsZeroBreakdownWhenNoRecords() {
        let breakdown = StreamingLatencyHarness.perUtteranceLatency(
            from: [],
            utteranceId: "missing"
        )

        XCTAssertEqual(breakdown.tVadWaitSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.tInferenceSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.tEmitSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.tTotalSeconds, 0, accuracy: 0.001)
    }
}
