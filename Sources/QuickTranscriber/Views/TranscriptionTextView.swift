import SwiftUI
import AppKit

public struct SegmentCharacterMap {
    public struct Entry {
        public let segmentIndex: Int
        public let characterRange: NSRange
        public let labelRange: NSRange?
    }
    public var entries: [Entry] = []

    public func segmentIndices(overlapping range: NSRange) -> [Int] {
        entries.compactMap { entry in
            let fullRange = NSUnionRange(
                entry.labelRange ?? entry.characterRange,
                entry.characterRange
            )
            if NSIntersectionRange(fullRange, range).length > 0 {
                return entry.segmentIndex
            }
            return nil
        }
    }

    public func consecutiveBlockIndices(from index: Int, segments: [ConfirmedSegment]) -> [Int] {
        guard index < segments.count, let speaker = segments[index].speaker else {
            return [index]
        }
        var result = [Int]()
        // Expand backward
        var i = index
        while i >= 0 && segments[i].speaker == speaker { i -= 1 }
        i += 1
        // Expand forward
        while i < segments.count && segments[i].speaker == speaker {
            result.append(i)
            i += 1
        }
        return result
    }

    public func labelEntry(at characterIndex: Int) -> Entry? {
        entries.first { entry in
            guard let labelRange = entry.labelRange else { return false }
            return NSLocationInRange(characterIndex, labelRange)
        }
    }
}

private class BlockReassignInfo: NSObject {
    let segmentIndex: Int
    let speakerIdString: String
    init(segmentIndex: Int, speakerIdString: String) {
        self.segmentIndex = segmentIndex
        self.speakerIdString = speakerIdString
    }
}

internal class InteractiveTranscriptionTextView: NSTextView {
    internal var segmentMap: SegmentCharacterMap?
    internal var confirmedSegments: [ConfirmedSegment] = []
    internal var availableSpeakers: [TranscriptionViewModel.SpeakerMenuItem] = []
    internal var onReassignBlock: ((Int, String) -> Void)?
    internal var onReassignSelection: ((NSRange, String, SegmentCharacterMap) -> Void)?
    private var lastEventLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let map = segmentMap else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        guard charIndex < (textStorage?.length ?? 0) else {
            super.mouseDown(with: event)
            return
        }

