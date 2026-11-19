import AppKit

/// Renders what `MarkdownStyler` marks up: hides concealed syntax (null glyphs) and draws block decorations
/// — bullets, checkboxes, quote bars, code block backgrounds, rules and mention pills.
/// Markers keep their characters, so the source stays plain Markdown and caret positions map 1:1.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    // MARK: - Hidden glyphs

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var modified: [NSLayoutManager.GlyphProperty]?
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard index < storage.length, storage.attribute(.mdHidden, at: index, effectiveRange: nil) != nil else { continue }
            if modified == nil {
                modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            }
            modified?[offset] = .null
        }
        guard let modified else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    // MARK: - Decorations

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let full = NSRange(location: 0, length: storage.length)

        // Code blocks: one rounded background across the whole block
        var drawnBlocks = Set<Int>()
        storage.enumerateAttribute(.mdCodeBlock, in: characters) { value, range, _ in
            guard let start = value as? Int, drawnBlocks.insert(start).inserted else { return }
            var block = range
            _ = storage.attribute(.mdCodeBlock, at: range.location, longestEffectiveRange: &block, in: full)
            guard let rect = lineFragmentsRect(forCharacterRange: block) else { return }
            let background = NSRect(x: origin.x, y: origin.y + rect.minY,
                                    width: container.size.width, height: rect.height)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        }

        // Quotes: a bar down the left edge
        storage.enumerateAttribute(.mdQuote, in: characters) { value, range, _ in
            guard value != nil, let rect = lineFragmentsRect(forCharacterRange: range) else { return }
            let bar = NSRect(x: origin.x + 2, y: origin.y + rect.minY + 1, width: 3, height: rect.height - 2)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Mentions: a soft pill behind the page title
        storage.enumerateAttribute(.mdMention, in: characters) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: MarkdownStyler.fontSize)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let pill = NSRect(x: origin.x + rect.minX - 3, y: origin.y + rect.minY,
                                  width: rect.width + 6, height: min(rect.height, lineHeight + 1))
                NSColor.linkColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.mdBullet, in: characters) { value, range, _ in
            guard let level = value as? Int, let anchor = markerAnchor(forCharacterRange: range, origin: origin) else { return }
            let size: CGFloat = 5.5
            let dot = NSRect(x: anchor.x + 4, y: anchor.midY - size / 2, width: size, height: size)
            NSColor.labelColor.withAlphaComponent(0.8).set()
            switch level % 3 {
            case 0:
                NSBezierPath(ovalIn: dot).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            default:
                NSBezierPath(rect: dot.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        }

        storage.enumerateAttribute(.mdCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool, let anchor = markerAnchor(forCharacterRange: range, origin: origin) else { return }
            let side: CGFloat = 14
            let box = NSRect(x: anchor.x + 1, y: anchor.midY - side / 2, width: side, height: side)
            if checked {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY + 0.2))
                check.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 3.8))
                check.line(to: NSPoint(x: box.maxX - 3.2, y: box.minY + 4))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.2, yRadius: 3.2)
                outline.lineWidth = 1.2
                NSColor.secondaryLabelColor.setStroke()
                outline.stroke()
            }
        }

        storage.enumerateAttribute(.mdRule, in: characters) { value, range, _ in
            guard value != nil, let rect = lineFragmentsRect(forCharacterRange: range) else { return }
            let line = NSRect(x: origin.x, y: origin.y + rect.minY + (rect.height - 4) / 2,
                              width: container.size.width, height: 1)
            NSColor.separatorColor.setFill()
            line.fill()
        }
    }

    // MARK: - Geometry

    /// Union of the line fragments covering a character range (in container coordinates)
    private func lineFragmentsRect(forCharacterRange range: NSRange) -> NSRect? {
        // Hidden glyphs at a line start are laid out at the end of the previous line, so skip them
        var range = range
        while range.length > 1, let storage = textStorage,
              storage.attribute(.mdHidden, at: range.location, effectiveRange: nil) != nil {
            range = NSRange(location: range.location + 1, length: range.length - 1)
        }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var union: NSRect?
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            union = union.map { $0.union(rect) } ?? rect
        }
        return union
    }

    /// Left edge of a marker and the vertical center of its line's text (x-height middle), in view coordinates
    private func markerAnchor(forCharacterRange range: NSRange, origin: NSPoint) -> (x: CGFloat, midY: CGFloat)? {
        guard let storage = textStorage, let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = location(forGlyphAt: glyphs.location).y
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: MarkdownStyler.fontSize)
        // Flipped coordinates: the baseline sits `baseline` below the fragment top
        let midY = origin.y + fragment.minY + baseline - font.xHeight / 2 - 0.5
        return (origin.x + bounds.minX, midY)
    }
}
