import XCTest
@testable import QuickTranscriberLib

final class SpeakerLabelTrackerTests: XCTestCase {

    // MARK: - First speaker is confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel("A")
        XCTAssertEqual(result, "A")
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel("A")
        XCTAssertEqual(result, "A")
    }

    // MARK: - Single different label returns nil (pending)

    func testSingleDifferentLabelReturnsPending() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel("B")  // only 1 B, need 2
        XCTAssertNil(result)
    }

    // MARK: - Threshold reached confirms new speaker

    func testThresholdReachedConfirmsNewSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        _ = tracker.processLabel("B")  // pending (1/2)
        let result = tracker.processLabel("B")  // confirmed (2/2)
        XCTAssertEqual(result, "B")
    }

    // MARK: - False alarm: different then back to original

    func testFalseAlarmReturnsToOriginal() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")     // confirm A
        _ = tracker.processLabel("B")     // pending
        let result = tracker.processLabel("A")  // back to A
        XCTAssertEqual(result, "A")
    }

    // MARK: - Nil label returns current confirmed speaker

    func testNilLabelReturnsConfirmedSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel(nil)
        XCTAssertEqual(result, "A")
    }

    func testNilLabelWithNoConfirmedSpeakerReturnsNil() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel(nil)
        XCTAssertNil(result)
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        XCTAssertEqual(tracker.processLabel("A"), "A")   // confirm A
        XCTAssertNil(tracker.processLabel("B"))           // pending
        XCTAssertEqual(tracker.processLabel("B"), "B")    // confirm B
        XCTAssertNil(tracker.processLabel("A"))           // pending
        XCTAssertEqual(tracker.processLabel("A"), "A")    // confirm A
    }

    // MARK: - Threshold of 3

    func testHigherThreshold() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertNil(tracker.processLabel("B"))   // 1/3
        XCTAssertNil(tracker.processLabel("B"))   // 2/3
        XCTAssertEqual(tracker.processLabel("B"), "B")  // 3/3 confirmed
    }

    // MARK: - Interrupted pending resets count

    func testInterruptedPendingResetsCount() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertNil(tracker.processLabel("B"))   // 1/3
        XCTAssertNil(tracker.processLabel("C"))   // C resets B count, 1/3 for C
        XCTAssertNil(tracker.processLabel("C"))   // 2/3 for C
        XCTAssertEqual(tracker.processLabel("C"), "C")  // 3/3 confirmed
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")
        tracker.reset()
        // After reset, next label is "first speaker" again
        XCTAssertEqual(tracker.processLabel("B"), "B")
    }

    // MARK: - Threshold of 1 (immediate change)

    func testThresholdOneConfirmsImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 1)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertEqual(tracker.processLabel("B"), "B")  // immediate change
    }
}
