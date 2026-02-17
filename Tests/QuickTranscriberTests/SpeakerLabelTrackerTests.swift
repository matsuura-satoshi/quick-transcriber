import XCTest
@testable import QuickTranscriberLib

final class SpeakerLabelTrackerTests: XCTestCase {

    // MARK: - Helper

    private func id(_ label: String, _ confidence: Float = 0.9) -> SpeakerIdentification {
        SpeakerIdentification(label: label, confidence: confidence)
    }

    // MARK: - First speaker is confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))  // confirm A
        let result = tracker.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Single different label returns nil (pending)

    func testSingleDifferentLabelReturnsPending() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))  // confirm A
        let result = tracker.processLabel(id("B"))  // only 1 B, need 2
        XCTAssertNil(result)
    }

    // MARK: - Threshold reached confirms new speaker

    func testThresholdReachedConfirmsNewSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))  // confirm A
        _ = tracker.processLabel(id("B"))  // pending (1/2)
        let result = tracker.processLabel(id("B"))  // confirmed (2/2)
        XCTAssertEqual(result?.label, "B")
    }

    // MARK: - False alarm: different then back to original

    func testFalseAlarmReturnsToOriginal() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))     // confirm A
        _ = tracker.processLabel(id("B"))     // pending
        let result = tracker.processLabel(id("A"))  // back to A
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Nil label returns current confirmed speaker

    func testNilLabelReturnsConfirmedSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))  // confirm A
        let result = tracker.processLabel(nil)
        XCTAssertEqual(result?.label, "A")
    }

    func testNilLabelWithNoConfirmedSpeakerReturnsNil() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel(nil)
        XCTAssertNil(result)
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        XCTAssertEqual(tracker.processLabel(id("A"))?.label, "A")   // confirm A
        XCTAssertNil(tracker.processLabel(id("B")))                  // pending
        XCTAssertEqual(tracker.processLabel(id("B"))?.label, "B")    // confirm B
        XCTAssertNil(tracker.processLabel(id("A")))                  // pending
        XCTAssertEqual(tracker.processLabel(id("A"))?.label, "A")    // confirm A
    }

    // MARK: - Threshold of 3

    func testHigherThreshold() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel(id("A"))?.label, "A")
        XCTAssertNil(tracker.processLabel(id("B")))   // 1/3
        XCTAssertNil(tracker.processLabel(id("B")))   // 2/3
        XCTAssertEqual(tracker.processLabel(id("B"))?.label, "B")  // 3/3 confirmed
    }

    // MARK: - Interrupted pending resets count

    func testInterruptedPendingResetsCount() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel(id("A"))?.label, "A")
        XCTAssertNil(tracker.processLabel(id("B")))   // 1/3
        XCTAssertNil(tracker.processLabel(id("C")))   // C resets B count, 1/3 for C
        XCTAssertNil(tracker.processLabel(id("C")))   // 2/3 for C
        XCTAssertEqual(tracker.processLabel(id("C"))?.label, "C")  // 3/3 confirmed
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(id("A"))
        tracker.reset()
        // After reset, next label is "first speaker" again
        XCTAssertEqual(tracker.processLabel(id("B"))?.label, "B")
    }

    // MARK: - Threshold of 1 (immediate change)

    func testThresholdOneConfirmsImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 1)
        XCTAssertEqual(tracker.processLabel(id("A"))?.label, "A")
        XCTAssertEqual(tracker.processLabel(id("B"))?.label, "B")  // immediate change
    }

    // MARK: - Confidence propagation

    func testProcessLabelPassesThroughConfidence() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.85))
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.85)
    }

    func testProcessLabelConfirmedSpeakerWithNilInputReturnsLastConfidence() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
        let result = tracker.processLabel(nil)
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.9)
    }

    func testProcessLabelUpdatesConfidenceOnSameSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
        let result = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.7))
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.7)
    }

    func testProcessLabelConfirmationUsesLatestConfidence() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
        _ = tracker.processLabel(SpeakerIdentification(label: "B", confidence: 0.6))  // pending
        let result = tracker.processLabel(SpeakerIdentification(label: "B", confidence: 0.75))  // confirmed
        XCTAssertEqual(result?.label, "B")
        XCTAssertEqual(result?.confidence, 0.75)
    }

    // MARK: - Integration: smoothing pipeline with retroactive updates

    func testSpeakerLabelSmoothing() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)

        // Simulate the engine's logic
        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: diarizer says "A" (first speaker, confirmed immediately)
        let speaker1 = tracker.processLabel(id("A"))
        XCTAssertEqual(speaker1?.label, "A")
        segments.append(ConfirmedSegment(text: "Hello", speaker: speaker1?.label, speakerConfidence: speaker1?.confidence))

        // Chunk 2: diarizer says "B" (pending, not yet confirmed)
        let speaker2 = tracker.processLabel(id("B"))
        XCTAssertNil(speaker2)
        segments.append(ConfirmedSegment(text: "New topic", speaker: speaker2?.label, speakerConfidence: speaker2?.confidence))
        pendingStart = 1

        // At this point, joinSegments should show text without speaker change
        let textDuringPending = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(textDuringPending, "A: Hello New topic")

        // Chunk 3: diarizer says "B" again (now confirmed!)
        let speaker3 = tracker.processLabel(id("B"))
        XCTAssertEqual(speaker3?.label, "B")

        // Retroactive update
        if let start = pendingStart {
            for i in start..<segments.count {
                segments[i].speaker = speaker3?.label
                segments[i].speakerConfidence = speaker3?.confidence
            }
            pendingStart = nil
        }
        segments.append(ConfirmedSegment(text: "More talk", speaker: speaker3?.label, speakerConfidence: speaker3?.confidence))

        // After retroactive update, output should show speaker change
        let textAfterConfirm = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(textAfterConfirm, "A: Hello\nB: New topic More talk")
    }

    func testSpeakerLabelFalseAlarm() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)

        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: A confirmed
        let s1 = tracker.processLabel(id("A"))
        segments.append(ConfirmedSegment(text: "Hello", speaker: s1?.label, speakerConfidence: s1?.confidence))

        // Chunk 2: B pending
        let s2 = tracker.processLabel(id("B"))
        XCTAssertNil(s2)
        segments.append(ConfirmedSegment(text: "glitch", speaker: s2?.label, speakerConfidence: s2?.confidence))
        pendingStart = 1

        // Chunk 3: Back to A (false alarm)
        let s3 = tracker.processLabel(id("A"))
        XCTAssertEqual(s3?.label, "A")

        // Retroactive update: pending segments get A (not B)
        if let start = pendingStart {
            for i in start..<segments.count {
                segments[i].speaker = s3?.label
                segments[i].speakerConfidence = s3?.confidence
            }
            pendingStart = nil
        }
        segments.append(ConfirmedSegment(text: "continuing", speaker: s3?.label, speakerConfidence: s3?.confidence))

        let text = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        // All segments are speaker A, no speaker change line
        XCTAssertEqual(text, "A: Hello glitch continuing")
    }
}
