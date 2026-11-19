import AppKit
import SwiftUI

/// Live-preview Markdown notes editor (Typora / Notion style). The stored text stays plain Markdown.
/// - Syntax is concealed and rendered: links show only their text, `- [ ]` is a checkbox, `- ` a bullet…
///   The caret uncovers the source of the inline element (or heading / quote line) it is in.
/// - Markdown as you type: `# `, `- `, `1. `, `[] `, `> `, ``` + Return, `---`; `/` opens a block menu
/// - Keys: ⌘B ⌘I ⇧⌘X ⌘E ⌘K, ⌥⌘0–6 block types, ⌥⌘Q quote, ⌥⌘C code block, Tab / ⇧Tab nest list items
/// - Pasting a URL inserts a page mention `[@Title](url)`, titled from the page
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    /// Distance of the text from the top; the placeholder must align with it
    static let topInset: CGFloat = 4

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(text: text, delegate: context.coordinator)
    }

    /// Builds the scrollable text view stack (also used by tests, so they exercise the real configuration)
    static func makeScrollView(text: String, delegate: NSTextViewDelegate?) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = delegate
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: topInset)
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.restyle(force: true)

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
        guard let textView = scrollView.documentView as? MarkdownTextView,
              textView.string != text,
              !textView.hasMarkedText() else { return }
        // External change (undo, switching events): replace the text, preserving the cursor position where possible
        let selection = textView.selectedRange()
        textView.string = text
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.restyle(force: true)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            textView.restyle()
            textView.updateSlashMenu()
            text.wrappedValue = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            textView.restyle()
            textView.updateSlashMenu()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                      toCharacterRange newRange: NSRange) -> NSRange {
            (textView as? MarkdownTextView)?.snappedSelection(from: oldRange, to: newRange) ?? newRange
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let textView = textView as? MarkdownTextView, !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return textView.handleReturn()
            case #selector(NSResponder.deleteBackward(_:)): return textView.handleBackspace()
            case #selector(NSResponder.insertTab(_:)): return textView.indentListItems(outward: false)
            case #selector(NSResponder.insertBacktab(_:)): return textView.indentListItems(outward: true)
            default: return false
            }
        }
    }
}

/// The text view behind `MarkdownEditor`: restyling, Markdown shortcuts, link pasting and clicks
final class MarkdownTextView: NSTextView {
    private var spans: [MarkdownStyler.Span] = []
    private var styledText: String?
    private var revealState: [Bool] = []
    private var isFocused = false
    private var keyMonitor: Any?
    /// Location of the `/` that opened the slash menu while it is open
    private var slashAnchor: Int?
    private lazy var slashMenu = SlashMenuPanel()

