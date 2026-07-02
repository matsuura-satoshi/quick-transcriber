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
        let textView = NSTextView()
        let scrollView = TranscriptTextViewSupport.makeScrollView(wrapping: textView)
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

        TranscriptTextViewSupport.applyDiffAppendOrReplace(attributed, to: textView, canDiffAppend: canDiffAppend)

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
            TranscriptTextViewSupport.isScrolledToBottom(scrollView)
        }
    }
}
