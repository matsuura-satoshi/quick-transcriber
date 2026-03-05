import XCTest
@testable import QuickTranscriberLib

final class ViterbiSpeakerSmootherTests: XCTestCase {

    // MARK: - Helper

    // Fixed UUIDs for test speakers
    private let speakerA = UUID()
    private let speakerB = UUID()
    private let speakerC = UUID()

    private func id(_ speakerId: UUID, _ confidence: Float = 0.9) -> SpeakerIdentification {
        SpeakerIdentification(speakerId: speakerId, confidence: confidence)
    }

    // MARK: - First speaker confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.process(id(speakerA))
        XCTAssertEqual(result?.speakerId, speakerA)
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA))
        let result = smoother.process(id(speakerA))
        XCTAssertEqual(result?.speakerId, speakerA)
    }

    // MARK: - Nil input

    func testNilInputReturnsConfirmed() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA))
        let result = smoother.process(nil)
        XCTAssertEqual(result?.speakerId, speakerA)
    }

    func testNilInputWithNoConfirmedReturnsNil() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.process(nil)
        XCTAssertNil(result)
    }

    // MARK: - High-confidence switch confirms within 2 observations

    func testHighConfidenceSwitchConfirms() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // First observation of B: pending
        let r1 = smoother.process(id(speakerB, 0.95))
        // B is new so it should go pending (return nil)
        XCTAssertNil(r1)
        // Second observation of B: should now confirm
        let r2 = smoother.process(id(speakerB, 0.95))
        XCTAssertEqual(r2?.speakerId, speakerB)
    }

    // MARK: - Low-confidence switch is suppressed

    func testLowConfidenceSwitchSuppressed() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // A series of low-confidence B observations should not overcome the stay bias
        let r1 = smoother.process(id(speakerB, 0.15))
        let r2 = smoother.process(id(speakerB, 0.15))
        // With stayProbability=0.9 and very low confidence, A should still win
        // Either nil (pending) or A (Viterbi keeps A as best)
        if r1 != nil {
            XCTAssertEqual(r1?.speakerId, speakerA, "Low confidence B should not override A")
        }
        if r2 != nil {
            XCTAssertEqual(r2?.speakerId, speakerA, "Low confidence B should not override A")
        }
    }

    // MARK: - False alarm (A -> B -> A)

    func testFalseAlarmReturnsToA() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // Single B observation (pending)
        let r1 = smoother.process(id(speakerB, 0.7))
        // Back to A before B is confirmed
        let r2 = smoother.process(id(speakerA, 0.9))
        // Should return A (either directly or after re-confirming)
        if r1 != nil {
            XCTAssertEqual(r1?.speakerId, speakerA)
        }
        XCTAssertNotNil(r2)
        XCTAssertEqual(r2?.speakerId, speakerA)
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A
        XCTAssertEqual(smoother.process(id(speakerA, 0.9))?.speakerId, speakerA)
        // Switch to B (need pending + confirm)
        _ = smoother.process(id(speakerB, 0.95))  // pending
        let bConfirm = smoother.process(id(speakerB, 0.95))  // confirm
        XCTAssertEqual(bConfirm?.speakerId, speakerB)
        // Switch to C
        _ = smoother.process(id(speakerC, 0.95))  // pending
        let cConfirm = smoother.process(id(speakerC, 0.95))  // confirm
        XCTAssertEqual(cConfirm?.speakerId, speakerC)
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA))
        smoother.reset()
        // After reset, next speaker is treated as first
        let result = smoother.process(id(speakerB))
        XCTAssertEqual(result?.speakerId, speakerB)
    }

    // MARK: - Confidence propagation

    func testConfidencePassThrough() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let result = smoother.process(id(speakerA, 0.85))
        XCTAssertEqual(result?.speakerId, speakerA)
        XCTAssertEqual(result?.confidence, 0.85)
    }

    func testConfidenceUpdatesOnSameSpeaker() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        let result = smoother.process(id(speakerA, 0.7))
        XCTAssertEqual(result?.speakerId, speakerA)
        XCTAssertEqual(result?.confidence, 0.7)
    }

    // MARK: - High stayProbability resists switching

    func testHighStayProbabilityResistsSwitching() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.99)
        _ = smoother.process(id(speakerA, 0.9))
        // With 0.99 stay probability, even moderate confidence B should not switch easily
        _ = smoother.process(id(speakerB, 0.7))
        _ = smoother.process(id(speakerB, 0.7))
        _ = smoother.process(id(speakerB, 0.7))
        // After 3 moderate B observations, with 0.99 stay probability, A should still hold
        let result = smoother.process(id(speakerB, 0.7))
        XCTAssertTrue(result == nil || result?.speakerId == speakerA,
            "High stay probability (0.99) should resist switching on moderate-confidence observations")
    }

    // MARK: - Low stayProbability switches more easily

    func testLowStayProbabilitySwitchesMoreEasily() {
        // With very low stay probability, a single high-confidence switch should work
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.5)
        _ = smoother.process(id(speakerA, 0.9))
        // At stayProbability=0.5, switching is equally likely as staying,
        // so high-confidence B should shift the Viterbi state quickly
        _ = smoother.process(id(speakerB, 0.95))
        let r2 = smoother.process(id(speakerB, 0.95))
        XCTAssertEqual(r2?.speakerId, speakerB)
    }

    // MARK: - Comparison: high vs low stayProbability

    func testStayProbabilityComparison() {
        // With low stayProbability (0.5), 2 high-confidence B observations should switch
        let lowStay = ViterbiSpeakerSmoother(stayProbability: 0.5)
        _ = lowStay.process(id(speakerA, 0.9))
        _ = lowStay.process(id(speakerB, 0.8))
        let lowResult = lowStay.process(id(speakerB, 0.8))

        // With high stayProbability (0.99), same sequence might not switch
        let highStay = ViterbiSpeakerSmoother(stayProbability: 0.99)
        _ = highStay.process(id(speakerA, 0.9))
        _ = highStay.process(id(speakerB, 0.8))
        let highResult = highStay.process(id(speakerB, 0.8))

        // Low stay should switch to B; high stay should still be A (or pending)
        XCTAssertEqual(lowResult?.speakerId, speakerB)
        // highResult is either nil (pending) or A (Viterbi still favors A)
        if let result = highResult {
            XCTAssertEqual(result.speakerId, speakerA)
        }
    }

    // MARK: - Integration: retroactive update pipeline

    func testIntegrationWithRetroactiveUpdates() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: first speaker A confirmed immediately
        let speaker1 = smoother.process(id(speakerA))
        XCTAssertEqual(speaker1?.speakerId, speakerA)
        segments.append(ConfirmedSegment(text: "Hello", speaker: speaker1?.speakerId.uuidString, speakerConfidence: speaker1?.confidence))

        // Chunk 2: B observed - pending
        let speaker2 = smoother.process(id(speakerB, 0.95))
        XCTAssertNil(speaker2)
        segments.append(ConfirmedSegment(text: "New topic", speaker: speaker2?.speakerId.uuidString, speakerConfidence: speaker2?.confidence))
        pendingStart = 1

        // During pending: no speaker change in output
        let textDuringPending = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertTrue(textDuringPending.hasSuffix("Hello New topic"))

        // Chunk 3: B confirmed
        let speaker3 = smoother.process(id(speakerB, 0.95))
        XCTAssertEqual(speaker3?.speakerId, speakerB)

        // Retroactive update
        if let start = pendingStart {
            for i in start..<segments.count {
                segments[i].speaker = speaker3?.speakerId.uuidString
                segments[i].speakerConfidence = speaker3?.confidence
            }
            pendingStart = nil
        }
        segments.append(ConfirmedSegment(text: "More talk", speaker: speaker3?.speakerId.uuidString, speakerConfidence: speaker3?.confidence))

        let textAfterConfirm = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        // With UUID-based speakers, check structure rather than exact labels
        XCTAssertTrue(textAfterConfirm.contains("Hello"))
        XCTAssertTrue(textAfterConfirm.contains("New topic"))
        XCTAssertTrue(textAfterConfirm.contains("More talk"))
    }

    // MARK: - Empty state safety (S-1: force unwrap removal)

    func testProcessAfterResetDoesNotCrash() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA))
        _ = smoother.process(id(speakerB, 0.8))
        smoother.reset()
        // After reset, should handle new input safely
        let result = smoother.process(id(speakerC))
        XCTAssertEqual(result?.speakerId, speakerC)
    }

    func testProcessWithVeryLowConfidence() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confidence at minimum clamp boundary (0.01)
        let result = smoother.process(SpeakerIdentification(speakerId: speakerA, confidence: 0.001))
        XCTAssertEqual(result?.speakerId, speakerA)
    }

    func testProcessWithVeryHighConfidence() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confidence at maximum clamp boundary (0.99)
        let result = smoother.process(SpeakerIdentification(speakerId: speakerA, confidence: 1.0))
        XCTAssertEqual(result?.speakerId, speakerA)
    }

    func testRapidSpeakerAlternation() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA))
        // Rapid alternation should not crash
        for _ in 0..<20 {
            _ = smoother.process(id(speakerB, 0.5))
            _ = smoother.process(id(speakerA, 0.5))
        }
        let result = smoother.process(id(speakerA, 0.9))
        XCTAssertNotNil(result)
    }

    // MARK: - resetForSpeakerChange

    func testResetForSpeakerChangeConfirmsImmediately() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerA, 0.9))
        // Reset for speaker change (silence detected)
        smoother.resetForSpeakerChange()
        // B should be confirmed immediately (no pending required)
        let result = smoother.process(id(speakerB, 0.9))
        XCTAssertEqual(result?.speakerId, speakerB, "After resetForSpeakerChange, new speaker should confirm immediately")
    }

    func testResetForSpeakerChangePreservesKnownSpeakers() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A, then switch to B
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerB, 0.95))
        _ = smoother.process(id(speakerB, 0.95))
        // Reset for speaker change
        smoother.resetForSpeakerChange()
        // A observation should confirm immediately (A is a known speaker)
        let result = smoother.process(id(speakerA, 0.9))
        XCTAssertEqual(result?.speakerId, speakerA, "After resetForSpeakerChange, known speaker should confirm immediately")
    }

    func testResetForSpeakerChangePreservesConfirmedForNilInput() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A
        _ = smoother.process(id(speakerA, 0.9))
        // Reset for speaker change
        smoother.resetForSpeakerChange()
        // nil input should still return last confirmed (A)
        let result = smoother.process(nil)
        XCTAssertEqual(result?.speakerId, speakerA, "After resetForSpeakerChange, nil input should return last confirmed speaker")
    }

    func testResetForSpeakerChangeThenSameSpeakerResumes() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Confirm A
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerA, 0.9))
        // Reset for speaker change (silence detected)
        smoother.resetForSpeakerChange()
        // Same speaker A returns - should confirm immediately
        let result = smoother.process(id(speakerA, 0.9))
        XCTAssertEqual(result?.speakerId, speakerA, "After resetForSpeakerChange, same speaker resuming should confirm immediately")
    }

    func testManySpeakers() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        // Register many speakers — should not crash due to state complexity
        let speakers = (0..<10).map { _ in UUID() }
        _ = smoother.process(id(speakers[0]))
        for i in 1..<10 {
            _ = smoother.process(id(speakers[i], 0.95))
            _ = smoother.process(id(speakers[i], 0.95))
            _ = smoother.process(id(speakers[i], 0.95))
        }
        // Returning to first speaker may require confirmation steps with many speakers
        _ = smoother.process(id(speakers[0], 0.95))
        _ = smoother.process(id(speakers[0], 0.95))
        let result = smoother.process(id(speakers[0], 0.95))
        // Either confirmed back to first speaker or still pending — no crash is the key assertion
        if let result {
            XCTAssertEqual(result.speakerId, speakers[0])
        }
    }

    // MARK: - Integration: false alarm pipeline

    func testIntegrationFalseAlarm() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        var segments: [ConfirmedSegment] = []

        // Chunk 1: A confirmed
        let s1 = smoother.process(id(speakerA))
        segments.append(ConfirmedSegment(text: "Hello", speaker: s1?.speakerId.uuidString, speakerConfidence: s1?.confidence))

        // Chunk 2: B observed with moderate confidence (0.7)
        let s2 = smoother.process(id(speakerB, 0.7))
        XCTAssertNotNil(s2, "Viterbi should keep A as best speaker for single B(0.7) observation")
        XCTAssertEqual(s2?.speakerId, speakerA)
        segments.append(ConfirmedSegment(text: "glitch", speaker: s2?.speakerId.uuidString, speakerConfidence: s2?.confidence))

        // Chunk 3: Back to A (reinforces A)
        let s3 = smoother.process(id(speakerA, 0.9))
        XCTAssertNotNil(s3)
        XCTAssertEqual(s3?.speakerId, speakerA)
        segments.append(ConfirmedSegment(text: "continuing", speaker: s3?.speakerId.uuidString, speakerConfidence: s3?.confidence))

        let text = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertTrue(text.contains("Hello glitch continuing"))
    }

    // MARK: - remapSpeaker

    func testRemapSpeaker_mergesLogProbabilities() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let spkA = UUID()
        let spkB = UUID()

        let idA = SpeakerIdentification(speakerId: spkA, confidence: 0.8, embedding: [])
        let idB = SpeakerIdentification(speakerId: spkB, confidence: 0.9, embedding: [])
        _ = smoother.process(idA)
        _ = smoother.process(idB)
        _ = smoother.process(idB)  // speakerB confirmed

        // Remap speakerB → speakerA
        smoother.remapSpeaker(from: spkB, to: spkA)

        // speakerB's state should be gone; speakerA should work normally
        let result = smoother.process(idA)
        XCTAssertEqual(result?.speakerId, spkA)
    }

    func testRemapSpeaker_unknownSourceIsNoOp() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let spkA = UUID()
        let unknownId = UUID()

        let idA = SpeakerIdentification(speakerId: spkA, confidence: 0.8, embedding: [])
        _ = smoother.process(idA)

        // Remap unknown UUID → no-op
        smoother.remapSpeaker(from: unknownId, to: spkA)

        let result = smoother.process(idA)
        XCTAssertEqual(result?.speakerId, spkA)
    }

    // MARK: - confirmSpeaker (user correction)

    func testConfirmSpeaker_setsConfirmedToTarget() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // User corrects to speakerB
        smoother.confirmSpeaker(speakerB)
        // nil input should return speakerB as confirmed
        let result = smoother.process(nil)
        XCTAssertEqual(result?.speakerId, speakerB)
    }

    func testConfirmSpeaker_subsequentSameSpeakerContinues() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerA, 0.9))
        // User corrects to speakerB
        smoother.confirmSpeaker(speakerB)
        // Next observation of B should continue as B (not flip back to A)
        let result = smoother.process(id(speakerB, 0.7))
        XCTAssertEqual(result?.speakerId, speakerB)
    }

    func testConfirmSpeaker_resistsSwitchBackToOldSpeaker() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerA, 0.9))
        _ = smoother.process(id(speakerA, 0.9))
        // User corrects to speakerB
        smoother.confirmSpeaker(speakerB)
        // Single A observation should NOT flip back (stayProbability keeps B)
        let r1 = smoother.process(id(speakerA, 0.7))
        // Should be B still (or pending/nil, but not confirmed A)
        if let r1 {
            XCTAssertEqual(r1.speakerId, speakerB,
                "After confirmSpeaker(B), single A observation should not override")
        }
    }

    func testConfirmSpeaker_clearsPendingState() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // Start a pending switch to B
        _ = smoother.process(id(speakerB, 0.95))
        // User corrects to speakerC while pending
        smoother.confirmSpeaker(speakerC)
        // Next observation of C should return C (not be affected by old pending B)
        let result = smoother.process(id(speakerC, 0.8))
        XCTAssertEqual(result?.speakerId, speakerC)
    }

    func testConfirmSpeaker_allowsNaturalSwitchAfter() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.process(id(speakerA, 0.9))
        // User corrects to speakerB
        smoother.confirmSpeaker(speakerB)
        // Two high-confidence A observations should eventually switch to A
        _ = smoother.process(id(speakerA, 0.95))  // pending
        let r2 = smoother.process(id(speakerA, 0.95))  // confirm
        XCTAssertEqual(r2?.speakerId, speakerA,
            "Natural speaker switch should still work after confirmSpeaker")
    }

    func testRemapSpeaker_updatesConfirmedSpeaker() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        let spkA = UUID()
        let spkB = UUID()

        // Confirm speakerB
        let idB = SpeakerIdentification(speakerId: spkB, confidence: 0.9, embedding: [1.0])
        _ = smoother.process(idB)

        // Remap speakerB → speakerA: confirmed should also update
        smoother.remapSpeaker(from: spkB, to: spkA)

        // nil input returns confirmed → should be speakerA now
        let result = smoother.process(nil)
        XCTAssertEqual(result?.speakerId, spkA)
    }
}
