import AppKit
import SwiftUI

/// 轻便的 Markdown 备注编辑器：边写边高亮，标记符号保留但变淡。
/// - 回车自动续写列表 / 待办 / 引用，空项回车结束列表
/// - ⌘B 粗体、⌘I 斜体（有选中文字时包起来）
/// - 点击 `[ ]` 勾选待办
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    /// 文字距顶部的距离，占位文字要对齐它
    static let topInset: CGFloat = 4

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: Self.topInset)
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        MarkdownStyler.apply(to: storage)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text,
              !textView.hasMarkedText() else { return }
        // 外部改动（撤销、切换日程）：替换文字，尽量保留光标位置
        let selection = textView.selectedRange()
        textView.string = text
        if let storage = textView.textStorage { MarkdownStyler.apply(to: storage) }
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // 输入法组字中不要动样式，否则会打断候选
            if !textView.hasMarkedText(), let storage = textView.textStorage {
                MarkdownStyler.apply(to: storage)
                textView.typingAttributes = MarkdownStyler.baseAttributes
            }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let string = textView.string as NSString
            let caret = textView.selectedRange()
            guard caret.length == 0 else { return false }
            let lineRange = string.lineRange(for: NSRange(location: caret.location, length: 0))
            // 只看光标前的部分，光标在行中间回车时也能正确续写
            let head = string.substring(with: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
            guard let continuation = MarkdownStyler.continuation(forLine: head) else { return false }

            if continuation.isEmpty {
                // 空列表项回车：删掉标记，结束列表
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
            } else {
                textView.insertText("\n" + continuation, replacementRange: caret)
            }
            return true
        }
    }
}

/// 处理 ⌘B / ⌘I 和点击勾选待办
final class MarkdownTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": wrapSelection(with: "**")
        case "i": wrapSelection(with: "*")
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    private func wrapSelection(with marker: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(marker + selected + marker, replacementRange: range)
        let markerLength = (marker as NSString).length
        // 没选中文字时把光标放到两个标记中间
        if range.length == 0 {
            setSelectedRange(NSRange(location: range.location + markerLength, length: 0))
        }
    }

    /// 点在 `[ ]` 上就切换勾选状态（通过 insertText 修改，可撤销）
    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer else { return false }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let string = self.string as NSString
        guard index < string.length else { return false }

        let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
        let line = string.substring(with: lineRange)
        guard let offset = MarkdownStyler.checkboxOffset(inLine: line) else { return false }
        // 复选框是 offset-1（[）到 offset+1（]）这三个字符
        let boxStart = lineRange.location + offset - 1
        guard index >= boxStart, index <= boxStart + 2 else { return false }

        let mark = NSRange(location: lineRange.location + offset, length: 1)
        let isDone = string.substring(with: mark).lowercased() == "x"
        insertText(isDone ? " " : "x", replacementRange: mark)
        return true
    }
}
