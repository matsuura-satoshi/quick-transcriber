import SwiftUI
import AppKit

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
    internal var availableSpeakers: [SpeakerMenuItem] = []
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

    private static func menuTitle(for speaker: SpeakerMenuItem) -> String {
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
    var availableSpeakers: [SpeakerMenuItem] = []
    var onReassignBlock: ((Int, String) -> Void)?
    var onReassignSelection: ((NSRange, String, SegmentCharacterMap) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InteractiveTranscriptionTextView()
        let scrollView = TranscriptTextViewSupport.makeScrollView(wrapping: textView)
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
        let newSpeakerFingerprint = Self.speakerFingerprint(confirmedSegments)

        guard newConfirmed != oldConfirmed
            || newUnconfirmed != oldUnconfirmed
            || fontSize != oldFontSize
            || newSpeakerFingerprint != coordinator.lastSpeakerFingerprint else {
            return
        }

        coordinator.lastConfirmedText = newConfirmed
        coordinator.lastUnconfirmedText = newUnconfirmed
        coordinator.lastFontSize = fontSize

        guard let textView = coordinator.textView else { return }

        let isAtBottom = coordinator.isScrolledToBottom()

        // segments が空の場合（clear 直後・unconfirmed のみ）も renderer が正しく描画する
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

        if isAtBottom {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: - Speaker Fingerprint

    /// Lightweight hash of speaker metadata (speaker UUID + confidence) for change detection.
    /// Used by updateNSView to detect speaker reassignments that don't change the plain text.
    static func speakerFingerprint(_ segments: [ConfirmedSegment]) -> Int {
        var hasher = Hasher()
        for segment in segments {
            hasher.combine(segment.speaker)
            hasher.combine(segment.speakerConfidence)
        }
        return hasher.finalize()
    }

    // MARK: - Segment-Based Rendering

    /// Build an NSAttributedString from segments, coloring speaker labels by confidence.
    /// Returns a tuple of (attributed string, segment character map).
    /// 実装は SegmentTextRenderer.render に委譲（joinSegments と同一の layout を消費する）。
    static func buildAttributedStringFromSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        fontSize: CGFloat,
        unconfirmed: String,
        speakerDisplayNames: [String: String] = [:]
    ) -> (NSAttributedString, SegmentCharacterMap) {
        SegmentTextRenderer.render(
            segments,
            language: language,
            silenceThreshold: silenceThreshold,
            fontSize: fontSize,
            unconfirmed: unconfirmed,
            speakerDisplayNames: speakerDisplayNames
        )
    }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastConfirmedText: String = ""
        var lastUnconfirmedText: String = ""
        var lastFontSize: CGFloat = 0
        var lastSpeakerFingerprint: Int = 0

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
            guard let textView, textView.textStorage != nil else { return }

            let (attributed, map) = TranscriptionTextView.buildAttributedStringFromSegments(
                segments, language: language, silenceThreshold: silenceThreshold,
                fontSize: fontSize, unconfirmed: unconfirmed, speakerDisplayNames: speakerDisplayNames
            )

            if let interactiveView = textView as? InteractiveTranscriptionTextView {
                interactiveView.segmentMap = map
            }

            lastSpeakerFingerprint = TranscriptionTextView.speakerFingerprint(segments)

            let newText = attributed.string
            let currentText = textView.textStorage?.string ?? ""

            let canDiffAppend = fontSize == oldFontSize
                && unconfirmed.isEmpty
                && oldUnconfirmed.isEmpty
                && !currentText.isEmpty
                && newText.hasPrefix(currentText)
                && newText.count > currentText.count

            TranscriptTextViewSupport.applyDiffAppendOrReplace(attributed, to: textView, canDiffAppend: canDiffAppend)
        }

        func isScrolledToBottom() -> Bool {
            TranscriptTextViewSupport.isScrolledToBottom(scrollView)
        }
    }
}
