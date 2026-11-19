import Foundation
import Testing
@testable import Immerse

/// "Now" is fixed at 2026-11-18 (Wednesday) 10:00
struct NaturalLanguageParserTests {
    private let calendar = Calendar.app
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10))!
    }

    private func parse(_ text: String) -> ParsedInput {
        NaturalLanguageParser.parse(text, now: now, calendar: calendar)
    }

    /// "11-19 15:00" format, convenient for assertions
    private func fmt(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d-%d %02d:%02d", c.month!, c.day!, c.hour!, c.minute!)
    }

    // MARK: - Examples from the requirements

    @Test func 需求示例() {
        let r = parse("明天下午3点 阅读《第一性原理》 1小时 重要")
        #expect(r.title == "阅读《第一性原理》")
        #expect(fmt(r.start) == "11-19 15:00")
        #expect(r.durationMinutes == 60)
        #expect(r.priority == .important)
        let task = r.makeSnapshot(now: now, calendar: calendar)
        #expect(fmt(task.end) == "11-19 16:00")
        #expect(!task.isAllDay)
    }

    // MARK: - Dates

    @Test(arguments: [
        ("今天 写周报", "11-18 00:00"),
        ("明天 写周报", "11-19 00:00"),
        ("后天 写周报", "11-20 00:00"),
        ("大后天 写周报", "11-21 00:00"),
    ])
    func 相对日期(text: String, expected: String) {
        let r = parse(text)
        #expect(fmt(r.date) == expected)
        #expect(r.title == "写周报")
    }

    @Test(arguments: [
        ("周五 复盘", "11-20 00:00"),       // Friday not yet reached this week
        ("周一 复盘", "11-23 00:00"),       // this Monday has passed, so it means next Monday
        ("周三 复盘", "11-18 00:00"),       // today
        ("星期日 复盘", "11-22 00:00"),
        ("周天 复盘", "11-22 00:00"),
        ("本周一 复盘", "11-16 00:00"),     // explicitly "this week", so it stays this week even if already passed
        ("下周三 复盘", "11-25 00:00"),
        ("下下周二 复盘", "12-1 00:00"),
        ("礼拜六 复盘", "11-21 00:00"),
    ])
    func 星期(text: String, expected: String) {
        #expect(fmt(parse(text).date) == expected)
    }

    @Test func 绝对日期() {
        #expect(fmt(parse("11月20日 体检").date) == "11-20 00:00")
        #expect(fmt(parse("12月1号 体检").date) == "12-1 00:00")
        #expect(fmt(parse("11/25 体检").date) == "11-25 00:00")
    }

    @Test func 已过去的日期算明年() {
        let r = parse("1月5日 年度计划")
        let year = calendar.component(.year, from: r.date!)
        #expect(year == 2027)
    }

    // MARK: - Times

    @Test(arguments: [
        ("明天上午9点 晨会", "11-19 09:00"),
        ("明天早上8点半 跑步", "11-19 08:30"),
        ("明天中午12点 午饭", "11-19 12:00"),
        ("明天中午1点 午休", "11-19 13:00"),
        ("明天下午3点半 评审", "11-19 15:30"),
        ("明天下午三点 评审", "11-19 15:00"),
        ("明天晚上8点 复盘", "11-19 20:00"),
        ("明天晚上十点 读书", "11-19 22:00"),
        ("明天14:30 评审", "11-19 14:30"),
        ("明天 9:05 站会", "11-19 09:05"),
        ("明天下午3点15分 电话", "11-19 15:15"),
        ("明天下午3点一刻 电话", "11-19 15:15"),
        ("明天凌晨1点 发布", "11-19 01:00"),
    ])
    func 时间点(text: String, expected: String) {
        #expect(fmt(parse(text).start) == expected)
    }

    @Test func 只写时间默认今天() {
        #expect(fmt(parse("下午4点 健身").start) == "11-18 16:00")
    }

    @Test func 今天已经过去的时间算明天() {
        #expect(fmt(parse("上午9点 晨会").start) == "11-19 09:00")
    }

    @Test func 不写时段的一到六点理解为下午() {
        #expect(fmt(parse("明天3点 喝茶").start) == "11-19 15:00")
        #expect(fmt(parse("明天9点 晨会").start) == "11-19 09:00")
        #expect(fmt(parse("明天03:00 发布").start) == "11-19 03:00")   // HH:mm is taken literally
    }

    @Test func 今晚() {
        let r = parse("今晚8点 看电影")
        #expect(fmt(r.start) == "11-18 20:00")
        #expect(r.title == "看电影")
    }

    // MARK: - Time ranges

    @Test func 时间段沿用开始的时段() {
        let r = parse("明天下午3点到5点 黑客松")
        #expect(fmt(r.start) == "11-19 15:00")
        #expect(fmt(r.end) == "11-19 17:00")
        #expect(r.title == "黑客松")
    }

    @Test func 冒号格式的时间段() {
        let r = parse("周五 14:00-15:30 Code Review")
        #expect(fmt(r.start) == "11-20 14:00")
        #expect(fmt(r.end) == "11-20 15:30")
        #expect(r.title == "Code Review")
    }

    @Test func 跨午夜的时间段() {
        let r = parse("明天晚上11点到1点 发版")
        #expect(fmt(r.start) == "11-19 23:00")
        #expect(fmt(r.end) == "11-20 01:00")
    }

    // MARK: - Durations

    @Test(arguments: [
        ("阅读 1小时", 60),
        ("阅读 2个小时", 120),
        ("阅读 45分钟", 45),
        ("阅读 半小时", 30),
        ("阅读 一个半小时", 90),
        ("阅读 1.5h", 90),
        ("阅读 90min", 90),
        ("阅读 两小时", 120),
    ])
    func 时长(text: String, minutes: Int) {
        let r = parse(text)
        #expect(r.durationMinutes == minutes)
        #expect(r.title == "阅读")
    }

    @Test func 只写时长时创建全天日程并作为专注时长() {
        let task = parse("阅读《谈判技巧》 45分钟").makeSnapshot(now: now, calendar: calendar)
        #expect(task.isAllDay)
        #expect(task.plannedMinutes == 45)
        #expect(fmt(task.start) == "11-18 00:00")
    }

    @Test func 时间里的分钟不会被当成时长() {
        let r = parse("明天下午3点30分 评审")
        #expect(fmt(r.start) == "11-19 15:30")
        #expect(r.durationMinutes == nil)
    }

    // MARK: - Priority and location

    @Test(arguments: [
        ("提交报告 紧急", Priority.urgent),
        ("提交报告 !!!", Priority.urgent),
        ("提交报告 !!", Priority.important),
        ("提交报告 ！", Priority.normal),
        ("普通 提交报告", Priority.normal),
    ])
    func 优先级(text: String, priority: Priority) {
        let r = parse(text)
        #expect(r.priority == priority)
        #expect(r.title == "提交报告")
    }

    @Test func 标题里的重要两个字不会被误识别() {
        let r = parse("整理重要文件")
        #expect(r.priority == nil)
        #expect(r.title == "整理重要文件")
    }

    @Test func 地点() {
        let r = parse("明天上午10点 周会 @3F会议室")
        #expect(r.place == "3F会议室")
        #expect(r.title == "周会")
    }

    // MARK: - Fallback

    @Test func 什么都没识别出来时整句作为标题全天今天() {
        let task = parse("学会使用区块浏览器").makeSnapshot(now: now, calendar: calendar)
        #expect(task.title == "学会使用区块浏览器")
        #expect(task.isAllDay)
        #expect(fmt(task.start) == "11-18 00:00")
        #expect(task.priority == .normal)
    }

    @Test func 书名号原样保留() {
        #expect(parse("后天 读《三体》 重要").title == "读《三体》")
    }

    @Test func 中文数字() {
        #expect(NaturalLanguageParser.number("十") == 10)
        #expect(NaturalLanguageParser.number("十二") == 12)
        #expect(NaturalLanguageParser.number("二十三") == 23)
        #expect(NaturalLanguageParser.number("两") == 2)
        #expect(NaturalLanguageParser.number("1.5") == 1.5)
        #expect(NaturalLanguageParser.number("") == nil)
    }
}
