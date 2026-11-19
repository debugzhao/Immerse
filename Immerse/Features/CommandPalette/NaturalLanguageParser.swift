import Foundation

/// Result of natural language parsing
struct ParsedInput: Equatable {
    var title: String
    /// Recognized date (midnight of that day)
    var date: Date?
    /// Recognized start time (including date)
    var start: Date?
    /// Recognized end time ("3点到5点")
    var end: Date?
    /// Recognized duration (minutes)
    var durationMinutes: Int?
    var priority: Priority?
    var place: String?

    /// Converts to an event. Rules:
    /// - No time given: create an all-day event (default today); the duration becomes the planned focus duration
    /// - Time given: end time = explicit end time > start + duration > start + 1 hour
    func makeSnapshot(now: Date, calendar: Calendar) -> TaskSnapshot {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start {
            let end = end ?? start.addingTimeInterval(TimeInterval((durationMinutes ?? 60) * 60))
            return TaskSnapshot(title: trimmedTitle, start: start, end: end, isAllDay: false,
                                priority: priority ?? .normal, place: place)
        }
        return TaskSnapshot(title: trimmedTitle, start: date ?? calendar.startOfDay(for: now), end: nil,
                            isAllDay: true, priority: priority ?? .normal, place: place,
                            plannedMinutes: durationMinutes)
    }
}

