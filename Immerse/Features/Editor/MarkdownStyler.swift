import AppKit

/// 轻量 Markdown 高亮：只识别备注里常用的语法，原样保留标记符号（变淡），不做渲染转换。
/// 分两步：`spans(in:)` 纯计算出每段文字的样式（便于测试），`apply(to:)` 把样式写进 NSTextStorage。
enum MarkdownStyler {
    struct Span: Equatable {
        enum Kind: Equatable {
            case heading(level: Int)
            /// `#`、`**`、`- `、`[ ]` 这类标记符号
            case marker
            case bold
            case italic
            case code
            case codeBlock
            case quote
            /// 已勾选的待办
            case done
        }

        let range: NSRange
        let kind: Kind
    }

    static let fontSize: CGFloat = 14

    // MARK: - 解析

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 模式都是写死的常量，出错就是代码 bug
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let headingPattern = regex(#"^(#{1,3})\s+\S.*$"#)
    private static let quotePattern = regex(#"^>\s?"#)
    private static let taskPattern = regex(#"^\s*[-*+]\s\[([ xX])\]\s?"#)
    private static let listPattern = regex(#"^\s*(?:[-*+]|\d+\.)\s"#)
    private static let rulePattern = regex(#"^(?:-{3,}|\*{3,})\s*$"#)
    private static let codePattern = regex(#"`([^`\n]+)`"#)
    private static let boldPattern = regex(#"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#)
    private static let italicPattern = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?!\*)"#)

    static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var inFence = false

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let content = string.substring(with: line)

            // ``` 代码块
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                spans.append(Span(range: line, kind: .codeBlock))
                spans.append(Span(range: line, kind: .marker))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(Span(range: line, kind: .codeBlock))
                return
            }

            spans += blockSpans(in: string, line: line)
            spans += inlineSpans(in: string, line: line)
        }
        return spans
    }

    private static func blockSpans(in string: NSString, line: NSRange) -> [Span] {
        if let match = headingPattern.firstMatch(in: string as String, range: line) {
            let level = match.range(at: 1).length
            let marker = NSRange(location: line.location, length: level + 1)
            return [Span(range: line, kind: .heading(level: level)), Span(range: marker, kind: .marker)]
        }
        if let match = quotePattern.firstMatch(in: string as String, range: line) {
            return [Span(range: line, kind: .quote), Span(range: match.range, kind: .marker)]
        }
        if let match = taskPattern.firstMatch(in: string as String, range: line) {
            var result = [Span(range: match.range, kind: .marker)]
            let isDone = string.substring(with: match.range(at: 1)).lowercased() == "x"
            let rest = NSRange(location: match.range.upperBound, length: line.upperBound - match.range.upperBound)
            if isDone && rest.length > 0 { result.append(Span(range: rest, kind: .done)) }
            return result
        }
        if let match = listPattern.firstMatch(in: string as String, range: line) {
            return [Span(range: match.range, kind: .marker)]
        }
        if rulePattern.firstMatch(in: string as String, range: line) != nil {
            return [Span(range: line, kind: .marker)]
        }
        return []
    }

    private static func inlineSpans(in string: NSString, line: NSRange) -> [Span] {
        var result: [Span] = []
        var codeRanges: [NSRange] = []

        for match in codePattern.matches(in: string as String, range: line) {
            codeRanges.append(match.range)
            result += wrapped(match, kind: .code, markerLength: 1)
        }
        // 代码里的 * 不算粗体 / 斜体
        func outsideCode(_ range: NSRange) -> Bool {
            !codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for match in boldPattern.matches(in: string as String, range: line) where outsideCode(match.range) {
            result += wrapped(match, kind: .bold, markerLength: 2)
        }
        for match in italicPattern.matches(in: string as String, range: line) where outsideCode(match.range) {
            result += wrapped(match, kind: .italic, markerLength: 1)
        }
        return result
    }

    /// 内容用 kind 样式，两端的标记符号用 marker 样式
    private static func wrapped(_ match: NSTextCheckingResult, kind: Span.Kind, markerLength: Int) -> [Span] {
        let range = match.range
        return [
            Span(range: match.range(at: 1), kind: kind),
            Span(range: NSRange(location: range.location, length: markerLength), kind: .marker),
            Span(range: NSRange(location: range.upperBound - markerLength, length: markerLength), kind: .marker),
        ]
    }

    // MARK: - 样式

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// 重新给整段文字上样式。只改属性不改字符，不会进撤销栈。
    @MainActor
    static func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let spans = spans(in: storage.string)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        // 先块级、再行内、最后标记符号，后面的覆盖前面的
        let order: (Span.Kind) -> Int = { kind in
            switch kind {
            case .heading, .codeBlock, .quote, .done: 0
            case .bold, .italic, .code: 1
            case .marker: 2
            }
        }
        for span in spans.sorted(by: { order($0.kind) < order($1.kind) }) where span.range.upperBound <= storage.length {
            style(span, in: storage)
        }
        storage.endEditing()
    }

    @MainActor
    private static func style(_ span: Span, in storage: NSTextStorage) {
        let range = span.range
        let fonts = NSFontManager.shared
        switch span.kind {
        case .heading(let level):
            let size: CGFloat = [22, 18, 16][min(level, 3) - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
        case .marker:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .bold:
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: fontSize)
                storage.addAttribute(.font, value: fonts.convert(font, toHaveTrait: .boldFontMask), range: sub)
            }
        case .italic:
            // 中文字体没有斜体字形，用倾斜度兜底
            storage.addAttribute(.obliqueness, value: 0.18, range: range)
        case .code:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                .foregroundColor: NSColor.systemPink,
            ], range: range)
        case .codeBlock:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .done:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: range)
        }
    }

    // MARK: - 编辑辅助

    /// 回车时续写列表标记。返回 nil 表示不是列表行；返回空串表示空列表项，应结束列表（删掉标记）
    static func continuation(forLine line: String) -> String? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let match: NSTextCheckingResult?
        let next: (String) -> String
        if let m = taskPattern.firstMatch(in: line, range: range) {
            match = m
            next = { indent in "\(indent)- [ ] " }
        } else if let m = regex(#"^(\s*)(\d+)\.\s"#).firstMatch(in: line, range: range) {
            match = m
            let number = Int(ns.substring(with: m.range(at: 2))) ?? 0
            next = { indent in "\(indent)\(number + 1). " }
        } else if let m = regex(#"^\s*([-*+])\s"#).firstMatch(in: line, range: range) {
            match = m
            let bullet = ns.substring(with: m.range(at: 1))
            next = { indent in "\(indent)\(bullet) " }
        } else if let m = quotePattern.firstMatch(in: line, range: range) {
            match = m
            next = { _ in "> " }
        } else {
            return nil
        }
        guard let match else { return nil }
        let body = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return "" }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return next(indent)
    }

    /// 行首待办复选框 `[ ]` / `[x]` 中间那个字符的位置（相对行首），不是待办行返回 nil
    static func checkboxOffset(inLine line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return taskPattern.firstMatch(in: line, range: range)?.range(at: 1).location
    }
}
