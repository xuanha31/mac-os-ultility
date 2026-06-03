import SwiftUI
import AppKit

/// Editor SQL dựa trên NSTextView: tắt smart-quotes, có số dòng, đồng bộ chắc chắn về binding.
struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        // Tắt mọi thay thế tự động (sửa lỗi nháy cong ORA-01756).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Resizing.
        let big = CGFloat.greatestFiniteMagnitude
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: big, height: big)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.string = text
        scrollView.documentView = textView

        // Số dòng.
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self   // giữ binding mới nhất
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            if sel.location <= text.utf16.count { textView.setSelectedRange(sel) }
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        weak var ruler: LineNumberRulerView?
        weak var textView: NSTextView?
        init(_ parent: SQLTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string      // đồng bộ về state.queryText
            ruler?.needsDisplay = true
        }
    }
}

/// Vẽ số dòng bên trái NSTextView.
final class LineNumberRulerView: NSRulerView {
    private weak var tv: NSTextView?
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.tv = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        // Vẽ lại khi cuộn / đổi kích thước.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.frameDidChangeNotification, object: textView)
        if let clip = scrollView.contentView as NSClipView? {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = tv,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        rect.fill()

        let content = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let inset = textView.textContainerInset.height
        let relativePoint = convert(NSZeroPoint, from: textView)

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        if charRange.location > 0 {
            lineNumber = content.substring(to: charRange.location)
                .reduce(into: 1) { acc, ch in if ch == "\n" { acc += 1 } }
        }

        var charIndex = charRange.location
        while charIndex < NSMaxRange(charRange) {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphLine = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var eff = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphLine.location, effectiveRange: &eff)
            let y = relativePoint.y + lineRect.minY + inset
            let str = "\(lineNumber)" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: ruleThickness - size.width - 6,
                                 y: y + (lineRect.height - size.height) / 2),
                     withAttributes: attrs)
            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        if content.length == 0 || content.hasSuffix("\n") {
            let str = "\(lineNumber)" as NSString
            let size = str.size(withAttributes: attrs)
            let usedRect = layoutManager.usedRect(for: container)
            let y = relativePoint.y + usedRect.maxY + inset
            str.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
        }
    }
}