/// Chinese natural language parser (local rules, no network).
///
/// Example: "明天下午3点 阅读《第一性原理》 1小时 重要" -> tomorrow 15:00–16:00, important, title "阅读《第一性原理》"
///
/// Approach: match with regexes in the order "location → priority → time range → time point → duration → date";
/// each matched fragment is cut out of the text and what remains is the title. Order matters: cut the time first so the "30分" in "3点30分" is not mistaken for a duration.
enum NaturalLanguageParser {
    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .app) -> ParsedInput {
        var rest = text
        var result = ParsedInput(title: "")

        // Location: @图书馆
        if let match = firstMatch(#"[@＠](\S+)"#, in: rest) {
            result.place = match.group(1)
            rest = match.removed
        }

        // Priority: !!! / !! / ! or a standalone "紧急 / 重要 / 普通"
        if let match = firstMatch(#"(?:^|\s)(!!!|！！！|!!|！！|!|！)(?=\s|$)"#, in: rest) {
            let marks = match.group(1)?.count ?? 1
            result.priority = marks >= 3 ? .urgent : marks == 2 ? .important : .normal
            rest = match.removed
        } else if let match = firstMatch(#"(?:^|\s)(紧急|重要|普通)(?=\s|$)"#, in: rest) {
            result.priority = Priority.allCases.first { $0.title == match.group(1) }
            rest = match.removed
        }

        // "今晚" in the date part gives both a date and a period of day; remember it first
        let impliesTonight = rest.contains("今晚")

        // Time range: "下午3点到5点", "14:00-15:30"
        var startTime: (hour: Int, minute: Int)?
        var endTime: (hour: Int, minute: Int)?
        let time = #"(上午|早上|早晨|中午|下午|傍晚|晚上|今晚|凌晨)?\s*(\d{1,2}|[零一二两三四五六七八九十]{1,3})(?:[:：](\d{2})|[点時时](半|一刻|三刻|(\d{1,2})分?)?)"#
        if let match = firstMatch(time + #"\s*(?:到|至|-|–|—|~|～)\s*"# + time, in: rest) {
            startTime = resolveTime(period: match.group(1), hour: match.group(2), colonMinute: match.group(3),
                                    suffix: match.group(4), minute: match.group(5))
            // If the end time has no period of day, reuse the start's: "下午3点到5点"
            let explicitEndPeriod = match.group(6)
            endTime = resolveTime(period: explicitEndPeriod ?? match.group(1), hour: match.group(7),
                                  colonMinute: match.group(8), suffix: match.group(9), minute: match.group(10))
            // "晚上11点到1点": reusing the period gives 13:00, which is before the start, so interpret it as 1 AM the next day
            if explicitEndPeriod == nil, let s = startTime, let e = endTime,
               e.hour * 60 + e.minute <= s.hour * 60 + s.minute {
                endTime = resolveTime(period: "凌晨", hour: match.group(7), colonMinute: match.group(8),
                                      suffix: match.group(9), minute: match.group(10))
            }
            rest = match.removed
        } else if let match = firstMatch(time, in: rest) {
            startTime = resolveTime(period: match.group(1), hour: match.group(2), colonMinute: match.group(3),
                                    suffix: match.group(4), minute: match.group(5))
            rest = match.removed
        }

        // Duration: "1小时", "45分钟", "半小时", "一个半小时", "1.5h", "90min"
        if let match = firstMatch(#"(?:(\d+|[一二两三四五六七八九十]+)个半小时)"#, in: rest),
           let n = number(match.group(1)) {
            result.durationMinutes = Int(n * 60) + 30
            rest = match.removed
        } else if let match = firstMatch(#"半(?:个)?小时"#, in: rest) {
            result.durationMinutes = 30
            rest = match.removed
        } else if let match = firstMatch(#"(\d+(?:\.\d+)?|[一二两三四五六七八九十]+)\s*(?:个)?\s*(小时|钟头|hours?|hrs?|h|分钟|mins?|minutes?)(?![A-Za-z])"#, in: rest),
                  let n = number(match.group(1)) {
            let isHour = ["小时", "钟头", "hour", "hours", "hr", "hrs", "h"].contains(match.group(2)?.lowercased() ?? "")
            result.durationMinutes = Int((isHour ? n * 60 : n).rounded())
            rest = match.removed
        }

        // Date
        let today = calendar.startOfDay(for: now)
        if let match = firstMatch(#"(大后天|后天|明天|今天|今晚)"#, in: rest) {
            let offset = ["今天": 0, "今晚": 0, "明天": 1, "后天": 2, "大后天": 3][match.group(1) ?? ""] ?? 0
            result.date = calendar.date(byAdding: .day, value: offset, to: today)
            rest = match.removed
        } else if let match = firstMatch(#"(下下周|下周|本周|这周|周|星期|礼拜)([一二三四五六日天])"#, in: rest) {
            result.date = weekday(prefix: match.group(1) ?? "", day: match.group(2) ?? "", today: today, calendar: calendar)
            rest = match.removed
        } else if let match = firstMatch(#"(\d{1,2})月(\d{1,2})[日号]?"#, in: rest)
                    ?? firstMatch(#"(?<![\d:：])(\d{1,2})[/／](\d{1,2})(?![\d:：])"#, in: rest) {
            result.date = monthDay(month: Int(match.group(1) ?? ""), day: Int(match.group(2) ?? ""),
                                   today: today, calendar: calendar)
            rest = match.removed
        }
        if result.date == nil && impliesTonight {
            result.date = today
        }

        // Assemble start / end times: with a time but no date, default to today; if that time has already passed today, use tomorrow
        if let startTime {
            var day = result.date ?? today
            var start = calendar.date(bySettingHour: startTime.hour, minute: startTime.minute, second: 0, of: day) ?? day
            if result.date == nil && start < now {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            }
            result.start = start
            if let endTime,
               var end = calendar.date(bySettingHour: endTime.hour, minute: endTime.minute, second: 0, of: day) {
                if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }   // crosses midnight
                result.end = end
            }
        }

        result.title = rest
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    // MARK: - Time

    private static func resolveTime(period: String?, hour: String?, colonMinute: String?,
                                    suffix: String?, minute: String?) -> (hour: Int, minute: Int)? {
        guard let hourText = hour, var h = number(hourText).map(Int.init), (0...24).contains(h) else { return nil }
        var m = 0
        if let colonMinute { m = Int(colonMinute) ?? 0 }
        else if suffix == "半" { m = 30 }
        else if suffix == "一刻" { m = 15 }
        else if suffix == "三刻" { m = 45 }
        else if let minute { m = Int(minute) ?? 0 }
        guard (0..<60).contains(m) else { return nil }

        switch period {
        case "下午", "傍晚", "晚上", "今晚":
            if h < 12 { h += 12 }
        case "中午":
            if h < 6 { h += 12 }   // "中午1点" = 13:00, "中午12点" = 12:00
        case "凌晨", "上午", "早上", "早晨":
            if h == 12 { h = 0 }
        default:
            // No period of day given: HH:mm is taken literally; "3点" (hours 1–6) most likely means PM
            if colonMinute == nil, (1...6).contains(h) { h += 12 }
        }
        return (min(h, 23), h == 24 ? 59 : m)
    }

    // MARK: - Date

    private static func weekday(prefix: String, day: String, today: Date, calendar: Calendar) -> Date? {
        // Monday = 0 … Sunday = 6
        guard let index = ["一", "二", "三", "四", "五", "六", "日"].firstIndex(of: day == "天" ? "日" : day),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let thisWeek = calendar.date(byAdding: .day, value: index, to: weekStart) else { return nil }
        switch prefix {
        case "本周", "这周": return thisWeek
        case "下周": return calendar.date(byAdding: .day, value: 7, to: thisWeek)
        case "下下周": return calendar.date(byAdding: .day, value: 14, to: thisWeek)
        default:
            // A bare "周三": the nearest Wednesday today or later
            return thisWeek < today ? calendar.date(byAdding: .day, value: 7, to: thisWeek) : thisWeek
        }
    }

    private static func monthDay(month: Int?, day: Int?, today: Date, calendar: Calendar) -> Date? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = calendar.dateComponents([.year], from: today)
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        // Past dates roll over to next year (in November, "1月5日" means next year)
        return date < today ? calendar.date(byAdding: .year, value: 1, to: date) : date
    }

    // MARK: - Numbers

    /// Arabic or Chinese numerals (up to 99)
    static func number(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        if let value = Double(text) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let tenIndex = text.firstIndex(of: "十") {
            let tens = text[..<tenIndex].isEmpty ? 1 : digits[text[text.startIndex]] ?? 0
            let after = text[text.index(after: tenIndex)...]
            let ones = after.first.flatMap { digits[$0] } ?? 0
            return Double(tens * 10 + ones)
        }
        guard text.count == 1, let value = digits[text[text.startIndex]] else { return nil }
        return Double(value)
    }

    // MARK: - Regex

    private struct Match {
        let groups: [String?]
        /// Text after removing the matched fragment (replaced with spaces so the surrounding text does not stick together)
        let removed: String
        func group(_ index: Int) -> String? { index < groups.count ? groups[index] : nil }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              let whole = Range(result.range, in: text) else { return nil }
        let groups: [String?] = (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
        var removed = text
        removed.replaceSubrange(whole, with: " ")
        return Match(groups: groups, removed: removed)
    }
}
