import Foundation
import ImmerseCore
import Testing
@testable import Immerse

struct MarkdownStylerTests {
    private func kinds(_ text: String) -> [(String, MarkdownStyler.Span.Kind)] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func has(_ text: String, _ fragment: String, _ kind: MarkdownStyler.Span.Kind) -> Bool {
        kinds(text).contains { $0.0 == fragment && $0.1 == kind }
    }

    @Test func 标题() {
        #expect(has("## 复盘", "## 复盘", .heading(level: 2)))
        #expect(has("## 复盘", "## ", .marker))
        #expect(kinds("#没有空格不算").isEmpty)
    }

    @Test func 粗体斜体和代码() {
        let text = "读 **第一性原理** 的 *第三章*，跑 `make test`"
        #expect(has(text, "第一性原理", .bold))
        #expect(has(text, "第三章", .italic))
        #expect(has(text, "make test", .code))
        #expect(has(text, "**", .marker))
        #expect(has(text, "`", .marker))
    }

    @Test func 代码里的星号不算强调() {
        #expect(!kinds("`a * b * c`").contains { $0.1 == .italic })
    }

    @Test func 列表标记不算斜体() {
        let result = kinds("* 第一项\n- 第二项\n1. 第三项")
        #expect(!result.contains { $0.1 == .italic })
        #expect(has("* 第一项", "* ", .bullet(level: 0)))
        #expect(has("- 第二项", "- ", .bullet(level: 0)))
        #expect(has("1. 第三项", "1. ", .ordered))
        #expect(has("    - 嵌套", "- ", .bullet(level: 2)))
    }

    @Test func 待办() {
        #expect(has("- [x] 买书", "买书", .done))
        #expect(has("- [x] 买书", "- [x] ", .checkbox(checked: true)))
        #expect(has("- [ ] 买书", "- [ ] ", .checkbox(checked: false)))
        #expect(!kinds("- [ ] 买书").contains { $0.1 == .done })
    }

    @Test func 引用和代码块() {
        #expect(has("> 少即是多", "> 少即是多", .quote))
        let fenced = kinds("```\nlet a = **b**\n```\n正文")
        #expect(fenced.contains { $0.0 == "```\nlet a = **b**\n```" && $0.1 == .codeBlock })
        #expect(fenced.filter { $0.1 == .fence }.count == 2)
        #expect(!fenced.contains { $0.1 == .bold })
    }

    @Test func 链接只显示文字() {
        let text = "看 [文档](https://example.com/a_b_c) 和 [@Uniswap](https://app.notion.com/p/Uniswap-41c9)"
        #expect(has(text, "文档", .link(url: "https://example.com/a_b_c")))
        #expect(has(text, "@Uniswap", .mention(url: "https://app.notion.com/p/Uniswap-41c9")))
        #expect(has(text, "](https://example.com/a_b_c)", .marker))
        // The URL's underscores are not italics
        #expect(!kinds(text).contains { $0.1 == .italic })
    }

    @Test func 裸链接可点击() {
        let text = "参考 https://example.com/x_y_z 。"
        #expect(has(text, "https://example.com/x_y_z", .link(url: "https://example.com/x_y_z")))
        #expect(!kinds(text).contains { $0.1 == .italic })
    }

    @Test func 删除线和下划线斜体() {
        #expect(has("~~取消~~", "取消", .strike))
        #expect(has("a _重点_ b", "重点", .italic))
        #expect(!kinds("snake_case_name").contains { $0.1 == .italic })
    }

    @Test func 分隔线() {
        #expect(has("---", "---", .rule))
        #expect(!kinds("--").contains { $0.1 == .rule })
    }

    @Test func 光标所在处显示源码() {
        let text = "前 **粗** 后"
        let spans = MarkdownStyler.spans(in: text)
        // Caret away from the bold: everything concealed
        #expect(MarkdownStyler.revealState(of: spans, selections: [NSRange(location: 0, length: 0)]).allSatisfy { !$0 })
        // Caret right after the closing ** still touches it
        #expect(MarkdownStyler.revealState(of: spans, selections: [NSRange(location: 7, length: 0)]).contains(true))

        // A link stays rendered with the caret right after it, so a pasted mention shows as a mention
        let link = "[@页](https://a.com)"
        let linkSpans = MarkdownStyler.spans(in: link)
        let end = (link as NSString).length
        #expect(MarkdownStyler.revealState(of: linkSpans, selections: [NSRange(location: end, length: 0)]).allSatisfy { !$0 })
        #expect(MarkdownStyler.revealState(of: linkSpans, selections: [NSRange(location: 2, length: 0)]).allSatisfy { $0 })
    }

