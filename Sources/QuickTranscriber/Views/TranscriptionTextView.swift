import SwiftUI
import AppKit

struct TranscriptionTextView: NSViewRepresentable {
    let confirmedText: String
    let unconfirmedText: String
    let fontSize: CGFloat
    let confirmedSegments: [ConfirmedSegment]
    var language: String = "en"
    var silenceThreshold: TimeInterval = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let newConfirmed = confirmedText
        let newUnconfirmed = unconfirmedText
        let oldConfirmed = coordinator.lastConfirmedText
        let oldUnconfirmed = coordinator.lastUnconfirmedText
        let oldFontSize = coordinator.lastFontSize

        guard newConfirmed != oldConfirmed
            || newUnconfirmed != oldUnconfirmed
            || fontSize != oldFontSize else {
            return
        }

        coordinator.lastConfirmedText = newConfirmed
        coordinator.lastUnconfirmedText = newUnconfirmed
        coordinator.lastFontSize = fontSize

        guard let textView = coordinator.textView,
              let textStorage = textView.textStorage else { return }

        let isAtBottom = coordinator.isScrolledToBottom()

        let hasSpeakerConfidence = confirmedSegments.contains { $0.speakerConfidence != nil }

        if hasSpeakerConfidence {
            // Use segment-based rendering for confidence coloring
            let attributed = Self.buildAttributedStringFromSegments(
                confirmedSegments,
                language: language,
                silenceThreshold: silenceThreshold,
                fontSize: fontSize,
                unconfirmed: newUnconfirmed
            )
            textStorage.setAttributedString(attributed)
        } else {
            // No confidence data: use efficient diff-append path
            let canDiffAppend = fontSize == oldFontSize
                && newUnconfirmed.isEmpty
                && oldUnconfirmed.isEmpty
                && newConfirmed.hasPrefix(oldConfirmed)
                && newConfirmed != oldConfirmed

            if canDiffAppend {
                let delta = String(newConfirmed.dropFirst(oldConfirmed.count))
                let attrs = Self.confirmedAttributes(fontSize: fontSize)
                textStorage.append(NSAttributedString(string: delta, attributes: attrs))
            } else {
                let attributed = Self.buildAttributedString(
                    confirmed: newConfirmed,
                    unconfirmed: newUnconfirmed,
                    fontSize: fontSize
                )
                textStorage.setAttributedString(attributed)
            }
        }

        if isAtBottom {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: - Attributed String Building

    static func makeParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 4
        return paragraphStyle
    }

    static func confirmedAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: makeParagraphStyle()
        ]
    }

    private static func buildAttributedString(
        confirmed: String,
        unconfirmed: String,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if !confirmed.isEmpty {
            result.append(NSAttributedString(string: confirmed, attributes: confirmedAttributes(fontSize: fontSize)))
        }

        if !unconfirmed.isEmpty {
            if !confirmed.isEmpty {
                let newline = NSAttributedString(string: "\n")
                result.append(newline)
            }
            result.append(buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize))
        }

        return result
    }

    // MARK: - Segment-Based Rendering

    private static let lowConfidenceThreshold: Float = 0.5

    /// Build an NSAttributedString from segments, coloring speaker labels by confidence.
    /// Mirrors the logic of TranscriptionUtils.joinSegments but produces attributed text.
    static func buildAttributedStringFromSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        fontSize: CGFloat,
        unconfirmed: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !segments.isEmpty else {
            if !unconfirmed.isEmpty {
                return buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize)
            }
            return result
        }

        let hasSpeakers = segments.contains { $0.speaker != nil }
        let sentenceEnders: Set<Character> = (language == "ja")
            ? ["。", "！", "？"] : [".", "!", "?"]
        let separator = (language == "ja") ? "" : " "
        let normalAttrs = confirmedAttributes(fontSize: fontSize)

        var currentSpeaker: String? = nil
        var lastChar: Character? = nil

        for segment in segments {
            guard !segment.text.isEmpty else { continue }

            let isFirst = (result.length == 0)

            if isFirst {
                if hasSpeakers, let speaker = segment.speaker {
                    let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
                    result.append(NSAttributedString(string: "\(speaker): ", attributes: labelAttrs))
                    result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                    currentSpeaker = speaker
                } else {
                    result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                }
                lastChar = segment.text.last
                continue
            }

            // Priority 1: Speaker change
            if hasSpeakers, let speaker = segment.speaker, speaker != currentSpeaker {
                let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
                result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
                result.append(NSAttributedString(string: "\(speaker): ", attributes: labelAttrs))
                result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                currentSpeaker = speaker
                lastChar = segment.text.last
                continue
            }

            // Priority 2: Silence threshold
            if segment.precedingSilence >= silenceThreshold {
                result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
                lastChar = segment.text.last
                continue
            }

            // Priority 3: Sentence end
            if let last = lastChar, sentenceEnders.contains(last) {
                result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
                lastChar = segment.text.last
                continue
            }

            // Priority 4: Inline
            result.append(NSAttributedString(string: separator + segment.text, attributes: normalAttrs))
            lastChar = segment.text.last
        }

        if !unconfirmed.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
            result.append(buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize))
        }

        return result
    }

    private static func speakerLabelAttributes(fontSize: CGFloat, confidence: Float?) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        if let conf = confidence, conf < lowConfidenceThreshold {
            color = .secondaryLabelColor
        } else {
            color = .labelColor
        }
        return [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: makeParagraphStyle()
        ]
    }

    private static func buildUnconfirmedAttributedString(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let italicFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: fontSize),
            toHaveTrait: .italicFontMask
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.3),
            .paragraphStyle: makeParagraphStyle()
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastConfirmedText: String = ""
        var lastUnconfirmedText: String = ""
        var lastFontSize: CGFloat = 0

        func isScrolledToBottom() -> Bool {
            guard let scrollView = scrollView,
                  let documentView = scrollView.documentView else {
                return true
            }
            let visibleRect = scrollView.contentView.bounds
            let documentHeight = documentView.frame.height
            let threshold: CGFloat = 50
            return visibleRect.maxY >= documentHeight - threshold
        }
    }
}
