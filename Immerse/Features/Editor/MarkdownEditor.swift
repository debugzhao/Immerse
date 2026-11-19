import AppKit
import SwiftUI

/// Lightweight Markdown notes editor: highlights as you type; markers are kept but dimmed.
/// - Return auto-continues lists / todos / quotes; Return on an empty item ends the list
/// - ⌘B bold, ⌘I italic (wraps the selection if there is one)
/// - Click `[ ]` to toggle a todo
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    /// Distance of the text from the top; the placeholder must align with it
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
        // External change (undo, switching events): replace the text, preserving the cursor position where possible
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
            // Don't touch styling during IME composition, or it will interrupt the candidates
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
            // Only look at the part before the cursor, so Return in the middle of a line continues correctly
            let head = string.substring(with: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
            guard let continuation = MarkdownStyler.continuation(forLine: head) else { return false }

            if continuation.isEmpty {
                // Return on an empty list item: remove the marker and end the list
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
            } else {
                textView.insertText("\n" + continuation, replacementRange: caret)
            }
            return true
        }
    }
}

/// Handles ⌘B / ⌘I and click-to-toggle todos
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
        // With no selection, place the cursor between the two markers
        if range.length == 0 {
            setSelectedRange(NSRange(location: range.location + markerLength, length: 0))
        }
    }

    /// Clicking on `[ ]` toggles the checked state (via insertText, so it is undoable)
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
        // The checkbox spans three characters: offset-1 ("[") through offset+1 ("]")
        let boxStart = lineRange.location + offset - 1
        guard index >= boxStart, index <= boxStart + 2 else { return false }

        let mark = NSRange(location: lineRange.location + offset, length: 1)
        let isDone = string.substring(with: mark).lowercased() == "x"
        insertText(isDone ? " " : "x", replacementRange: mark)
        return true
    }
}