        if let entry = map.labelEntry(at: charIndex) {
            let blockIndices = map.consecutiveBlockIndices(from: entry.segmentIndex, segments: confirmedSegments)
            showSpeakerMenu(for: blockIndices, at: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        lastEventLocation = convert(event.locationInWindow, from: nil)
        let base = super.menu(for: event) ?? NSMenu()
        let range = selectedRange()

        guard range.length > 0,
              let text = textStorage?.string,
              let map = segmentMap else {
            return base
        }

        let selectedText = (text as NSString).substring(with: range)
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }

        let indices = map.segmentIndices(overlapping: range)
        guard !indices.isEmpty else { return base }

        let speakerMenu = NSMenu()
        for speaker in availableSpeakers {
            let title = Self.menuTitle(for: speaker)
            let item = NSMenuItem(title: title, action: #selector(reassignSelectionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speaker.id.uuidString
            speakerMenu.addItem(item)
        }

        base.addItem(NSMenuItem.separator())
        let assignItem = NSMenuItem(title: "Assign Speaker", action: nil, keyEquivalent: "")
        assignItem.submenu = speakerMenu
        base.addItem(assignItem)

        return base
    }

    private func showSpeakerMenu(for blockIndices: [Int], at event: NSEvent) {
        guard let firstIdx = blockIndices.first else { return }
        let menu = NSMenu()

        for speaker in availableSpeakers {
            let title = Self.menuTitle(for: speaker)
            let item = NSMenuItem(title: title, action: #selector(reassignBlockAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BlockReassignInfo(segmentIndex: firstIdx, speakerIdString: speaker.id.uuidString)
            menu.addItem(item)
        }

        let point = convert(event.locationInWindow, from: nil)
        lastEventLocation = point
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private static func menuTitle(for speaker: TranscriptionViewModel.SpeakerMenuItem) -> String {
        if let name = speaker.displayName {
            return name
        }
        return speaker.id.uuidString
    }

    @objc private func reassignBlockAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? BlockReassignInfo else { return }
        let segmentIndex = info.segmentIndex
        let speakerId = info.speakerIdString
        onReassignBlock?(segmentIndex, speakerId)
    }

    @objc private func reassignSelectionAction(_ sender: NSMenuItem) {
        guard let speakerId = sender.representedObject as? String,
              let map = segmentMap else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        onReassignSelection?(range, speakerId, map)
    }

}

struct TranscriptionTextView: NSViewRepresentable {
    let confirmedText: String
    let unconfirmedText: String
    let fontSize: CGFloat
    let confirmedSegments: [ConfirmedSegment]
    var language: String = "en"
    var silenceThreshold: TimeInterval = 1.0
    var speakerDisplayNames: [String: String] = [:]
    var availableSpeakers: [TranscriptionViewModel.SpeakerMenuItem] = []
    var onReassignBlock: ((Int, String) -> Void)?
    var onReassignSelection: ((NSRange, String, SegmentCharacterMap) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = InteractiveTranscriptionTextView()
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

        // Update interactive text view properties
        if let interactiveView = coordinator.textView as? InteractiveTranscriptionTextView {
            interactiveView.confirmedSegments = confirmedSegments
            interactiveView.availableSpeakers = availableSpeakers
            interactiveView.onReassignBlock = onReassignBlock
            interactiveView.onReassignSelection = onReassignSelection
        }

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
            coordinator.applySegmentUpdate(
                segments: confirmedSegments,
                language: language,
                silenceThreshold: silenceThreshold,
                fontSize: fontSize,
                unconfirmed: newUnconfirmed,
                oldFontSize: oldFontSize,
                oldUnconfirmed: oldUnconfirmed,
                speakerDisplayNames: speakerDisplayNames
            )
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
                let savedRange = textView.selectedRange()
                let hadSelection = savedRange.length > 0
                let attributed = Self.buildAttributedString(
                    confirmed: newConfirmed,
                    unconfirmed: newUnconfirmed,
                    fontSize: fontSize
                )
                textStorage.setAttributedString(attributed)
                if hadSelection && NSMaxRange(savedRange) <= textStorage.length {
                    textView.setSelectedRange(savedRange)
                }
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

    private static let lowConfidenceThreshold: Float = Constants.Embedding.similarityThreshold

    /// Build an NSAttributedString from segments, coloring speaker labels by confidence.
    /// Mirrors the logic of TranscriptionUtils.joinSegments but produces attributed text.
    /// Returns a tuple of (attributed string, segment character map).
    static func buildAttributedStringFromSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        fontSize: CGFloat,
        unconfirmed: String,
        speakerDisplayNames: [String: String] = [:]
    ) -> (NSAttributedString, SegmentCharacterMap) {
        let result = NSMutableAttributedString()
        var map = SegmentCharacterMap()
        guard !segments.isEmpty else {
            if !unconfirmed.isEmpty {
                return (buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize), map)
            }
            return (result, map)
        }

        let hasSpeakers = segments.contains { $0.speaker != nil }
        let sentenceEnders: Set<Character> = (language == "ja")
            ? ["。", "！", "？"] : [".", "!", "?"]
        let separator = (language == "ja") ? "" : " "
        let normalAttrs = confirmedAttributes(fontSize: fontSize)

        var currentSpeaker: String? = nil
        var lastChar: Character? = nil
        var segmentIndex = 0

        for segment in segments {
            guard !segment.text.isEmpty else {
                segmentIndex += 1
                continue
            }

            let isFirst = (result.length == 0)
            var labelRange: NSRange? = nil

            if isFirst {
                if hasSpeakers, let speaker = segment.speaker {
                    let displayName = speakerDisplayNames[speaker] ?? "Unknown"
                    let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
                    let labelStart = result.length
                    let labelStr = "\(displayName): "
                    result.append(NSAttributedString(string: labelStr, attributes: labelAttrs))
                    labelRange = NSRange(location: labelStart, length: (labelStr as NSString).length)
                    let textStart = result.length
                    result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                    let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
                    map.entries.append(SegmentCharacterMap.Entry(
                        segmentIndex: segmentIndex, characterRange: textRange, labelRange: labelRange
                    ))
                    currentSpeaker = speaker
                } else {
                    let textStart = result.length
                    result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                    let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
                    map.entries.append(SegmentCharacterMap.Entry(
                        segmentIndex: segmentIndex, characterRange: textRange, labelRange: nil
                    ))
                }
                lastChar = segment.text.last
                segmentIndex += 1
                continue
            }

            // Priority 1: Speaker change
            if hasSpeakers, let speaker = segment.speaker, speaker != currentSpeaker {
                let displayName = speakerDisplayNames[speaker] ?? "Unknown"
                let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
                result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
                let labelStart = result.length
                let labelStr = "\(displayName): "
                result.append(NSAttributedString(string: labelStr, attributes: labelAttrs))
                labelRange = NSRange(location: labelStart, length: (labelStr as NSString).length)
                let textStart = result.length
                result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
                map.entries.append(SegmentCharacterMap.Entry(
                    segmentIndex: segmentIndex, characterRange: textRange, labelRange: labelRange
                ))
                currentSpeaker = speaker
                lastChar = segment.text.last
                segmentIndex += 1
                continue
            }

            // Priority 2: Silence threshold
            if segment.precedingSilence >= silenceThreshold {
                let textStart = result.length + 1 // +1 for newline
                result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
                let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
                map.entries.append(SegmentCharacterMap.Entry(
                    segmentIndex: segmentIndex, characterRange: textRange, labelRange: nil
                ))
                lastChar = segment.text.last
                segmentIndex += 1
                continue
            }

            // Priority 3: Sentence end
            if let last = lastChar, sentenceEnders.contains(last) {
                let textStart = result.length + 1
                result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
                let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
                map.entries.append(SegmentCharacterMap.Entry(
                    segmentIndex: segmentIndex, characterRange: textRange, labelRange: nil
                ))
                lastChar = segment.text.last
                segmentIndex += 1
                continue
            }

            // Priority 4: Inline
            let prefixLen = (separator as NSString).length
            let textStart = result.length + prefixLen
            result.append(NSAttributedString(string: separator + segment.text, attributes: normalAttrs))
            let textRange = NSRange(location: textStart, length: (segment.text as NSString).length)
            map.entries.append(SegmentCharacterMap.Entry(
                segmentIndex: segmentIndex, characterRange: textRange, labelRange: nil
            ))
            lastChar = segment.text.last
            segmentIndex += 1
        }

        if !unconfirmed.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
            result.append(buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize))
        }

