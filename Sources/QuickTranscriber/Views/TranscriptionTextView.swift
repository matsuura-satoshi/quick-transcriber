import SwiftUI
import AppKit

struct TranscriptionTextView: NSViewRepresentable {
    let confirmedText: String
    let unconfirmedText: String
    let fontSize: CGFloat

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

        guard newConfirmed != coordinator.lastConfirmedText
            || newUnconfirmed != coordinator.lastUnconfirmedText
            || fontSize != coordinator.lastFontSize else {
            return
        }

        coordinator.lastConfirmedText = newConfirmed
        coordinator.lastUnconfirmedText = newUnconfirmed
        coordinator.lastFontSize = fontSize

        guard let textView = coordinator.textView else { return }

        // Check if user is scrolled to bottom before updating
        let isAtBottom = coordinator.isScrolledToBottom()

        let attributed = Self.buildAttributedString(
            confirmed: newConfirmed,
            unconfirmed: newUnconfirmed,
            fontSize: fontSize
        )

        textView.textStorage?.setAttributedString(attributed)

        // Only auto-scroll if user was at the bottom
        if isAtBottom {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    private static func buildAttributedString(
        confirmed: String,
        unconfirmed: String,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 8

        if !confirmed.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            result.append(NSAttributedString(string: confirmed, attributes: attrs))
        }

        if !unconfirmed.isEmpty {
            if !confirmed.isEmpty {
                let newline = NSAttributedString(string: "\n")
                result.append(newline)
            }

            let italicFont = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize),
                toHaveTrait: .italicFontMask
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: italicFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.3),
                .paragraphStyle: paragraphStyle
            ]
            result.append(NSAttributedString(string: unconfirmed, attributes: attrs))
        }

        return result
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
