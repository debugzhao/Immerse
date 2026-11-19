import AppKit
import SwiftUI

/// A block the `/` menu can insert (Notion-style slash command)
struct SlashCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case block(MarkdownStyler.BlockKind)
        case codeBlock
        case divider
    }

    let id: String
    let title: String
    /// SF Symbol name, or a label of up to two characters
    let icon: String
    /// The Markdown you could type instead, shown on the right
    let hint: String
    /// Matched against the query: English names, pinyin and pinyin initials
    let keywords: [String]
    let action: Action

    static let all: [SlashCommand] = [
        SlashCommand(id: "text", title: "正文", icon: "textformat", hint: "",
                     keywords: ["text", "paragraph", "p", "zhengwen", "zw"], action: .block(.paragraph)),
        SlashCommand(id: "h1", title: "标题 1", icon: "H1", hint: "#",
                     keywords: ["h1", "heading1", "title", "biaoti1", "bt1", "bt"], action: .block(.heading(level: 1))),
        SlashCommand(id: "h2", title: "标题 2", icon: "H2", hint: "##",
                     keywords: ["h2", "heading2", "biaoti2", "bt2", "bt"], action: .block(.heading(level: 2))),
        SlashCommand(id: "h3", title: "标题 3", icon: "H3", hint: "###",
                     keywords: ["h3", "heading3", "biaoti3", "bt3", "bt"], action: .block(.heading(level: 3))),
        SlashCommand(id: "todo", title: "待办", icon: "checkmark.square", hint: "[]",
                     keywords: ["todo", "task", "checkbox", "daiban", "db", "renwu"], action: .block(.todo(checked: false))),
        SlashCommand(id: "bullet", title: "无序列表", icon: "list.bullet", hint: "-",
                     keywords: ["bullet", "list", "ul", "liebiao", "lb", "wuxu", "wx"], action: .block(.bullet)),
        SlashCommand(id: "ordered", title: "有序列表", icon: "list.number", hint: "1.",
                     keywords: ["number", "ordered", "list", "ol", "liebiao", "lb", "youxu", "yx"], action: .block(.ordered(number: 1))),
        SlashCommand(id: "quote", title: "引用", icon: "text.quote", hint: ">",
                     keywords: ["quote", "blockquote", "yinyong", "yy"], action: .block(.quote)),
        SlashCommand(id: "code", title: "代码块", icon: "chevron.left.forwardslash.chevron.right", hint: "```",
                     keywords: ["code", "codeblock", "daima", "dm"], action: .codeBlock),
        SlashCommand(id: "divider", title: "分隔线", icon: "minus", hint: "---",
                     keywords: ["divider", "hr", "line", "separator", "fengexian", "fgx"], action: .divider),
    ]

    /// Commands whose title or keywords contain the query (case-insensitive); all of them for an empty query
    static func matching(_ query: String) -> [SlashCommand] {
        let needle = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return all }
        return all.filter { command in
            command.title.lowercased().replacingOccurrences(of: " ", with: "").contains(needle)
                || command.keywords.contains { $0.hasPrefix(needle) }
        }
    }

    /// Characters that open the menu: `/`, and `、` which the Chinese input method types for that key
    static let triggers: Set<String> = ["/", "、"]
}

/// State shared by the menu view and the text view driving it with the keyboard
@MainActor
@Observable
final class SlashMenuModel {
    var commands: [SlashCommand] = []
    var selection = 0

    var selected: SlashCommand? {
        commands.indices.contains(selection) ? commands[selection] : nil
    }

    func move(by delta: Int) {
        guard !commands.isEmpty else { return }
        selection = (selection + delta + commands.count) % commands.count
    }
}

struct SlashMenuView: View {
    let model: SlashMenuModel
    let onChoose: (SlashCommand) -> Void

    static let rowHeight: CGFloat = 36
    static let headerHeight: CGFloat = 26
    static let width: CGFloat = 248
    static let maxHeight: CGFloat = 330

    static func height(for count: Int) -> CGFloat {
        min(headerHeight + CGFloat(count) * rowHeight + 10, maxHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("基础块")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.headerHeight, alignment: .bottomLeading)
                        .padding(.horizontal, 10)
                    ForEach(Array(model.commands.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == model.selection)
                            .id(command.id)
                            .onHover { if $0 { model.selection = index } }
                            .onTapGesture { onChoose(command) }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, _ in
                if let id = model.selected?.id { proxy.scrollTo(id) }
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// SF Symbol name, or a short label such as `H1` (the size symbols are localized into 大 / 小)
    @ViewBuilder
    private func icon(_ name: String) -> some View {
        if name.count <= 2 {
            Text(name).font(.system(size: 12, weight: .semibold, design: .rounded))
        } else {
            Image(systemName: name).font(.system(size: 13, weight: .medium))
        }
    }

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(command.icon)
                .frame(width: 26, height: 26)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            Text(command.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Text(command.hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A borderless panel under the caret that never takes focus, so typing keeps going to the editor
@MainActor
final class SlashMenuPanel {
    let model = SlashMenuModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows (or moves) the menu so its top-left sits below `anchor` (a screen rect of the `/`)
    func show(below anchor: NSRect, in parent: NSWindow, onChoose: @escaping (SlashCommand) -> Void) {
        let panel = self.panel ?? makePanel(onChoose: onChoose)
        self.panel = panel
        let height = SlashMenuView.height(for: model.commands.count)
        var origin = NSPoint(x: anchor.minX - 6, y: anchor.minY - 4 - height)
        // Flip above the line if it would run off the bottom of the screen
        if let screen = parent.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = anchor.maxY + 4
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: SlashMenuView.width, height: height)), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel(onChoose: @escaping (SlashCommand) -> Void) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SlashMenuView(model: model, onChoose: onChoose))
        return panel
    }
}