        return (result, map)
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

        func applySegmentUpdate(
            segments: [ConfirmedSegment],
            language: String,
            silenceThreshold: TimeInterval,
            fontSize: CGFloat,
            unconfirmed: String,
            oldFontSize: CGFloat,
            oldUnconfirmed: String,
            speakerDisplayNames: [String: String] = [:]
        ) {
            guard let textView, let textStorage = textView.textStorage else { return }

            let (attributed, map) = TranscriptionTextView.buildAttributedStringFromSegments(
                segments, language: language, silenceThreshold: silenceThreshold,
                fontSize: fontSize, unconfirmed: unconfirmed, speakerDisplayNames: speakerDisplayNames
            )

            if let interactiveView = textView as? InteractiveTranscriptionTextView {
                interactiveView.segmentMap = map
            }

            let newText = attributed.string
            let currentText = textStorage.string

            let canDiffAppend = fontSize == oldFontSize
                && unconfirmed.isEmpty
                && oldUnconfirmed.isEmpty
                && !currentText.isEmpty
                && newText.hasPrefix(currentText)
                && newText.count > currentText.count

            if canDiffAppend {
                let deltaStart = (currentText as NSString).length
                let deltaRange = NSRange(location: deltaStart, length: attributed.length - deltaStart)
                textStorage.append(attributed.attributedSubstring(from: deltaRange))
            } else {
                let savedRange = textView.selectedRange()
                let hadSelection = savedRange.length > 0
                textStorage.setAttributedString(attributed)
                if hadSelection && NSMaxRange(savedRange) <= textStorage.length {
                    textView.setSelectedRange(savedRange)
                }
            }
        }

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