    @Test func 回车续写列表() {
        #expect(MarkdownStyler.continuation(forLine: "- 买菜") == "- ")
        #expect(MarkdownStyler.continuation(forLine: "  * 缩进") == "  * ")
        #expect(MarkdownStyler.continuation(forLine: "3. 第三步") == "4. ")
        #expect(MarkdownStyler.continuation(forLine: "- [x] 已完成") == "- [ ] ")
        #expect(MarkdownStyler.continuation(forLine: "> 引用") == "> ")
        #expect(MarkdownStyler.continuation(forLine: "- ") == "")
        #expect(MarkdownStyler.continuation(forLine: "- [ ] ") == "")
        #expect(MarkdownStyler.continuation(forLine: "普通文字") == nil)
        #expect(MarkdownStyler.continuation(forLine: "## 标题") == nil)
    }

    @Test func 复选框位置() {
        #expect(MarkdownStyler.checkboxOffset(inLine: "- [ ] 待办") == 3)
        #expect(MarkdownStyler.checkboxOffset(inLine: "  - [x] 缩进") == 5)
        #expect(MarkdownStyler.checkboxOffset(inLine: "- 普通") == nil)
    }

    @Test func 行首语法() {
        #expect(MarkdownStyler.linePrefix("## 标题").kind == .heading(level: 2))
        #expect(MarkdownStyler.linePrefix("  - [x] 完成") == .init(indent: "  ", marker: "- [x] ", kind: .todo(checked: true)))
        #expect(MarkdownStyler.linePrefix("12. 第十二").kind == .ordered(number: 12))
        #expect(MarkdownStyler.linePrefix("---").kind == .paragraph)
        #expect(MarkdownStyler.content(ofLine: "> 引用") == "引用")
    }

    @Test func 切换块类型() {
        #expect(MarkdownStyler.transform(line: "买菜", to: .todo(checked: false)) == "- [ ] 买菜")
        #expect(MarkdownStyler.transform(line: "- [ ] 买菜", to: .heading(level: 2)) == "## 买菜")
        #expect(MarkdownStyler.transform(line: "  - 嵌套", to: .ordered(number: 3)) == "  3. 嵌套")
        #expect(MarkdownStyler.transform(line: "## 标题", to: .paragraph) == "标题")
    }
}

struct LinkTitleResolverTests {
    @Test func 识别粘贴的网址() {
        #expect(LinkTitleResolver.webURL(from: " https://example.com/a?b=1 \n") != nil)
        #expect(LinkTitleResolver.webURL(from: "看 https://example.com") == nil)
        #expect(LinkTitleResolver.webURL(from: "ftp://example.com") == nil)
        #expect(LinkTitleResolver.webURL(from: "example") == nil)
    }

    @Test func 从网址猜标题() {
        let notion = URL(string: "https://app.notion.com/p/Uniswap-41c95506c1a7817cb4d2d0b09f6b176c?source=copy_link")!
        #expect(LinkTitleResolver.provisionalTitle(for: notion) == "Uniswap")
        let multiword = URL(string: "https://www.notion.so/team/Weekly-Review-0123456789abcdef0123456789abcdef")!
        #expect(LinkTitleResolver.provisionalTitle(for: multiword) == "Weekly Review")
        #expect(LinkTitleResolver.provisionalTitle(for: URL(string: "https://www.github.com/a/b")!) == "github.com")
    }

    @Test func 解析网页标题() {
        #expect(LinkTitleResolver.title(fromHTML: #"<meta content="Uniswap &amp; DeFi" property="og:title">"#) == "Uniswap & DeFi")
        #expect(LinkTitleResolver.title(fromHTML: "<title>\n  协议 &#35814;解 </title>") == "协议 详解")
        #expect(LinkTitleResolver.title(fromHTML: "<p>none</p>") == nil)
    }

    @Test func 过滤登录墙标题() {
        let notion = URL(string: "https://app.notion.com/p/x")!
        #expect(LinkTitleResolver.isGeneric("Notion", for: notion))
        #expect(LinkTitleResolver.isGeneric("Notion | Where teams and agents work together", for: notion))
        #expect(!LinkTitleResolver.isGeneric("Uniswap 协议详解", for: notion))
    }

    @Test func 提及的Markdown() {
        #expect(LinkTitleResolver.mention(title: "a [b]", url: "https://x.com") == "[@a (b)](https://x.com)")
    }
}

struct TimeSlotsTests {
    private let calendar = Calendar.app

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func 开始时间每15分钟一个() {
        let starts = TimeSlots.starts(on: date(15), calendar: calendar)
        #expect(starts.count == 96)
        #expect(starts.first == date(0))
        #expect(starts.last == date(23, 45))
    }

    @Test func 结束时间从开始后15分钟起并对齐刻度() {
        let ends = TimeSlots.ends(after: date(9, 32), calendar: calendar)
        #expect(ends.first == date(10))
        #expect(ends.last! <= date(9, 32, day: 19))
        #expect(TimeSlots.ends(after: date(9), calendar: calendar).first == date(9, 15))
    }

    @Test func 时长文字() {
        #expect(TimeSlots.durationText(minutes: 45) == "45分钟")
        #expect(TimeSlots.durationText(minutes: 60) == "1小时")
        #expect(TimeSlots.durationText(minutes: 90) == "1小时30分")
    }
}
