import SwiftUI
import AppKit

struct TranslationTextView: NSViewRepresentable {
    let confirmedSegments: [ConfirmedSegment]
    let fontSize: CGFloat
    var language: String = "en"
    var silenceThreshold: TimeInterval = 1.0
    var speakerDisplayNames: [String: String] = [:]

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

        guard let textView = coordinator.textView,
              let textStorage = textView.textStorage else { return }

        let isAtBottom = coordinator.isScrolledToBottom()

        let (attributed, _) = TranscriptionTextView.buildAttributedStringFromSegments(
            confirmedSegments,
            language: language,
            silenceThreshold: silenceThreshold,
            fontSize: fontSize,
            unconfirmed: "",
            speakerDisplayNames: speakerDisplayNames
        )

        let newText = attributed.string
        let currentText = textStorage.string

        let canDiffAppend = fontSize == coordinator.lastFontSize
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

        coordinator.lastFontSize = fontSize

        if isAtBottom {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
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
