import AppKit

/// Custom attributes read by `MarkdownLayoutManager` to hide markers and draw block decorations
extension NSAttributedString.Key {
    /// Concealed syntax: generates no glyph, so it takes no space
    static let mdHidden = NSAttributedString.Key("ImmerseMarkdownHidden")
    /// Bullet marker `- `; value is the nesting level (Int)
    static let mdBullet = NSAttributedString.Key("ImmerseMarkdownBullet")
    /// To-do marker `- [ ] `; value is whether it is checked (Bool)
    static let mdCheckbox = NSAttributedString.Key("ImmerseMarkdownCheckbox")
    static let mdQuote = NSAttributedString.Key("ImmerseMarkdownQuote")
    /// Fenced code block; value is the block start (Int), so adjacent blocks stay apart
    static let mdCodeBlock = NSAttributedString.Key("ImmerseMarkdownCodeBlock")
    static let mdRule = NSAttributedString.Key("ImmerseMarkdownRule")
    /// Link text rendered as a pill (link text starting with `@`)
    static let mdMention = NSAttributedString.Key("ImmerseMarkdownMention")
    /// Clickable link target (URL)
    static let mdLink = NSAttributedString.Key("ImmerseMarkdownLink")
}

/// Live-preview Markdown, Typora style: the source stays Markdown, but syntax is concealed and rendered
/// unless the caret is inside it (inline elements) or on its line (headings, quotes).
/// Three steps: `spans(in:)` is a pure parse (easy to test), `revealState` decides what the caret uncovers,
/// `apply` writes the attributes into the NSTextStorage.
enum MarkdownStyler {
    struct Span: Equatable {
        enum Kind: Equatable {
            case heading(level: Int)
            /// Syntax such as `#`, `**`, `[`, `](url)`; concealed unless revealed
            case marker
            case bold
            case italic
            case strike
            case code
            case codeBlock
            /// The ``` lines of a code block
            case fence
            case quote
            /// A checked to-do
            case done
            case link(url: String)
            /// A link whose text starts with `@`: a pasted page reference, drawn as a pill
            case mention(url: String)
            case bullet(level: Int)
            case checkbox(checked: Bool)
            case ordered
            case rule
        }

        let range: NSRange
        let kind: Kind
        /// Caret inside (or touching) this range uncovers the syntax; nil = always rendered the same
        var reveal: NSRange?

        init(range: NSRange, kind: Kind, reveal: NSRange? = nil) {
            self.range = range
            self.kind = kind
            self.reveal = reveal
        }
    }

    static let fontSize: CGFloat = 14

