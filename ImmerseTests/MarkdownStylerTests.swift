import Foundation
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
        #expect(result.filter { $0.1 == .marker }.map(\.0) == ["* ", "- ", "1. "])
    }

    @Test func 待办() {
        #expect(has("- [x] 买书", "买书", .done))
        #expect(has("- [x] 买书", "- [x] ", .marker))
        #expect(!kinds("- [ ] 买书").contains { $0.1 == .done })
    }

    @Test func 引用和代码块() {
        #expect(has("> 少即是多", "> 少即是多", .quote))
        let fenced = kinds("```\nlet a = **b**\n```\n正文")
        #expect(fenced.contains { $0.0 == "let a = **b**" && $0.1 == .codeBlock })
        #expect(!fenced.contains { $0.1 == .bold })
    }

    @Test func 回车续写列表() {
        #expect(MarkdownStyler.continuation(forLine: "- 买菜") == "- ")
        #expect(MarkdownStyler.continuation(forLine: "  * 缩进") == "  * ")
        #expect(MarkdownStyler.continuation(forLine: "3. 第三步") == "4. ")
        #expect(MarkdownStyler.continuation(forLine: "- [x] 已完成") == "- [ ] ")
        #expect(MarkdownStyler.continuation(forLine: "> 引用") == "> ")
        #expect(MarkdownStyler.continuation(forLine: "- ") == "")
        #expect(MarkdownStyler.continuation(forLine: "普通文字") == nil)
    }

    @Test func 复选框位置() {
        #expect(MarkdownStyler.checkboxOffset(inLine: "- [ ] 待办") == 3)
        #expect(MarkdownStyler.checkboxOffset(inLine: "  - [x] 缩进") == 5)
        #expect(MarkdownStyler.checkboxOffset(inLine: "- 普通") == nil)
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
