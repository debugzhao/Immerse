import Foundation
import Testing
@testable import ImmerseCore

struct NotionCSVImporterTests {
    private let calendar = Calendar.app
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private func fmt(_ date: Date?) -> String {
        guard let date else { return "nil" }
        var cal = calendar
        cal.timeZone = timeZone
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d-%d %02d:%02d", c.month!, c.day!, c.hour!, c.minute!)
    }

    private var shanghaiCalendar: Calendar {
        var cal = calendar
        cal.timeZone = timeZone
        return cal
    }

    @Test func 解析主线任务日程导出的CSV() throws {
        // Notion export has a BOM and CRLF, and notes contain commas and newlines
        let csv = "\u{FEFF}任务,Place,优先级,备注,完成,日期,状态\r\n"
            + "了解 Creative 链，完成第一天的任务,,紧急,,No,\"November 17, 2026\",已完成\r\n"
            + "阅读《谈判技巧》,图书馆,普通,\"第三章，\n做笔记\",No,\"November 18, 2026 3:00 PM (GMT+8) → 4:30 PM\",未开始\r\n"
            + "Creative 链黑客松,,重要,,Yes,\"November 19, 2026 → November 20, 2026\",进行中\r\n"
            + "没有日期的任务,,普通,,No,,未开始\r\n"
            + ",,,,,,\r\n"

        let result = try NotionCSVImporter.parse(csv, calendar: shanghaiCalendar, timeZone: timeZone)
        #expect(result.tasks.count == 3)
        #expect(result.skipped.map(\.row) == [4])

        let first = result.tasks[0]
        #expect(first.title == "了解 Creative 链，完成第一天的任务")
        #expect(first.isAllDay)
        #expect(first.priority == .urgent)
        #expect(first.status == .done)

        let reading = result.tasks[1]
        #expect(!reading.isAllDay)
        #expect(fmt(reading.start) == "11-18 15:00")
        #expect(fmt(reading.end) == "11-18 16:30")
        #expect(reading.place == "图书馆")
        #expect(reading.notes == "第三章，\n做笔记")

        let hackathon = result.tasks[2]
        #expect(hackathon.isAllDay)
        #expect(fmt(hackathon.end) == "11-20 00:00")
        // when the "完成" (done) checkbox is set, it takes precedence
        #expect(hackathon.status == .done)
    }

    @Test(arguments: [
        ("Nov 17, 2026", "11-17 00:00", true),
        ("2026/11/17", "11-17 00:00", true),
        ("2026-11-17", "11-17 00:00", true),
        ("2026年11月17日", "11-17 00:00", true),
        ("November 17, 2026 9:30 AM", "11-17 09:30", false),
        ("2026/11/17 21:05", "11-17 21:05", false),
    ])
    func 日期格式(text: String, expected: String, isAllDay: Bool) throws {
        let value = try #require(NotionDate.parse(text, calendar: shanghaiCalendar, timeZone: timeZone))
        #expect(fmt(value.start) == expected)
        #expect(value.isAllDay == isAllDay)
    }

    @Test func 无法识别的日期会跳过并说明原因() throws {
        let csv = "任务,日期\n周会,下周某天\n"
        let result = try NotionCSVImporter.parse(csv, calendar: shanghaiCalendar, timeZone: timeZone)
        #expect(result.tasks.isEmpty)
        #expect(result.skipped.first?.reason.contains("下周某天") == true)
    }

    @Test func 缺少标题列时报错() {
        #expect(throws: NotionCSVImporter.ImportError.self) {
            try NotionCSVImporter.parse("日期\n2026/11/17\n", calendar: shanghaiCalendar, timeZone: timeZone)
        }
    }

    @Test func 去掉已有的重复日程() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = [TaskSnapshot(title: "周会", start: start, end: nil, isAllDay: true)]
        let incoming = [
            TaskSnapshot(title: "周会", start: start, end: nil, isAllDay: true),
            TaskSnapshot(title: "健身", start: start, end: nil, isAllDay: true),
        ]
        #expect(NotionCSVImporter.removingDuplicates(incoming, existing: existing).map(\.title) == ["健身"])
    }

    @Test func CSV引号转义() {
        let rows = CSV.parse("a,\"b \"\"quoted\"\"\",c\n1,2,3")
        #expect(rows == [["a", "b \"quoted\"", "c"], ["1", "2", "3"]])
    }
}
