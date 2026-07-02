import AppKit

/// TranscriptionTextView / TranslationTextView が共用する NSTextView 配管。
enum TranscriptTextViewSupport {
    /// 標準のトランスクリプト表示用 scroll view + text view を構成する。
    static func makeScrollView(wrapping textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

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
        return scrollView
    }

    /// canDiffAppend のとき末尾差分のみ append、それ以外は選択範囲を保って全置換する。
    /// - Precondition: `canDiffAppend == true` の場合、`attributed.string` は現在の
    ///   textStorage 内容の prefix 拡張であること（呼び出し側の canDiffAppend 判定が保証する）。
    ///   これが破れると負の長さの NSRange でクラッシュする。
    static func applyDiffAppendOrReplace(
        _ attributed: NSAttributedString,
        to textView: NSTextView,
        canDiffAppend: Bool
    ) {
        guard let textStorage = textView.textStorage else { return }
        if canDiffAppend {
            let deltaStart = (textStorage.string as NSString).length
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

    static func isScrolledToBottom(_ scrollView: NSScrollView?) -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return true }
        let threshold: CGFloat = 50
        return scrollView.contentView.bounds.maxY >= documentView.frame.height - threshold
    }
}