    /// Characters typed next to a concealed marker would otherwise inherit its hidden attributes
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set { super.typingAttributes = MarkdownStyler.baseAttributes }
    }

    // MARK: - Styling

    /// Re-parses after edits and re-renders when the caret uncovers or leaves a piece of syntax
    func restyle(force: Bool = false) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        // Selection changes also fire while the storage is still processing an edit; restyling then would
        // skip font fallback (CJK typed into the system font would get no glyphs), so wait until it is done
        guard storage.editedMask.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.restyle(force: force) }
            return
        }
        let current = storage.string
        var needsApply = force
        if current != styledText {
            spans = MarkdownStyler.spans(in: current)
            styledText = current
            needsApply = true
        }
        // Without focus nothing is being edited, so everything renders
        let selections = isFocused ? selectedRanges.map(\.rangeValue) : []
        let state = MarkdownStyler.revealState(of: spans, selections: selections)
        if state != revealState { needsApply = true }
        guard needsApply else { return }
        revealState = state
        MarkdownStyler.apply(spans, to: storage, selections: selections)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isFocused = true
            restyle()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isFocused = false
            dismissSlashMenu()
            restyle()
        }
        return accepted
    }

    private var isStyleCurrent: Bool { styledText == string }

    /// Bullets and checkboxes are drawn over their characters, so the caret steps over them as one unit
    func snappedSelection(from oldRange: NSRange, to newRange: NSRange) -> NSRange {
        guard newRange.length == 0, isStyleCurrent else { return newRange }
        let markers = spans.compactMap { span -> NSRange? in
            switch span.kind {
            case .bullet, .checkbox: span.range
            default: nil
            }
        }
        guard let marker = markers.first(where: { newRange.location >= $0.location && newRange.location < $0.upperBound }) else {
            return newRange
        }
        // Arrowing left out of the item text continues to the end of the previous line
        if oldRange.length == 0, oldRange.location == marker.upperBound, newRange.location < marker.upperBound {
            let lineStart = (string as NSString).lineRange(for: NSRange(location: marker.location, length: 0)).location
            if lineStart > 0 { return NSRange(location: lineStart - 1, length: 0) }
        }
        return NSRange(location: marker.upperBound, length: 0)
    }

    // MARK: - Editing primitives

    /// Undoable replacement that bypasses the typing shortcuts
    private func replace(_ range: NSRange, with text: String) {
        breakUndoCoalescing()
        super.insertText(text, replacementRange: range)
        breakUndoCoalescing()
    }

    private var nsString: NSString { string as NSString }

    /// The line around a location, without its line break
    private func line(at location: Int) -> NSRange {
        var range = nsString.lineRange(for: NSRange(location: location, length: 0))
        while range.length > 0, [0x0A, 0x0D].contains(nsString.character(at: range.upperBound - 1)) {
            range.length -= 1
        }
        return range
    }

    /// The whole lines covered by the selection, without the final line break
    private func selectedLines() -> NSRange {
        let selection = selectedRange()
        let first = line(at: selection.location)
        let last = line(at: max(selection.location, selection.upperBound - (selection.length > 0 ? 1 : 0)))
        return NSRange(location: first.location, length: last.upperBound - first.location)
    }

    // MARK: - Typing shortcuts

    private static let todoShortcut = try! NSRegularExpression(pattern: #"^([ \t]*)(?:\[([ xX]?)\]|【([ xX]?)】)$"#)

    /// `[] ` / `[x] ` becomes a to-do (also with the Chinese input method's 【】), `》 ` a quote
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if typed == " ", !hasMarkedText(), applySpaceShortcut(replacementRange) { return }
        super.insertText(insertString, replacementRange: replacementRange)
        if let typed, SlashCommand.triggers.contains(typed), !hasMarkedText() {
            openSlashMenuIfAtWordStart()
        }
    }

    private func applySpaceShortcut(_ replacementRange: NSRange) -> Bool {
        let caret = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard caret.length == 0 else { return false }
        let lineStart = line(at: caret.location).location
        let headRange = NSRange(location: lineStart, length: caret.location - lineStart)
        let head = nsString.substring(with: headRange)
        let headNS = head as NSString

        if head == "》" {
            replace(headRange, with: "> ")
            return true
        }
        guard let match = Self.todoShortcut.firstMatch(in: head, range: NSRange(location: 0, length: headNS.length)) else { return false }
        let indent = headNS.substring(with: match.range(at: 1))
        let mark = [2, 3].map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { headNS.substring(with: $0) } ?? ""
        replace(headRange, with: indent + (mark.lowercased() == "x" ? "- [x] " : "- [ ] "))
        return true
    }

    /// Return: continues lists, ends them on an empty item, closes a freshly opened code block
    func handleReturn() -> Bool {
        let caret = selectedRange()
        guard caret.length == 0 else { return false }
        let lineRange = line(at: caret.location)
        let text = nsString.substring(with: lineRange)

        if caret.location == lineRange.upperBound, opensUnclosedFence(lineRange) {
            replace(caret, with: "\n\n```")
            setSelectedRange(NSRange(location: caret.location + 1, length: 0))
            return true
        }

        let prefix = MarkdownStyler.linePrefix(text)
        guard let continuation = MarkdownStyler.continuation(forLine: text),
              caret.location >= lineRange.location + prefix.length else { return false }
        if continuation.isEmpty {
            // Return on an empty item: un-nest it first, then end the list
            if !prefix.indent.isEmpty {
                return indentListItems(outward: true)
            }
            replace(NSRange(location: lineRange.location, length: prefix.length), with: "")
            return true
        }
        replace(caret, with: "\n" + continuation)
        return true
    }

    /// Whether the line is a ``` that opens a block nothing closes yet
    private func opensUnclosedFence(_ lineRange: NSRange) -> Bool {
        let fence = try! NSRegularExpression(pattern: #"^[ \t]*```"#, options: [.anchorsMatchLines])
        guard fence.firstMatch(in: string, range: lineRange) != nil else { return false }
        let all = fence.matches(in: string, range: NSRange(location: 0, length: nsString.length))
        let before = all.filter { $0.range.location < lineRange.location }.count
        return before % 2 == 0 && all.count % 2 == 1
    }

    /// Backspace at the start of a list item turns it back into text; after a concealed link it edits the link
    func handleBackspace() -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, isStyleCurrent else { return false }

        // The `)` before the caret is hidden: a mention goes as a whole, a link loses its last letter
        for span in spans {
            guard let inner = span.reveal, inner.upperBound + 1 == caret.location else { continue }
            switch span.kind {
            case .mention:
                replace(NSRange(location: inner.location - 1, length: inner.length + 2), with: "")
                return true
            case .link:
                replace(nsString.rangeOfComposedCharacterSequence(at: span.range.upperBound - 1), with: "")
                return true
            default:
                continue
            }
        }

        let lineRange = line(at: caret.location)
        let prefix = MarkdownStyler.linePrefix(nsString.substring(with: lineRange))
        guard prefix.kind.isList, caret.location == lineRange.location + prefix.length else { return false }
        if !prefix.indent.isEmpty {
            return indentListItems(outward: true)
        }
        replace(NSRange(location: lineRange.location, length: prefix.length), with: "")
        return true
    }

    /// Tab / ⇧Tab on list items nests / un-nests them by two spaces; elsewhere Tab types normally
    @discardableResult
    func indentListItems(outward: Bool) -> Bool {
        let selection = selectedRange()
        let block = selectedLines()
        var lines = nsString.substring(with: block).components(separatedBy: "\n")
        guard lines.contains(where: { MarkdownStyler.linePrefix($0).kind.isList }) else { return false }

        var shifts: [Int] = []
        for index in lines.indices {
            let old = lines[index]
            if MarkdownStyler.linePrefix(old).kind.isList {
                if !outward {
                    lines[index] = "  " + old
                } else if old.hasPrefix("  ") {
                    lines[index] = String(old.dropFirst(2))
                } else if old.hasPrefix(" ") || old.hasPrefix("\t") {
                    lines[index] = String(old.dropFirst())
                }
            }
            shifts.append((lines[index] as NSString).length - (old as NSString).length)
        }
        let total = shifts.reduce(0, +)
        guard total != 0 else { return true }
        replace(block, with: lines.joined(separator: "\n"))
        let first = shifts[0]
        let location = max(block.location, selection.location + first)
        let length = selection.length == 0 ? 0 : max(0, selection.length + total - first)
        setSelectedRange(NSRange(location: location, length: length))
        return true
    }

    // MARK: - Formatting commands

    // SwiftUI's window consumes ⌘-keys before `performKeyEquivalent` reaches a view inside its hierarchy,
    // and the event sheet takes Esc; a local monitor sees the keys first while the editor has focus.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dismissSlashMenu()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        } else if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return handled ? nil : event
            }
        }
    }

    /// Slash menu navigation and formatting shortcuts; returns whether the key was used
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.firstResponder === self, !hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])

        if slashAnchor != nil, flags.isEmpty || flags == .shift {
            switch event.keyCode {
            case 126: slashMenu.model.move(by: -1)          // ↑
            case 125: slashMenu.model.move(by: 1)           // ↓
            case 36, 76, 48:                                // Return, Enter, Tab
                guard let command = slashMenu.model.selected else { return false }
                chooseSlashCommand(command)
            case 53: dismissSlashMenu()                     // Esc
            default: return false
            }
            return true
        }
        return handleShortcut(event)
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch flags {
        case [.command]:
            switch key {
            case "b": toggleInline("**")
            case "i": toggleInline("*")
            case "e": toggleInline("`")
            // ⌘K without a selection stays the command palette
            case "k" where selectedRange().length > 0: insertLink()
            default: return false
            }
        case [.command, .shift] where key == "x":
            toggleInline("~~")
        case [.command, .option]:
            guard let command = BlockCommand(keyCode: event.keyCode) else { return false }
            perform(command)
        default:
            return false
        }
        return true
    }

    /// Wraps the selection in a marker, or unwraps it if it is already wrapped
    func toggleInline(_ marker: String) {
        let selection = selectedRange()
        let selected = nsString.substring(with: selection)
        let length = (marker as NSString).length

        // A lone `*` next to `**` belongs to bold, not italic
        func starRun(before location: Int) -> Int {
            var count = 0
            while location - count - 1 >= 0, nsString.character(at: location - count - 1) == 0x2A { count += 1 }
            return count
        }

        // Wrapped from outside: **|text|**
        if selection.location >= length, selection.upperBound + length <= nsString.length,
           nsString.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           nsString.substring(with: NSRange(location: selection.upperBound, length: length)) == marker,
           marker != "*" || starRun(before: selection.location) != 2 {
            replace(NSRange(location: selection.location - length, length: selection.length + 2 * length), with: selected)
            setSelectedRange(NSRange(location: selection.location - length, length: selection.length))
            return
        }
        // Wrapped from inside: |**text**|
        if selection.length >= 2 * length, selected.hasPrefix(marker), selected.hasSuffix(marker),
           marker != "*" || !selected.hasPrefix("**") || selected.hasPrefix("***") {
            let inner = (selected as NSString).substring(with: NSRange(location: length, length: selection.length - 2 * length))
            replace(selection, with: inner)
            setSelectedRange(NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }
        replace(selection, with: marker + selected + marker)
        setSelectedRange(NSRange(location: selection.location + length, length: selection.length))
    }

    /// ⌘K: links the selected words to the URL on the clipboard, or leaves the caret in `()` to type one
    func insertLink() {
        let selection = selectedRange()
        let selected = nsString.substring(with: selection)
        if let url = LinkTitleResolver.webURL(from: selected) {
            insertMention(url: url, address: selected.trimmingCharacters(in: .whitespacesAndNewlines), replacing: selection)
            return
        }
        let target = NSPasteboard.general.string(forType: .string).flatMap(LinkTitleResolver.webURL)?.absoluteString ?? ""
        let markdown = "[\(LinkTitleResolver.sanitized(selected))](\(target))"
        replace(selection, with: markdown)
        let end = selection.location + (markdown as NSString).length
        setSelectedRange(NSRange(location: target.isEmpty ? end - 1 : end, length: 0))
    }

    enum BlockCommand {
        case block(MarkdownStyler.BlockKind)
        case codeBlock

        init?(keyCode: UInt16) {
            switch keyCode {
            case 29: self = .block(.paragraph)          // 0
            case 18: self = .block(.heading(level: 1))  // 1
            case 19: self = .block(.heading(level: 2))  // 2
            case 20: self = .block(.heading(level: 3))  // 3
            case 21: self = .block(.todo(checked: false)) // 4
            case 23: self = .block(.bullet)             // 5
            case 22: self = .block(.ordered(number: 1)) // 6
            case 12: self = .block(.quote)              // Q
            case 8: self = .codeBlock                   // C
            default: return nil
            }
        }
    }

    func perform(_ command: BlockCommand) {
        switch command {
        case .block(let kind): setBlock(kind)
        case .codeBlock: wrapInCodeBlock()
        }
    }

    /// Turns the selected lines into a block kind; applying the kind they already have turns them back into text
    func setBlock(_ kind: MarkdownStyler.BlockKind, toggles: Bool = true) {
        let selection = selectedRange()
        let block = selectedLines()
        let lines = nsString.substring(with: block).components(separatedBy: "\n")
        let prefixes = lines.map(MarkdownStyler.linePrefix)
        let isAlready = toggles && prefixes.allSatisfy { $0.kind.isSameFamily(as: kind) }

        var number = 0
        let rewritten = lines.map { line -> String in
            if lines.count > 1, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if isAlready { return MarkdownStyler.transform(line: line, to: .paragraph) }
            if case .ordered = kind {
                number += 1
                return MarkdownStyler.transform(line: line, to: .ordered(number: number))
            }
            return MarkdownStyler.transform(line: line, to: kind)
        }
        let newText = rewritten.joined(separator: "\n")
        replace(block, with: newText)

        if lines.count == 1 {
            // Keep the caret on the same letter of the text
            let offset = max(0, selection.location - block.location - prefixes[0].length)
            let body = (MarkdownStyler.content(ofLine: lines[0]) as NSString).length
            // (measured, not re-parsed: an empty `## ` is not a heading yet)
            let newPrefix = (newText as NSString).length - body
            let location = block.location + min(newPrefix + offset, (newText as NSString).length)
            setSelectedRange(NSRange(location: location, length: min(selection.length, nsString.length - location)))
        } else {
            setSelectedRange(NSRange(location: block.location, length: (newText as NSString).length))
        }
    }

    func wrapInCodeBlock() {
        let block = selectedLines()
        let body = nsString.substring(with: block)
        replace(block, with: "```\n" + body + "\n```")
        setSelectedRange(NSRange(location: block.location + 4, length: (body as NSString).length))
    }

    // MARK: - Slash menu

    /// A `/` at a line start or after a space opens the menu (not one inside a URL or a date)
    private func openSlashMenuIfAtWordStart() {
        let slash = selectedRange().location - 1
        guard slash >= 0, selectedRange().length == 0 else { return }
        if slash > 0 {
            let before = nsString.substring(with: nsString.rangeOfComposedCharacterSequence(at: slash - 1))
            guard before.allSatisfy(\.isWhitespace) else { return }
        }
        slashAnchor = slash
        slashMenu.model.selection = 0
        updateSlashMenu()
    }

    /// Filters the menu by what was typed after the `/`; closes it once the caret leaves or nothing matches
    func updateSlashMenu() {
        guard let anchor = slashAnchor, !hasMarkedText() else { return }
        let caret = selectedRange()
        guard caret.length == 0, caret.location > anchor, anchor < nsString.length,
              SlashCommand.triggers.contains(nsString.substring(with: NSRange(location: anchor, length: 1))) else {
            dismissSlashMenu()
            return
        }
        let query = nsString.substring(with: NSRange(location: anchor + 1, length: caret.location - anchor - 1))
        let commands = SlashCommand.matching(query)
        guard !query.contains(where: \.isWhitespace), !commands.isEmpty else {
            dismissSlashMenu()
            return
        }
        let model = slashMenu.model
        if model.commands != commands {
            model.commands = commands
            model.selection = 0
        }
        guard let window else { return }
        let anchorRect = firstRect(forCharacterRange: NSRange(location: anchor, length: 1), actualRange: nil)
        slashMenu.show(below: anchorRect, in: window) { [weak self] command in
            self?.chooseSlashCommand(command)
        }
    }

    func dismissSlashMenu() {
        slashAnchor = nil
        slashMenu.hide()
    }

    var isSlashMenuOpen: Bool { slashAnchor != nil }

    /// Removes the typed `/query` and turns the line into the chosen block, as one replacement (one undo step)
    func chooseSlashCommand(_ command: SlashCommand) {
        guard let anchor = slashAnchor else { return }
        let end = max(anchor + 1, selectedRange().location)
        dismissSlashMenu()

        let lineRange = line(at: anchor)
        let query = NSRange(location: anchor - lineRange.location, length: end - anchor)
        let text = (nsString.substring(with: lineRange) as NSString).replacingCharacters(in: query, with: "")
        let caret = query.location
        let length = { (string: String) in (string as NSString).length }
        let isBlank = text.trimmingCharacters(in: .whitespaces).isEmpty

        let newText: String
        let newCaret: Int
        switch command.action {
        case .block(let kind):
            newText = MarkdownStyler.transform(line: text, to: kind)
            let oldPrefix = length(text) - length(MarkdownStyler.content(ofLine: text))
            let newPrefix = length(newText) - length(MarkdownStyler.content(ofLine: text))
            newCaret = newPrefix + max(0, caret - oldPrefix)
        case .codeBlock:
            newText = isBlank ? "```\n\n```" : "```\n" + text + "\n```"
            newCaret = 4 + (isBlank ? 0 : caret)
        case .divider:
            newText = isBlank ? "---\n" : text + "\n---\n"
            newCaret = length(newText)
        }
        replace(lineRange, with: newText)
        setSelectedRange(NSRange(location: lineRange.location + newCaret, length: 0))
    }

    // MARK: - Links

    /// Pasting a URL: over selected words it links them; otherwise it becomes a page mention
    override func paste(_ sender: Any?) {
        guard !hasMarkedText(),
              let raw = NSPasteboard.general.string(forType: .string),
              let url = LinkTitleResolver.webURL(from: raw) else {
            super.paste(sender)
            return
        }
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = selectedRange()
        let selected = nsString.substring(with: selection)
        if selection.length > 0, !selected.contains("\n"), LinkTitleResolver.webURL(from: selected) == nil {
            replace(selection, with: "[\(LinkTitleResolver.sanitized(selected))](\(address))")
            return
        }
        insertMention(url: url, address: address, replacing: selection)
    }

    /// Inserts `[@Title](url)` titled from the URL right away, then swaps in the page's real title
    private func insertMention(url: URL, address: String, replacing range: NSRange) {
        let markdown = LinkTitleResolver.mention(title: LinkTitleResolver.provisionalTitle(for: url), url: address)
        replace(range, with: markdown)
        let inserted = NSRange(location: range.location, length: (markdown as NSString).length)
        setSelectedRange(NSRange(location: inserted.upperBound, length: 0))

        Task { [weak self] in
            guard let title = await LinkTitleResolver.fetchTitle(for: url) else { return }
            self?.retitleMention(at: inserted, from: markdown, title: title, address: address)
        }
    }

    private func retitleMention(at range: NSRange, from markdown: String, title: String, address: String) {
        // Leave it alone if it was edited (or another event's notes are showing) in the meantime
        guard range.upperBound <= nsString.length, nsString.substring(with: range) == markdown else { return }
        let replacement = LinkTitleResolver.mention(title: title, url: address)
        guard replacement != markdown else { return }
        let selection = selectedRange()
        let delta = (replacement as NSString).length - range.length
        replace(range, with: replacement)
        let location = selection.location >= range.upperBound ? selection.location + delta : min(selection.location, range.location)
        setSelectedRange(NSRange(location: min(location, nsString.length), length: 0))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(under: point) {
            if toggleCheckbox(at: index) { return }
            // ⌥-click places the caret in the link instead of opening it
            if event.clickCount == 1, !event.modifierFlags.contains(.option),
               let url = textStorage?.attribute(.mdLink, at: index, effectiveRange: nil) as? URL {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The character drawn under a point, or nil if the point is beside the text
    private func characterIndex(under point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard bounds.insetBy(dx: -2, dy: -2).contains(location) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Clicking a checkbox toggles it (undoable), leaving the caret where it was
    private func toggleCheckbox(at index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length,
              storage.attribute(.mdCheckbox, at: index, effectiveRange: nil) != nil else { return false }
        let lineRange = line(at: index)
        guard let offset = MarkdownStyler.checkboxOffset(inLine: nsString.substring(with: lineRange)) else { return false }
        let mark = NSRange(location: lineRange.location + offset, length: 1)
        let isDone = nsString.substring(with: mark).lowercased() == "x"
        let selection = selectedRange()
        replace(mark, with: isDone ? " " : "x")
        setSelectedRange(selection)
        return true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let format = NSMenu(title: "格式")
        let entries: [(String, String, NSEvent.ModifierFlags, Int)] = [
            ("粗体", "b", [.command], 1), ("斜体", "i", [.command], 2), ("删除线", "x", [.command, .shift], 3),
            ("行内代码", "e", [.command], 4), ("链接", "k", [.command], 5),
            ("", "", [], 0),
            ("正文", "0", [.command, .option], 10), ("标题 1", "1", [.command, .option], 11),
            ("标题 2", "2", [.command, .option], 12), ("标题 3", "3", [.command, .option], 13),
            ("待办", "4", [.command, .option], 14), ("无序列表", "5", [.command, .option], 15),
            ("有序列表", "6", [.command, .option], 16), ("引用", "q", [.command, .option], 17),
            ("代码块", "c", [.command, .option], 18),
        ]
        for (title, key, modifiers, tag) in entries {
            guard tag != 0 else {
                format.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(formatFromMenu(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.tag = tag
            format.addItem(item)
        }
        let formatItem = NSMenuItem(title: "格式", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        menu.insertItem(formatItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func formatFromMenu(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: toggleInline("**")
        case 2: toggleInline("*")
        case 3: toggleInline("~~")
        case 4: toggleInline("`")
        case 5: insertLink()
        case 10: setBlock(.paragraph)
        case 11, 12, 13: setBlock(.heading(level: sender.tag - 10))
        case 14: setBlock(.todo(checked: false))
        case 15: setBlock(.bullet)
        case 16: setBlock(.ordered(number: 1))
        case 17: setBlock(.quote)
        case 18: wrapInCodeBlock()
        default: break
        }
    }
}
