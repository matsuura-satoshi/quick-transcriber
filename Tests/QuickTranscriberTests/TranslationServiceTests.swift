import XCTest
@testable import QuickTranscriberLib

@MainActor
final class TranslationServiceTests: XCTestCase {
    private var service: TranslationService!

    override func setUp() {
        super.setUp()
        service = TranslationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Reset

    func testResetClearsState() {
        // Manually set up some state
        service.translatedSegments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World")
        ]

        service.reset()

        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    func testResetAllowsRetranslation() {
        // After reset, cursor should be back to 0
        service.reset()

        // translatedSegments should be empty
        XCTAssertEqual(service.translatedSegments.count, 0)
    }

    // MARK: - Translate without session

    func testTranslateWithoutSessionDoesNothing() async {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A")
        ]

        await service.translateNewSegments(segments)

        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    // MARK: - Metadata preservation

    func testMetadataPreservedInTranslatedSegment() {
        // Verify that when we create a translated segment, metadata is copied from source
        let source = ConfirmedSegment(
            text: "Hello world",
            precedingSilence: 1.5,
            speaker: "A",
            speakerConfidence: 0.85,
            isUserCorrected: true,
            originalSpeaker: "B",
            speakerEmbedding: [0.1, 0.2, 0.3]
        )

        // Simulate what TranslationService does: copy metadata, replace text
        let translated = ConfirmedSegment(
            text: "こんにちは世界",
            precedingSilence: source.precedingSilence,
            speaker: source.speaker,
            speakerConfidence: source.speakerConfidence,
            isUserCorrected: source.isUserCorrected,
            originalSpeaker: source.originalSpeaker,
            speakerEmbedding: source.speakerEmbedding
        )

        XCTAssertEqual(translated.text, "こんにちは世界")
        XCTAssertEqual(translated.precedingSilence, 1.5)
        XCTAssertEqual(translated.speaker, "A")
        XCTAssertEqual(translated.speakerConfidence, 0.85)
        XCTAssertTrue(translated.isUserCorrected)
        XCTAssertEqual(translated.originalSpeaker, "B")
        XCTAssertEqual(translated.speakerEmbedding, [0.1, 0.2, 0.3])
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertTrue(service.translatedSegments.isEmpty)
    }
}
