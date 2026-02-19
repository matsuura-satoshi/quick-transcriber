import Foundation
import Translation

@MainActor
public final class TranslationService: ObservableObject {
    @Published public var translatedSegments: [ConfirmedSegment] = []

    private var translationCursor: Int = 0
    private var session: TranslationSession?
    private var isTranslating: Bool = false

    public init() {}

    public func setSession(_ session: TranslationSession) {
        self.session = session
    }

    public func translateNewSegments(_ segments: [ConfirmedSegment]) async {
        guard translationCursor < segments.count else { return }
        guard let session else { return }
        guard !isTranslating else { return }

        isTranslating = true
        defer { isTranslating = false }

        let newSegments = Array(segments[translationCursor...])
        let startCursor = translationCursor

        do {
            let requests = newSegments.enumerated().map { index, segment in
                TranslationSession.Request(
                    sourceText: segment.text,
                    clientIdentifier: "\(startCursor + index)"
                )
            }

            let responses = try await session.translations(from: requests)

            for response in responses {
                guard let idStr = response.clientIdentifier,
                      let index = Int(idStr) else { continue }
                let sourceIndex = index - startCursor
                guard sourceIndex >= 0, sourceIndex < newSegments.count else { continue }

                let source = newSegments[sourceIndex]
                let translated = ConfirmedSegment(
                    text: response.targetText,
                    precedingSilence: source.precedingSilence,
                    speaker: source.speaker,
                    speakerConfidence: source.speakerConfidence,
                    isUserCorrected: source.isUserCorrected,
                    originalSpeaker: source.originalSpeaker,
                    speakerEmbedding: source.speakerEmbedding
                )

                let targetIndex = index
                if targetIndex < translatedSegments.count {
                    translatedSegments[targetIndex] = translated
                } else {
                    // Fill gaps if any
                    while translatedSegments.count < targetIndex {
                        translatedSegments.append(ConfirmedSegment(text: ""))
                    }
                    translatedSegments.append(translated)
                }
            }

            translationCursor = startCursor + newSegments.count
        } catch {
            NSLog("[QuickTranscriber] Translation error: \(error)")
        }
    }

    public func reset() {
        translatedSegments = []
        translationCursor = 0
        isTranslating = false
    }
}