    // MARK: - Parsing

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are hard-coded constants; a failure here is a code bug
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let headingPattern = regex(#"^(#{1,6})[ \t]+(?=\S)"#)
    private static let rulePattern = regex(#"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let quotePattern = regex(#"^>[ \t]?"#)
    private static let taskPattern = regex(#"^([ \t]*)([-*+][ \t]\[([ xX])\](?:[ \t]|$))"#)
    private static let bulletPattern = regex(#"^([ \t]*)([-*+][ \t])"#)
    private static let orderedPattern = regex(#"^([ \t]*)((\d{1,9})([.)])[ \t])"#)
    private static let fencePattern = regex(#"^[ \t]*```"#)

    private static let codePattern = regex(#"`([^`\n]+)`"#)
    private static let linkPattern = regex(#"(?<!!)\[([^\[\]\n]+)\]\(([^()\s]+)\)"#)
    private static let boldPattern = regex(#"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#)
    private static let italicPattern = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?!\*)"#)
    private static let underscoreItalicPattern = regex(#"(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=\S)_(?![_\w])"#)
    private static let strikePattern = regex(#"~~(?=\S)([^~\n]+?)(?<=\S)~~"#)
    private static let urlDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }

        var spans: [Span] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if fencePattern.firstMatch(in: text, range: line) != nil {
                // Code block: up to the closing ``` (an unclosed fence runs to the end)
                var close = index + 1
                while close < lines.count, fencePattern.firstMatch(in: text, range: lines[close]) == nil { close += 1 }
                let last = lines[min(close, lines.count - 1)]
                let block = NSRange(location: line.location, length: last.upperBound - line.location)
                spans.append(Span(range: block, kind: .codeBlock))
                spans.append(Span(range: line, kind: .fence, reveal: block))
                if close < lines.count { spans.append(Span(range: lines[close], kind: .fence, reveal: block)) }
                index = close + 1
                continue
            }
            spans += blockSpans(in: string, line: line)
            spans += inlineSpans(in: string, line: line)
            index += 1
        }
        return spans
    }

    private static func blockSpans(in string: NSString, line: NSRange) -> [Span] {
        let text = string as String
        if let match = headingPattern.firstMatch(in: text, range: line) {
            let level = match.range(at: 1).length
            return [Span(range: line, kind: .heading(level: level)), Span(range: match.range, kind: .marker, reveal: line)]
        }
        if rulePattern.firstMatch(in: text, range: line) != nil {
            return [Span(range: line, kind: .rule, reveal: line)]
        }
        if let match = quotePattern.firstMatch(in: text, range: line) {
            return [Span(range: line, kind: .quote), Span(range: match.range, kind: .marker, reveal: line)]
        }
        if let match = taskPattern.firstMatch(in: text, range: line) {
            let isDone = string.substring(with: match.range(at: 3)).lowercased() == "x"
            var result = [Span(range: match.range(at: 2), kind: .checkbox(checked: isDone))]
            let rest = NSRange(location: match.range.upperBound, length: line.upperBound - match.range.upperBound)
            if isDone && rest.length > 0 { result.append(Span(range: rest, kind: .done)) }
            return result
        }
        if let match = bulletPattern.firstMatch(in: text, range: line) {
            let level = indentColumns(string.substring(with: match.range(at: 1))) / 2
            return [Span(range: match.range(at: 2), kind: .bullet(level: level))]
        }
        if let match = orderedPattern.firstMatch(in: text, range: line) {
            return [Span(range: match.range(at: 2), kind: .ordered)]
        }
        return []
    }

    private static func inlineSpans(in string: NSString, line: NSRange) -> [Span] {
        let text = string as String
        var result: [Span] = []
        // Ranges whose content is literal: code, link targets, bare URLs (they often contain `_` or `*`)
        var literal: [NSRange] = []
        func isFree(_ range: NSRange) -> Bool {
            !literal.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in codePattern.matches(in: text, range: line) {
            literal.append(match.range)
            result += wrapped(match, kind: .code, markerLength: 1)
        }

        var linkRanges: [NSRange] = []
        for match in linkPattern.matches(in: text, range: line) where isFree(match.range) {
            let full = match.range
            let label = match.range(at: 1)
            let url = string.substring(with: match.range(at: 2))
            // Strictly inside: a caret right after the link keeps it rendered
            let inner = NSRange(location: full.location + 1, length: full.length - 2)
            let tail = NSRange(location: label.upperBound, length: full.upperBound - label.upperBound)
            let isMention = string.substring(with: label).hasPrefix("@")
            result += [
                Span(range: label, kind: isMention ? .mention(url: url) : .link(url: url), reveal: inner),
                Span(range: NSRange(location: full.location, length: 1), kind: .marker, reveal: inner),
                Span(range: tail, kind: .marker, reveal: inner),
            ]
            linkRanges.append(full)
            literal.append(tail)
        }

        for match in urlDetector.matches(in: text, range: line) {
            let range = match.range
            let candidate = string.substring(with: range)
            guard candidate.contains("://"), isFree(range),
                  !linkRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            literal.append(range)
            result.append(Span(range: range, kind: .link(url: match.url?.absoluteString ?? candidate)))
        }

        for match in boldPattern.matches(in: text, range: line) where isFree(match.range) {
            result += wrapped(match, kind: .bold, markerLength: 2)
        }
        for pattern in [italicPattern, underscoreItalicPattern] {
            for match in pattern.matches(in: text, range: line) where isFree(match.range) {
                result += wrapped(match, kind: .italic, markerLength: 1)
            }
        }
        for match in strikePattern.matches(in: text, range: line) where isFree(match.range) {
            result += wrapped(match, kind: .strike, markerLength: 2)
        }
        return result
    }

    /// Content gets the kind style, the markers at both ends are concealed until the caret touches the element
    private static func wrapped(_ match: NSTextCheckingResult, kind: Span.Kind, markerLength: Int) -> [Span] {
        let range = match.range
        return [
            Span(range: match.range(at: 1), kind: kind),
            Span(range: NSRange(location: range.location, length: markerLength), kind: .marker, reveal: range),
            Span(range: NSRange(location: range.upperBound - markerLength, length: markerLength), kind: .marker, reveal: range),
        ]
    }

    private static func indentColumns(_ indent: String) -> Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }

    // MARK: - Reveal

    /// A caret reveals a range it sits in or touches; a selection reveals what it overlaps
    static func isRevealed(_ range: NSRange, by selections: [NSRange]) -> Bool {
        selections.contains { selection in
            if selection.length == 0 {
                return selection.location >= range.location && selection.location <= range.upperBound
            }
            return NSIntersectionRange(selection, range).length > 0
        }
    }

    /// Which concealable spans the selection uncovers; restyling is only needed when this changes
    static func revealState(of spans: [Span], selections: [NSRange]) -> [Bool] {
        spans.compactMap { span in span.reveal.map { isRevealed($0, by: selections) } }
    }

    // MARK: - Styling

    private static let indentSpaceWidth: CGFloat = 10
    private static let bulletWidth: CGFloat = 20
    private static let checkboxWidth: CGFloat = 24
    private static let quoteIndent: CGFloat = 16
    private static let codeIndent: CGFloat = 12

    static var baseParagraph: NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return paragraph
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: baseParagraph,
        ]
    }

    /// Restyles the whole text. Changes attributes only, not characters, so nothing goes on the undo stack.
    @MainActor
    static func apply(_ spans: [Span], to storage: NSTextStorage, selections: [NSRange]) {
        let full = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        // Block level first, then inline, then markers; later passes override earlier ones
        let order: (Span.Kind) -> Int = { kind in
            switch kind {
            case .heading, .codeBlock, .quote, .done: 0
            case .bold, .italic, .strike, .code, .link, .mention: 1
            case .marker, .fence, .bullet, .checkbox, .ordered, .rule: 2
            }
        }
        for span in spans.sorted(by: { order($0.kind) < order($1.kind) }) where span.range.upperBound <= storage.length {
            let revealed = span.reveal.map { isRevealed($0, by: selections) } ?? false
            style(span, revealed: revealed, in: storage)
        }
        // Font fallback for characters the system font lacks (CJK, emoji)
        storage.fixAttributes(in: full)
        storage.endEditing()

        // Hidden markers change glyph generation, not just drawing
        for layoutManager in storage.layoutManagers {
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    @MainActor
    private static func style(_ span: Span, revealed: Bool, in storage: NSTextStorage) {
        let range = span.range
        let fonts = NSFontManager.shared
        let concealed: [NSAttributedString.Key: Any] = [.mdHidden: true, .foregroundColor: NSColor.clear]

        switch span.kind {
        case .heading(let level):
            let sizes: [CGFloat] = [24, 20, 17, 15]
            let size = sizes[min(level, sizes.count) - 1]
            let paragraph = baseParagraph
            paragraph.paragraphSpacingBefore = level == 1 ? 8 : 4
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold),
                .paragraphStyle: paragraph,
            ], range: paragraphRange(of: range, in: storage))

        case .marker:
            if revealed {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            } else {
                storage.addAttributes(concealed, range: range)
            }

        case .fence:
            if revealed {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ], range: range)
            } else {
                // Collapse the line to a sliver so the block reads as just its code
                // (the newline must keep its glyph, or the line break would disappear)
                let paragraph = baseParagraph
                paragraph.lineSpacing = 0
                paragraph.minimumLineHeight = 6
                paragraph.maximumLineHeight = 6
                let line = paragraphRange(of: range, in: storage)
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: paragraph], range: line)
                storage.addAttributes(concealed, range: range)
            }

        case .bold:
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: fontSize)
                storage.addAttribute(.font, value: fonts.convert(font, toHaveTrait: .boldFontMask), range: sub)
            }
        case .italic:
            // CJK fonts have no italic glyphs, so fall back to an oblique skew
            storage.addAttribute(.obliqueness, value: 0.18, range: range)
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .code:
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                .foregroundColor: NSColor.systemPink,
            ], range: range)

        case .codeBlock:
            let paragraph = baseParagraph
            paragraph.lineSpacing = 3
            paragraph.firstLineHeadIndent = codeIndent
            paragraph.headIndent = codeIndent
            paragraph.tailIndent = -codeIndent
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                .mdCodeBlock: range.location,
                .paragraphStyle: paragraph,
            ], range: range)

        case .quote:
            let paragraph = baseParagraph
            paragraph.firstLineHeadIndent = quoteIndent
            paragraph.headIndent = quoteIndent
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .mdQuote: true,
                .paragraphStyle: paragraph,
            ], range: paragraphRange(of: range, in: storage))

        case .done:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ], range: range)

        case .link(let url), .mention(let url):
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.linkColor]
            if case .link = span.kind {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = NSColor.linkColor.withAlphaComponent(0.35)
            }
            // While being edited the link is plain text, so clicks place the caret instead of opening it
            if !revealed, let target = URL(string: url) {
                attributes[.mdLink] = target
                attributes[.cursor] = NSCursor.pointingHand
                attributes[.toolTip] = url
                if case .mention = span.kind { attributes[.mdMention] = true }
            }
            storage.addAttributes(attributes, range: range)

        case .bullet(let level):
            storage.addAttributes([.foregroundColor: NSColor.clear, .mdBullet: level], range: range)
            layOutListMarker(range, width: bulletWidth, in: storage)

        case .checkbox(let checked):
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .mdCheckbox: checked,
                .cursor: NSCursor.pointingHand,
            ], range: range)
            layOutListMarker(range, width: checkboxWidth, in: storage)

        case .ordered:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            layOutListMarker(range, width: bulletWidth, in: storage)

        case .rule:
            if revealed {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            } else {
                storage.addAttributes([.foregroundColor: NSColor.clear, .mdRule: true], range: range)
            }
        }
    }

    /// Gives a list marker a fixed width (so text lines up) and indents wrapped lines under the text
    @MainActor
    private static func layOutListMarker(_ marker: NSRange, width: CGFloat, in storage: NSTextStorage) {
        let string = storage.string as NSString
        let paragraphRange = string.paragraphRange(for: marker)
        let font = NSFont.systemFont(ofSize: fontSize)

        // Leading spaces are widened so nesting is visible
        var indentWidth: CGFloat = 0
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        for offset in 0..<(marker.location - paragraphRange.location) {
            let index = paragraphRange.location + offset
            if string.character(at: index) == 0x20 {
                storage.addAttribute(.kern, value: indentSpaceWidth - spaceWidth, range: NSRange(location: index, length: 1))
                indentWidth += indentSpaceWidth
            } else {
                indentWidth += 28 // default tab stop interval
            }
        }

        let natural = string.substring(with: marker).size(withAttributes: [.font: font]).width
        let target = max(width, natural)
        let last = NSRange(location: marker.upperBound - 1, length: 1)
        storage.addAttribute(.kern, value: target - natural, range: last)

        let paragraph = baseParagraph
        paragraph.headIndent = indentWidth + target
        storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
    }

    private static func paragraphRange(of range: NSRange, in storage: NSTextStorage) -> NSRange {
        (storage.string as NSString).paragraphRange(for: range)
    }

    // MARK: - Block structure

    enum BlockKind: Equatable {
        case paragraph
        case heading(level: Int)
        case quote
        case bullet
        case todo(checked: Bool)
        case ordered(number: Int)

        var isList: Bool {
            switch self {
            case .bullet, .todo, .ordered: true
            default: false
            }
        }

        /// Same kind of block, ignoring the check state / number
        func isSameFamily(as other: BlockKind) -> Bool {
            switch (self, other) {
            case (.todo, .todo), (.ordered, .ordered): true
            default: self == other
            }
        }
    }

    /// The syntax at the start of a line: indentation + block marker
    struct LinePrefix: Equatable {
        var indent: String
        var marker: String
        var kind: BlockKind

        /// UTF-16 length, to be used with NSString ranges
        var length: Int { ((indent + marker) as NSString).length }
    }

    static func linePrefix(_ line: String) -> LinePrefix {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String { ns.substring(with: match.range(at: index)) }

        if let match = headingPattern.firstMatch(in: line, range: range) {
            return LinePrefix(indent: "", marker: ns.substring(with: match.range), kind: .heading(level: match.range(at: 1).length))
        }
        if rulePattern.firstMatch(in: line, range: range) != nil {
            return LinePrefix(indent: "", marker: "", kind: .paragraph)
        }
        if let match = quotePattern.firstMatch(in: line, range: range) {
            return LinePrefix(indent: "", marker: ns.substring(with: match.range), kind: .quote)
        }
        if let match = taskPattern.firstMatch(in: line, range: range) {
            return LinePrefix(indent: group(match, 1), marker: group(match, 2), kind: .todo(checked: group(match, 3).lowercased() == "x"))
        }
        if let match = bulletPattern.firstMatch(in: line, range: range) {
            return LinePrefix(indent: group(match, 1), marker: group(match, 2), kind: .bullet)
        }
        if let match = orderedPattern.firstMatch(in: line, range: range) {
            return LinePrefix(indent: group(match, 1), marker: group(match, 2), kind: .ordered(number: Int(group(match, 3)) ?? 1))
        }
        return LinePrefix(indent: "", marker: "", kind: .paragraph)
    }

    /// Text after the line's block syntax
    static func content(ofLine line: String) -> String {
        (line as NSString).substring(from: linePrefix(line).length)
    }

    /// Rewrites a line as another block kind, keeping its text (and indentation for lists)
    static func transform(line: String, to kind: BlockKind) -> String {
        let prefix = linePrefix(line)
        let body = content(ofLine: line)
        let indent = prefix.kind.isList ? prefix.indent : ""
        switch kind {
        case .paragraph: return body
        case .heading(let level): return String(repeating: "#", count: level) + " " + body
        case .quote: return "> " + body
        case .bullet: return indent + "- " + body
        case .todo(let checked): return indent + (checked ? "- [x] " : "- [ ] ") + body
        case .ordered(let number): return indent + "\(number). " + body
        }
    }

    // MARK: - Editing helpers

    /// Continues the list marker on Return. Returns nil if not a list line; returns an empty string for an empty list item, which should end the list (remove the marker)
    static func continuation(forLine line: String) -> String? {
        let prefix = linePrefix(line)
        let body = content(ofLine: line).trimmingCharacters(in: .whitespaces)
        let next: String
        switch prefix.kind {
        case .paragraph, .heading:
            return nil
        case .quote:
            next = "> "
        case .bullet:
            next = prefix.indent + prefix.marker
        case .todo:
            next = prefix.indent + "- [ ] "
        case .ordered(let number):
            let delimiter = prefix.marker.contains(")") ? ")" : "."
            next = prefix.indent + "\(number + 1)\(delimiter) "
        }
        return body.isEmpty ? "" : next
    }

    /// Position of the character inside the `[ ]` / `[x]` checkbox at the line start (relative to line start); nil if not a to-do line
    static func checkboxOffset(inLine line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return taskPattern.firstMatch(in: line, range: range)?.range(at: 3).location
    }
}
