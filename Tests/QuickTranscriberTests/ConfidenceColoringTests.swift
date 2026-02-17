import XCTest
@testable import QuickTranscriberLib

final class ConfidenceColoringTests: XCTestCase {

    // MARK: - TranscriptionState confirmedSegments

    func testTranscriptionStateDefaultSegmentsEmpty() {
        let state = TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "",
            isRecording: true
        )
        XCTAssertTrue(state.confirmedSegments.isEmpty)
    }

    func testTranscriptionStateWithSegments() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.3),
        ]
        let state = TranscriptionState(
            confirmedText: "A: Hello\nB: World",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: segments
        )
        XCTAssertEqual(state.confirmedSegments.count, 2)
        XCTAssertEqual(state.confirmedSegments[0].speaker, "A")
        XCTAssertEqual(state.confirmedSegments[1].speakerConfidence, 0.3)
    }

    // MARK: - buildAttributedStringFromSegments

    func testBuildAttributedStringEmptySegments() {
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            [],
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.length, 0)
    }

    func testBuildAttributedStringEmptySegmentsWithUnconfirmed() {
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            [],
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: "thinking..."
        )
        XCTAssertEqual(result.string, "thinking...")
    }

    func testBuildAttributedStringSingleSegmentNoSpeaker() {
        let segments = [ConfirmedSegment(text: "Hello world")]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "Hello world")
    }

    func testBuildAttributedStringSingleSegmentWithSpeaker() {
        let segments = [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8)]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "A: Hello")
    }

    func testBuildAttributedStringSpeakerChange() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.9),
            ConfirmedSegment(text: "Hi there", speaker: "B", speakerConfidence: 0.7),
        ]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "A: Hello\nB: Hi there")
    }

    func testBuildAttributedStringSilenceBreak() {
        let segments = [
            ConfirmedSegment(text: "Before pause"),
            ConfirmedSegment(text: "After pause", precedingSilence: 2.0),
        ]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "Before pause\nAfter pause")
    }

    func testBuildAttributedStringSentenceEndBreak() {
        let segments = [
            ConfirmedSegment(text: "Hello."),
            ConfirmedSegment(text: "World"),
        ]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "Hello.\nWorld")
    }

    func testBuildAttributedStringInlineJoin() {
        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "world"),
        ]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "Hello world")
    }

    func testBuildAttributedStringJapaneseInlineJoinNoSpace() {
        let segments = [
            ConfirmedSegment(text: "こんにちは"),
            ConfirmedSegment(text: "世界"),
        ]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "ja",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        XCTAssertEqual(result.string, "こんにちは世界")
    }

    func testBuildAttributedStringWithUnconfirmedAppended() {
        let segments = [ConfirmedSegment(text: "Hello")]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: "thinking..."
        )
        XCTAssertEqual(result.string, "Hello\nthinking...")
    }

    // MARK: - Speaker label confidence coloring

    func testHighConfidenceSpeakerLabelUsesLabelColor() {
        let segments = [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8)]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        // "A: Hello" — check attributes of "A: " (range 0..<3)
        var range = NSRange(location: 0, length: 0)
        let attrs = result.attributes(at: 0, effectiveRange: &range)
        let color = attrs[.foregroundColor] as? NSColor
        XCTAssertEqual(color, NSColor.labelColor, "High confidence speaker label should use labelColor")
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                      "Speaker label should be bold")
    }

    func testLowConfidenceSpeakerLabelUsesSecondaryColor() {
        let segments = [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.3)]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        // "A: Hello" — check attributes of "A: " (range 0..<3)
        var range = NSRange(location: 0, length: 0)
        let attrs = result.attributes(at: 0, effectiveRange: &range)
        let color = attrs[.foregroundColor] as? NSColor
        XCTAssertEqual(color, NSColor.secondaryLabelColor,
                       "Low confidence speaker label should use secondaryLabelColor")
    }

    func testNilConfidenceSpeakerLabelUsesLabelColor() {
        let segments = [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: nil)]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        var range = NSRange(location: 0, length: 0)
        let attrs = result.attributes(at: 0, effectiveRange: &range)
        let color = attrs[.foregroundColor] as? NSColor
        XCTAssertEqual(color, NSColor.labelColor,
                       "Nil confidence speaker label should use labelColor (treat as high)")
    }

    func testTextBodyAlwaysUsesLabelColor() {
        let segments = [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.3)]
        let result = TranscriptionTextView.buildAttributedStringFromSegments(
            segments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15,
            unconfirmed: ""
        )
        // "A: Hello" — text body starts at index 3 ("Hello")
        var range = NSRange(location: 0, length: 0)
        let attrs = result.attributes(at: 3, effectiveRange: &range)
        let color = attrs[.foregroundColor] as? NSColor
        XCTAssertEqual(color, NSColor.labelColor,
                       "Text body should always use labelColor regardless of speaker confidence")
    }

    // MARK: - TranscriptionViewModel

    @MainActor
    func testViewModelExposesConfirmedSegments() async {
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")
        await vm.loadModel()

        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.9)
        ]
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "A: Hello",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: segments
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedSegments.count, 1)
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "A")
        XCTAssertEqual(vm.confirmedSegments[0].speakerConfidence, 0.9)
    }

    @MainActor
    func testViewModelExposeSilenceLineBreakThreshold() {
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")
        // Default silenceLineBreakThreshold should be accessible
        let threshold = vm.silenceLineBreakThreshold
        XCTAssertGreaterThan(threshold, 0)
    }

    // MARK: - Selection preservation on segment updates

    func testSegmentAppendPreservesSelection() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.textView = textView

        // Initial segments
        let segments1 = [
            ConfirmedSegment(text: "Hello world", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
        ]
        coordinator.applySegmentUpdate(
            segments: segments1, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: ""
        )
        // "A: Hello world" → select "Hello" (position 3, length 5)
        textView.setSelectedRange(NSRange(location: 3, length: 5))

        // New segment appended
        let segments2 = segments1 + [
            ConfirmedSegment(text: "How are you", precedingSilence: 0.5),
        ]
        coordinator.applySegmentUpdate(
            segments: segments2, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: ""
        )

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 5),
                       "Selection should be preserved when segments are appended")
    }

    func testSegmentFullRebuildPreservesSelection() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.textView = textView

        let segments = [
            ConfirmedSegment(text: "Hello world", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
        ]
        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: ""
        )
        textView.setSelectedRange(NSRange(location: 3, length: 5))

        // Unconfirmed text change triggers full rebuild
        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "typing...", oldFontSize: 15, oldUnconfirmed: ""
        )

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 5),
                       "Selection should be preserved during full rebuild with unconfirmed text")
    }

    // MARK: - ChunkedWhisperEngine emits segments

    func testEngineEmitsConfirmedSegments() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Hello", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "State with segments")
        var lastState: TranscriptionState?

        try await engine.startStreaming(language: "en") { state in
            if !state.confirmedText.isEmpty {
                lastState = state
                expectation.fulfill()
            }
        }

        // Feed 5 seconds of audio to trigger chunk
        let speechBuffer = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speechBuffer)

        await fulfillment(of: [expectation], timeout: 6.0)

        XCTAssertEqual(lastState?.confirmedSegments.count, 1)
        XCTAssertEqual(lastState?.confirmedSegments.first?.text, "Hello")

        await engine.stopStreaming()
    }
}
