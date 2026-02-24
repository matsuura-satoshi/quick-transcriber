import Foundation
import Translation

struct TranslationGroup {
    var startIndex: Int
    var endIndex: Int
    var isFinalized: Bool
}

@MainActor
public final class TranslationService: ObservableObject {
    @Published public var translatedSegments: [ConfirmedSegment] = []
    @Published public var displaySegments: [ConfirmedSegment] = []

    var translationCursor: Int = 0
    var groups: [TranslationGroup] = []
    private var groupRetranslations: [Int: String] = [:]  // groupIndex -> retranslated text
    private var sourceLanguage: String = "en"

    public init() {}

    public func translateNewSegments(
        _ segments: [ConfirmedSegment],
        using session: TranslationSession,
        sourceLanguage: String = "en"
    ) async {
        self.sourceLanguage = sourceLanguage
        guard translationCursor < segments.count else { return }

        let newSegments = Array(segments[translationCursor...])
        let startCursor = translationCursor

        do {
            // Pass 1: translate new segments individually
            let requests = newSegments.enumerated().map { index, segment in
                TranslationSession.Request(
                    sourceText: segment.text,
                    clientIdentifier: "\(startCursor + index)"
                )
            }

            let responses = try await session.translations(from: requests)

            // Batch updates to avoid N separate @Published notifications
            var updated = translatedSegments
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
                if targetIndex < updated.count {
                    updated[targetIndex] = translated
                } else {
                    while updated.count < targetIndex {
                        updated.append(ConfirmedSegment(text: ""))
                    }
                    updated.append(translated)
                }
            }
            translatedSegments = updated

            translationCursor = startCursor + newSegments.count

            // Update groups with new segments
            for i in startCursor..<translationCursor {
                if Self.isGroupBoundary(segments: segments, at: i, sourceLanguage: sourceLanguage) {
                    // Finalize previous group
                    if !groups.isEmpty {
                        groups[groups.count - 1].isFinalized = true
                    }
                    // Start new group
                    groups.append(TranslationGroup(startIndex: i, endIndex: i, isFinalized: false))
                } else if groups.isEmpty {
                    groups.append(TranslationGroup(startIndex: i, endIndex: i, isFinalized: false))
                } else {
                    groups[groups.count - 1].endIndex = i
                }
            }

            // Pass 2: retranslate finalized multi-segment groups
            try await retranslateFinalized(segments: segments, using: session)

            rebuildDisplaySegments()
        } catch {
            NSLog("[QuickTranscriber] Translation error: \(error)")
        }
    }

    public func finalizeLastGroup(
        _ segments: [ConfirmedSegment], using session: TranslationSession
    ) async {
        guard !groups.isEmpty else { return }
        groups[groups.count - 1].isFinalized = true

        do {
            try await retranslateFinalized(segments: segments, using: session)
            rebuildDisplaySegments()
        } catch {
            NSLog("[QuickTranscriber] Finalize translation error: \(error)")
        }
    }

    private func retranslateFinalized(
        segments: [ConfirmedSegment], using session: TranslationSession
    ) async throws {
        var requests: [(groupIndex: Int, request: TranslationSession.Request)] = []

        for (groupIdx, group) in groups.enumerated() {
            guard group.isFinalized,
                  group.endIndex > group.startIndex,
                  groupRetranslations[groupIdx] == nil else { continue }

            let groupText = segments[group.startIndex...group.endIndex]
                .map(\.text)
                .joined()
            requests.append((
                groupIndex: groupIdx,
                request: TranslationSession.Request(
                    sourceText: groupText,
                    clientIdentifier: "group_\(groupIdx)"
                )
            ))
        }

        guard !requests.isEmpty else { return }

        let responses = try await session.translations(
            from: requests.map(\.request)
        )

        for response in responses {
            guard let id = response.clientIdentifier,
                  id.hasPrefix("group_"),
                  let groupIdx = Int(id.dropFirst(6)) else { continue }
            groupRetranslations[groupIdx] = response.targetText
        }
    }

    // MARK: - Split segment

    /// Split the translated segment at the given index to maintain 1:1 index
    /// correspondence with confirmedSegments after a split.
    public func splitSegment(at index: Int) {
        guard index < translatedSegments.count else { return }

        var second = translatedSegments[index]
        second.text = ""
        second.precedingSilence = 0

        var updated = translatedSegments
        updated.insert(second, at: index + 1)
        translatedSegments = updated

        if translationCursor > index {
            translationCursor += 1
        }

        for i in 0..<groups.count {
            if groups[i].startIndex > index {
                groups[i].startIndex += 1
                groups[i].endIndex += 1
            } else if groups[i].endIndex >= index {
                groups[i].endIndex += 1
            }
        }

        rebuildDisplaySegments()
    }

    // MARK: - Group boundary detection

    public static func isGroupBoundary(
        segments: [ConfirmedSegment], at index: Int, sourceLanguage: String
    ) -> Bool {
        guard index > 0, index < segments.count else { return false }

        let prev = segments[index - 1]
        let current = segments[index]

        // 1. Previous segment ends with sentence-ending punctuation
        let enders = sourceLanguage == "ja"
            ? Constants.Translation.sentenceEndersJA
            : Constants.Translation.sentenceEndersEN
        if let lastChar = prev.text.last(where: { !$0.isWhitespace }),
           enders.contains(lastChar) {
            return true
        }

        // 2. Speaker change (both non-nil, different)
        if let prevSpeaker = prev.speaker, let curSpeaker = current.speaker,
           prevSpeaker != curSpeaker {
            return true
        }

        // 2b. nil → non-nil transition (pending segment resolved)
        if prev.speaker == nil && current.speaker != nil {
            return true
        }

        // 3. Long silence
        if current.precedingSilence > Constants.Translation.groupBoundarySilence {
            return true
        }

        return false
    }

    // MARK: - Display segments

    public func rebuildDisplaySegments() {
        var display = translatedSegments

        for (groupIdx, group) in groups.enumerated() {
            guard let retranslation = groupRetranslations[groupIdx],
                  group.startIndex < display.count else { continue }

            // First segment gets the retranslated text, preserving metadata from translatedSegments
            display[group.startIndex].text = retranslation

            // Remaining segments in group get empty text (skipped by buildAttributedString)
            let end = min(group.endIndex, display.count - 1)
            for i in (group.startIndex + 1)...end {
                display[i].text = ""
            }
        }

        displaySegments = display
    }

    /// Apply a group retranslation for testing purposes.
    public func applyGroupRetranslation(
        groupStartIndex: Int, groupEndIndex: Int, translatedText: String
    ) {
        let groupIdx = groups.count
        groups.append(TranslationGroup(
            startIndex: groupStartIndex, endIndex: groupEndIndex, isFinalized: true
        ))
        groupRetranslations[groupIdx] = translatedText
        rebuildDisplaySegments()
    }

    // MARK: - Speaker metadata sync

    public func syncSpeakerMetadata(from source: [ConfirmedSegment]) {
        let count = min(translatedSegments.count, source.count)
        guard count > 0 else { return }
        var updated = translatedSegments
        for i in 0..<count {
            updated[i].speaker = source[i].speaker
            updated[i].speakerConfidence = source[i].speakerConfidence
            updated[i].isUserCorrected = source[i].isUserCorrected
            updated[i].originalSpeaker = source[i].originalSpeaker
        }
        translatedSegments = updated
        rebuildDisplaySegments()
    }

    public func reset() {
        translatedSegments = []
        displaySegments = []
        translationCursor = 0
        groups = []
        groupRetranslations = [:]
        sourceLanguage = "en"
    }
}
