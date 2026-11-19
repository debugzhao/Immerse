import Foundation

/// Imports a CSV exported from the Notion "主线任务日程" database (database ⋯ → Export → Markdown & CSV).
///
/// Field mapping: 任务 (task) → title, 日期 (date) → start/end/all-day, 优先级 (priority), 状态 (status; the "完成" checkbox being Yes means done), 备注 (notes), Place → location.
/// Dates support the common Notion export formats, including ranges with "→" and timezone suffixes like "(GMT+8)".
enum NotionCSVImporter {
    struct Result: Equatable {
        var tasks: [TaskSnapshot]
        /// Skipped rows and reasons (row number, 1-based, excluding the header)
        var skipped: [(row: Int, reason: String)]

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.tasks == rhs.tasks && lhs.skipped.map(\.row) == rhs.skipped.map(\.row)
        }
    }

    enum ImportError: LocalizedError {
        case empty
        case missingTitleColumn

        var errorDescription: String? {
            switch self {
            case .empty: "文件是空的"
            case .missingTitleColumn: "没找到「任务」或「Name」列，确认导出的是「主线任务日程」数据库"
            }
        }
    }

    static func parse(_ text: String, calendar: Calendar = .app, timeZone: TimeZone = .current) throws -> Result {
        let rows = CSV.parse(text)
        guard let header = rows.first else { throw ImportError.empty }
        let columns = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) },
                                 uniquingKeysWith: { first, _ in first })

        func index(_ names: String...) -> Int? { names.lazy.compactMap { columns[$0] }.first }
        guard let titleIndex = index("任务", "Name", "名称", "标题") else { throw ImportError.missingTitleColumn }
        let dateIndex = index("日期", "Date")
        let priorityIndex = index("优先级", "Priority")
        let statusIndex = index("状态", "Status")
        let doneIndex = index("完成", "Done")
        let notesIndex = index("备注", "Notes")
        let placeIndex = index("Place", "地点")

        var result = Result(tasks: [], skipped: [])
        for (offset, row) in rows.dropFirst().enumerated() {
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let title = value(titleIndex)
            if title.isEmpty && row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            guard !title.isEmpty else {
                result.skipped.append((offset + 1, "标题为空"))
                continue
            }
            guard let date = NotionDate.parse(value(dateIndex), calendar: calendar, timeZone: timeZone) else {
                result.skipped.append((offset + 1, value(dateIndex).isEmpty ? "没有日期" : "无法识别日期「\(value(dateIndex))」"))
                continue
            }

            var status = TaskStatus.allCases.first { $0.title == value(statusIndex) } ?? .todo
            if ["yes", "true", "是", "✅"].contains(value(doneIndex).lowercased()) { status = .done }
            let place = value(placeIndex)

            result.tasks.append(TaskSnapshot(
                title: title,
                start: date.start,
                end: date.end,
                isAllDay: date.isAllDay,
                priority: Priority.allCases.first { $0.title == value(priorityIndex) } ?? .normal,
                status: status,
                notes: value(notesIndex),
                place: place.isEmpty ? nil : place
            ))
        }
        return result
    }

    /// Drop events that duplicate existing ones (same title + start time)
    static func removingDuplicates(_ tasks: [TaskSnapshot], existing: [TaskSnapshot]) -> [TaskSnapshot] {
        let keys = Set(existing.map { "\($0.title)|\($0.start.timeIntervalSince1970)" })
        return tasks.filter { !keys.contains("\($0.title)|\($0.start.timeIntervalSince1970)") }
    }
}

/// Date text exported by Notion
enum NotionDate {
    struct Value: Equatable {
        var start: Date
        var end: Date?
        var isAllDay: Bool
    }

    /// Supported:
    /// - November 17, 2026 / Nov 17, 2026 / 2026/11/17 / 2026-11-17 / 2026年11月17日
    /// - With time: November 17, 2026 3:00 PM / 2026/11/17 15:00
    /// - Range: A → B, where B may be just a time (same day)
    /// - Timezone suffix: (GMT+8) / (UTC)
    static func parse(_ raw: String, calendar: Calendar, timeZone: TimeZone) -> Value? {
        var text = raw.replacingOccurrences(of: #"\s*\((?:GMT|UTC)[^)]*\)"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let parts = text.components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parseOne(parts[0], calendar: calendar, timeZone: timeZone) else { return nil }

        var end: Date?
        if parts.count > 1 {
            if let full = parseOne(parts[1], calendar: calendar, timeZone: timeZone) {
                end = full.date
            } else if let time = parseTime(parts[1]) {
                // "3:00 PM → 4:00 PM": the end has only a time, on the same day as the start
                end = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: first.date)
            }
        }
        let isAllDay = !first.hasTime
        return Value(start: isAllDay ? calendar.startOfDay(for: first.date) : first.date,
                     end: end.map { isAllDay ? calendar.startOfDay(for: $0) : $0 },
                     isAllDay: isAllDay)
    }

    private static let dateFormats = ["MMMM d, yyyy", "MMM d, yyyy", "yyyy/MM/dd", "yyyy-MM-dd", "yyyy年M月d日", "M/d/yyyy"]
    private static let timeFormats = ["h:mm a", "HH:mm"]

    private static func parseOne(_ text: String, calendar: Calendar, timeZone: TimeZone) -> (date: Date, hasTime: Bool)? {
        for dateFormat in dateFormats {
            for timeFormat in timeFormats {
                if let date = format(dateFormat + " " + timeFormat, calendar: calendar, timeZone: timeZone).date(from: text) {
                    return (date, true)
                }
            }
            if let date = format(dateFormat, calendar: calendar, timeZone: timeZone).date(from: text) {
                return (date, false)
            }
        }
        return nil
    }

    private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        for timeFormat in timeFormats {
            let formatter = format(timeFormat, calendar: .init(identifier: .gregorian), timeZone: .gmt)
            if let date = formatter.date(from: text) {
                var gmt = Calendar(identifier: .gregorian)
                gmt.timeZone = .gmt
                let c = gmt.dateComponents([.hour, .minute], from: date)
                return (c.hour ?? 0, c.minute ?? 0)
            }
        }
        return nil
    }

    private static func format(_ format: String, calendar: Calendar, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

/// Minimal CSV parser: supports quoted fields, escaped quotes (""), newlines within fields, BOM, CRLF
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        if pending == "\u{FEFF}" { pending = iterator.next() }

        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                fallthrough
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
