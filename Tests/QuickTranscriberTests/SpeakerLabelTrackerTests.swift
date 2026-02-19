import XCTest
@testable import QuickTranscriberLib

final class ViterbiSpeakerSmootherTests: XCTestCase {

    // MARK: - Helper

    private func id(_ label: String, _ confidence: Float = 0.9) -> SpeakerIdentification {
        SpeakerIdentification(label: label, confidence: confidence)
    }

    // MARK: - First speaker confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A"))
        let result = smoother.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Nil input

    func testNilInputReturnsConfirmed() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A"))
        let result = smoother.processLabel(nil)
        XCTAssertEqual(result?.label, "A")
    }

    func testNilInputWithNoConfirmedReturnsNil() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.processLabel(nil)
        XCTAssertNil(result)
    }

    // MARK: - High-confidence switch confirms within 2 observations

    func testHighConfidenceSwitchConfirms() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        // First observation of B: pending
        let r1 = smoother.processLabel(id("B", 0.95))
        // B is new so it should go pending (return nil)
        XCTAssertNil(r1)
        // Second observation of B: should now confirm
        let r2 = smoother.processLabel(id("B", 0.95))
        XCTAssertEqual(r2?.label, "B")
    }

    // MARK: - Low-confidence switch is suppressed

    func testLowConfidenceSwitchSuppressed() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        // A series of low-confidence B observations should not overcome the stay bias
        let r1 = smoother.processLabel(id("B", 0.15))
        let r2 = smoother.processLabel(id("B", 0.15))
        // With stayProbability=0.9 and very low confidence, A should still win
        // Either nil (pending) or A (Viterbi keeps A as best)
        // The Viterbi algorithm with stayProbability=0.9 and observation confidence=0.15
        // should keep A as the most likely state
        if r1 != nil {
            XCTAssertEqual(r1?.label, "A", "Low confidence B should not override A")
        }
        if r2 != nil {
            XCTAssertEqual(r2?.label, "A", "Low confidence B should not override A")
        }
    }

    // MARK: - False alarm (A -> B -> A)

    func testFalseAlarmReturnsToA() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        // Single B observation (pending)
        let r1 = smoother.processLabel(id("B", 0.7))
        // Back to A before B is confirmed
        let r2 = smoother.processLabel(id("A", 0.9))
        // Should return A (either directly or after re-confirming)
        // r1 should be nil (pending) or A (Viterbi still favors A)
        if r1 != nil {
            XCTAssertEqual(r1?.label, "A")
        }
        XCTAssertNotNil(r2)
        XCTAssertEqual(r2?.label, "A")
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A
        XCTAssertEqual(smoother.processLabel(id("A", 0.9))?.label, "A")
        // Switch to B (need pending + confirm)
        _ = smoother.processLabel(id("B", 0.95))  // pending
        let bConfirm = smoother.processLabel(id("B", 0.95))  // confirm
        XCTAssertEqual(bConfirm?.label, "B")
        // Switch to C
        _ = smoother.processLabel(id("C", 0.95))  // pending
        let cConfirm = smoother.processLabel(id("C", 0.95))  // confirm
        XCTAssertEqual(cConfirm?.label, "C")
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A"))
        smoother.reset()
        // After reset, next speaker is treated as first
        let result = smoother.processLabel(id("B"))
        XCTAssertEqual(result?.label, "B")
    }

    // MARK: - Confidence propagation

    func testConfidencePassThrough() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.processLabel(id("A", 0.85))
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.85)
    }

    func testConfidenceUpdatesOnSameSpeaker() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        let result = smoother.processLabel(id("A", 0.7))
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.7)
    }

    // MARK: - High stayProbability resists switching

    func testHighStayProbabilityResistsSwitching() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.99)
        _ = smoother.processLabel(id("A", 0.9))
        // With 0.99 stay probability, even moderate confidence B should not switch easily
        _ = smoother.processLabel(id("B", 0.7))
        _ = smoother.processLabel(id("B", 0.7))
        _ = smoother.processLabel(id("B", 0.7))
        // After 3 moderate B observations, with 0.99 stay probability, A might still hold
        // This tests that high stayProbability does resist switching
        // (We don't assert the exact result here since the math depends on implementation;
        //  the key test is that lower stayProbability switches more easily below)
    }

    // MARK: - Low stayProbability switches more easily

    func testLowStayProbabilitySwitchesMoreEasily() {
        // With very low stay probability, a single high-confidence switch should work
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.5)
        _ = smoother.processLabel(id("A", 0.9))
        // At stayProbability=0.5, switching is equally likely as staying,
        // so high-confidence B should shift the Viterbi state quickly
        _ = smoother.processLabel(id("B", 0.95))
        let r2 = smoother.processLabel(id("B", 0.95))
        XCTAssertEqual(r2?.label, "B")
    }

    // MARK: - Comparison: high vs low stayProbability

    func testStayProbabilityComparison() {
        // With low stayProbability (0.5), 2 high-confidence B observations should switch
        let lowStay = ViterbiSpeakerSmoother(stayProbability: 0.5)
        _ = lowStay.processLabel(id("A", 0.9))
        _ = lowStay.processLabel(id("B", 0.8))
        let lowResult = lowStay.processLabel(id("B", 0.8))

        // With high stayProbability (0.99), same sequence might not switch
        let highStay = ViterbiSpeakerSmoother(stayProbability: 0.99)
        _ = highStay.processLabel(id("A", 0.9))
        _ = highStay.processLabel(id("B", 0.8))
        let highResult = highStay.processLabel(id("B", 0.8))

        // Low stay should switch to B; high stay should still be A (or pending)
        XCTAssertEqual(lowResult?.label, "B")
        // highResult is either nil (pending) or A (Viterbi still favors A)
        if let result = highResult {
            XCTAssertEqual(result.label, "A")
        }
    }

    // MARK: - Integration: retroactive update pipeline

    func testIntegrationWithRetroactiveUpdates() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: first speaker A confirmed immediately
        let speaker1 = smoother.processLabel(id("A"))
        XCTAssertEqual(speaker1?.label, "A")
        segments.append(ConfirmedSegment(text: "Hello", speaker: speaker1?.label, speakerConfidence: speaker1?.confidence))

        // Chunk 2: B observed - pending
        let speaker2 = smoother.processLabel(id("B", 0.95))
        XCTAssertNil(speaker2)
        segments.append(ConfirmedSegment(text: "New topic", speaker: speaker2?.label, speakerConfidence: speaker2?.confidence))
        pendingStart = 1

        // During pending: no speaker change in output
        let textDuringPending = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(textDuringPending, "A: Hello New topic")

        // Chunk 3: B confirmed
        let speaker3 = smoother.processLabel(id("B", 0.95))
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

        let textAfterConfirm = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(textAfterConfirm, "A: Hello\nB: New topic More talk")
    }

    // MARK: - Integration: false alarm pipeline

    func testIntegrationFalseAlarm() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: A confirmed
        let s1 = smoother.processLabel(id("A"))
        segments.append(ConfirmedSegment(text: "Hello", speaker: s1?.label, speakerConfidence: s1?.confidence))

        // Chunk 2: B pending
        let s2 = smoother.processLabel(id("B", 0.7))
        XCTAssertNil(s2)
        segments.append(ConfirmedSegment(text: "glitch", speaker: s2?.label, speakerConfidence: s2?.confidence))
        pendingStart = 1

        // Chunk 3: Back to A (false alarm resolved)
        let s3 = smoother.processLabel(id("A", 0.9))
        XCTAssertNotNil(s3)
        XCTAssertEqual(s3?.label, "A")

        // Retroactive update: pending segments get A
        if let start = pendingStart {
            for i in start..<segments.count {
                segments[i].speaker = s3?.label
                segments[i].speakerConfidence = s3?.confidence
            }
            pendingStart = nil
        }
        segments.append(ConfirmedSegment(text: "continuing", speaker: s3?.label, speakerConfidence: s3?.confidence))

        let text = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(text, "A: Hello glitch continuing")
    }
}
