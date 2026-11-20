import AppKit
import Testing
@testable import Immerse

/// Drives the real editor text view: typing shortcuts, Return / Backspace / Tab, formatting commands, reveal
@MainActor
struct MarkdownTextViewTests {
    /// Keeps the delegates alive: NSTextView holds its delegate weakly
    private static var coordinators: [MarkdownEditor.Coordinator] = []

    private func makeEditor(_ text: String, caret: Int? = nil) -> (MarkdownTextView, NSWindow) {
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: 10_000))
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        let coordinator = MarkdownEditor.Coordinator(text: .constant(""))
        Self.coordinators.append(coordinator)
        textView.delegate = coordinator
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        textView.restyle(force: true)
        return (textView, window)
    }

    private func type(_ text: String, into textView: MarkdownTextView) {
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        textView.restyle()
    }

    @Test func 方括号加空格变成待办() {
        let (view, _) = makeEditor("")
        type("[] 买书", into: view)
        #expect(view.string == "- [ ] 买书")

        let (chinese, _) = makeEditor("  ")
        type("【】 缩进", into: chinese)
        #expect(chinese.string == "  - [ ] 缩进")
    }

    @Test func 回车续写和结束列表() {
        let (view, _) = makeEditor("- 买菜")
        #expect(view.handleReturn())
        #expect(view.string == "- 买菜\n- ")
        #expect(view.handleReturn())
        #expect(view.string == "- 买菜\n")

        let (ordered, _) = makeEditor("1. 一")
        #expect(ordered.handleReturn())
        #expect(ordered.string == "1. 一\n2. ")

        let (nested, _) = makeEditor("  - ")
        #expect(nested.handleReturn())
        #expect(nested.string == "- ")
    }

    @Test func 回车补全代码块() {
        let (view, _) = makeEditor("```")
        #expect(view.handleReturn())
        #expect(view.string == "```\n\n```")
        #expect(view.selectedRange().location == 4)
    }

    @Test func 行首退格还原为正文() {
        let (view, _) = makeEditor("- [ ] 待办", caret: 6)
        #expect(view.handleBackspace())
        #expect(view.string == "待办")
    }

    @Test func 退格删除整个提及() {
        let text = "看 [@页面](https://a.com)"
        let (view, _) = makeEditor(text)
        #expect(view.handleBackspace())
        #expect(view.string == "看 ")
    }

    @Test func Tab缩进列表() {
        let (view, _) = makeEditor("- a\n- b", caret: 7)
        #expect(view.indentListItems(outward: false))
        #expect(view.string == "- a\n  - b")
        #expect(view.indentListItems(outward: true))
        #expect(view.string == "- a\n- b")

        let (plain, _) = makeEditor("正文")
        #expect(!plain.indentListItems(outward: false))
    }

    @Test func 粗体切换() {
        let (view, _) = makeEditor("重点")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.toggleInline("**")
        #expect(view.string == "**重点**")
        #expect(view.selectedRange() == NSRange(location: 2, length: 2))
        view.toggleInline("**")
        #expect(view.string == "重点")

        // ⌘I on bold text adds italics instead of stripping a bold star
        let (bold, _) = makeEditor("**重点**")
        bold.setSelectedRange(NSRange(location: 2, length: 2))
        bold.toggleInline("*")
        #expect(bold.string == "***重点***")
    }

    @Test func 切换块类型() {
        let (view, _) = makeEditor("标题", caret: 1)
        view.setBlock(.heading(level: 2))
        #expect(view.string == "## 标题")
        #expect(view.selectedRange().location == 4)
        view.setBlock(.heading(level: 2))
        #expect(view.string == "标题")

        let (lines, _) = makeEditor("一\n二")
        lines.setSelectedRange(NSRange(location: 0, length: 3))
        lines.setBlock(.ordered(number: 1))
        #expect(lines.string == "1. 一\n2. 二")

        let (empty, _) = makeEditor("")
        empty.setBlock(.heading(level: 1))
        #expect(empty.string == "# ")
        #expect(empty.selectedRange().location == 2)
    }

    @Test func 光标进入才显示源码() {
        let text = "前 [链接](https://a.com) 后"
        let (view, window) = makeEditor(text, caret: 0)
        #expect(window.makeFirstResponder(view))
        let bracket = 2
        #expect(view.textStorage?.attribute(.mdHidden, at: bracket, effectiveRange: nil) != nil)
        #expect(view.textStorage?.attribute(.mdLink, at: 3, effectiveRange: nil) is URL)

        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.restyle()
        #expect(view.textStorage?.attribute(.mdHidden, at: bracket, effectiveRange: nil) == nil)
        #expect(view.textStorage?.attribute(.mdLink, at: 3, effectiveRange: nil) == nil)
    }

    @Test func 编辑时实时渲染() {
        let (view, window) = makeEditor("")
        #expect(window.makeFirstResponder(view))
        type("说 **重点** 好", into: view)
        // Caret has left the bold: markers concealed, typed text is not hidden
        let markers = view.textStorage?.attribute(.mdHidden, at: 2, effectiveRange: nil)
        #expect(markers != nil)
        #expect(view.textStorage?.attribute(.mdHidden, at: (view.string as NSString).length - 1, effectiveRange: nil) == nil)
    }

    @Test func 输入的中文能显示() {
        let coordinator = MarkdownEditor.Coordinator(text: .constant(""))
        Self.coordinators.append(coordinator)
        let scrollView = MarkdownEditor.makeScrollView(text: "", delegate: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        let view = scrollView.documentView as! MarkdownTextView
        #expect(window.makeFirstResponder(view))

        type("abc ", into: view)
        // Pinyin input method: marked text, then the committed characters
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "abc 你好")

        let layoutManager = view.layoutManager!
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 4, length: 2), actualCharacterRange: nil)
        for glyph in glyphs.location..<glyphs.upperBound {
            #expect(!layoutManager.propertyForGlyph(at: glyph).contains(.null))
        }
        window.contentView = nil
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test func 快捷键在按键监听里处理() {
        let (view, window) = makeEditor("重点")
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(view.handleKeyDown(keyEvent("b", keyCode: 11, modifiers: .command, in: window)))
        #expect(view.string == "**重点**")
        // ⌥⌘2 by key code, whatever character the layout produces
        #expect(view.handleKeyDown(keyEvent("™", keyCode: 19, modifiers: [.command, .option], in: window)))
        #expect(view.string == "## **重点**")
        // ⌘K with nothing selected is left to the command palette
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!view.handleKeyDown(keyEvent("k", keyCode: 40, modifiers: .command, in: window)))
        // Plain typing is not touched
        #expect(!view.handleKeyDown(keyEvent("a", keyCode: 0, modifiers: [], in: window)))
    }

    @Test func 斜杠菜单() {
        let (view, window) = makeEditor("")
        #expect(window.makeFirstResponder(view))
        // No event loop here: group undo per key press by hand, as the app does per event
        let undo = view.undoManager!
        undo.groupsByEvent = false
        func keyPress(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }
        keyPress { type("/", into: view) }
        #expect(view.isSlashMenuOpen)
        keyPress { type("bt", into: view) }
        #expect(view.isSlashMenuOpen)
        // ↓ to 标题 2, Return to choose
        keyPress { #expect(view.handleKeyDown(keyEvent("", keyCode: 125, modifiers: [], in: window))) }
        keyPress { #expect(view.handleKeyDown(keyEvent("\r", keyCode: 36, modifiers: [], in: window))) }
        #expect(!view.isSlashMenuOpen)
        #expect(view.string == "## ")
        #expect(view.selectedRange().location == 3)

        // One undo restores the typed `/bt`
        undo.undo()
        #expect(view.string == "/bt")
        undo.groupsByEvent = true
    }

    @Test func 斜杠菜单关闭时机() {
        let (view, window) = makeEditor("见 a")
        #expect(window.makeFirstResponder(view))
        type("/", into: view)
        #expect(!view.isSlashMenuOpen) // inside a word, e.g. a URL or a date

        let (chinese, chineseWindow) = makeEditor("待办 ")
        #expect(chineseWindow.makeFirstResponder(chinese))
        type("、", into: chinese)
        #expect(chinese.isSlashMenuOpen)
        type("zzz", into: chinese)
        #expect(!chinese.isSlashMenuOpen) // nothing matches

        let (escape, escapeWindow) = makeEditor("")
        #expect(escapeWindow.makeFirstResponder(escape))
        type("/", into: escape)
        #expect(escape.handleKeyDown(keyEvent("\u{1b}", keyCode: 53, modifiers: [], in: escapeWindow)))
        #expect(!escape.isSlashMenuOpen)
        #expect(escape.string == "/")
    }

    @Test func 斜杠插入代码块和分隔线() {
        let (view, window) = makeEditor("")
        #expect(window.makeFirstResponder(view))
        type("/code", into: view)
        view.chooseSlashCommand(SlashCommand.matching("code")[0])
        #expect(view.string == "```\n\n```")
        #expect(view.selectedRange().location == 4)

        let (divider, dividerWindow) = makeEditor("")
        #expect(dividerWindow.makeFirstResponder(divider))
        type("/fgx", into: divider)
        divider.chooseSlashCommand(SlashCommand.matching("fgx")[0])
        #expect(divider.string == "---\n")
    }

    @Test func 斜杠指令过滤() {
        #expect(SlashCommand.matching("").count == SlashCommand.all.count)
        #expect(SlashCommand.matching("bt").map(\.id) == ["h1", "h2", "h3"])
        #expect(SlashCommand.matching("待办").map(\.id) == ["todo"])
        #expect(SlashCommand.matching("TODO").map(\.id) == ["todo"])
        #expect(SlashCommand.matching("列表").map(\.id) == ["bullet", "ordered"])
        #expect(SlashCommand.matching("xyz").isEmpty)
    }

    @Test func 光标跳过列表符号() {
        let (view, _) = makeEditor("一\n- 二")
        // Clicking onto the bullet lands after it
        #expect(view.snappedSelection(from: NSRange(location: 0, length: 0), to: NSRange(location: 2, length: 0)) == NSRange(location: 4, length: 0))
        // Arrowing left from the item text goes to the previous line
        #expect(view.snappedSelection(from: NSRange(location: 4, length: 0), to: NSRange(location: 3, length: 0)) == NSRange(location: 1, length: 0))
    }

    @Test func 输入法组字时隐藏占位提示() {
        let (view, window) = makeEditor("")
        view.placeholder = "添加备注…"
        #expect(window.makeFirstResponder(view))
        #expect(view.isShowingPlaceholder)

        // Pinyin still being composed: nothing is committed yet, but the letters are on screen
        view.setMarkedText("gao", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!view.isShowingPlaceholder)

        view.insertText("高", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "高")
        #expect(!view.isShowingPlaceholder)

        view.string = ""
        #expect(view.isShowingPlaceholder)
    }
}
