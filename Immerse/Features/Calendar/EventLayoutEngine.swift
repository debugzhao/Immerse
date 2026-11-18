import Foundation

/// 时间网格里一个待排布的日程片段
struct LayoutItem: Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let priority: Priority
}

/// 排布结果：位于第几列、所在簇共几列、向右占几列
struct LayoutPlacement: Equatable, Sendable {
    let column: Int
    let columnCount: Int
    let span: Int
}

/// 重叠日程排布算法（与 Google Calendar / Notion Calendar 同思路）。纯函数，便于单元测试。
///
/// 1. 按开始时间排序（同时开始的：优先级高的在前，长的在前）
/// 2. 分簇：直接或间接重叠的日程归为一簇，簇内共享列数
/// 3. 分列：放进第一个「已空出来」的列，没有就新开一列
/// 4. 扩展：右侧相邻列在该时段空着的话，向右占满
enum EventLayoutEngine {
    static func layout(_ items: [LayoutItem], minimumDuration: TimeInterval = 0) -> [UUID: LayoutPlacement] {
        struct Entry {
            let id: UUID
            let start: Date
            let end: Date
            let priority: Priority
            var column = 0
        }

        // 太短的日程在视觉上也会占一个最小高度，按最小高度参与重叠判断，避免文字互相压住
        let sorted = items
            .map { Entry(id: $0.id, start: $0.start, end: max($0.end, $0.start.addingTimeInterval(minimumDuration)), priority: $0.priority) }
            .sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.end > b.end
            }

        var result: [UUID: LayoutPlacement] = [:]
        var cluster: [Entry] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = columnEnds.count
            for entry in cluster {
                var span = 1
                for column in (entry.column + 1)..<max(count, entry.column + 1) {
                    let blocked = cluster.contains { other in
                        other.column == column && other.start < entry.end && entry.start < other.end
                    }
                    if blocked { break }
                    span += 1
                }
                result[entry.id] = LayoutPlacement(column: entry.column, columnCount: count, span: span)
            }
            cluster.removeAll()
            columnEnds.removeAll()
            clusterEnd = .distantPast
        }

        for var entry in sorted {
            if !cluster.isEmpty && entry.start >= clusterEnd {
                flush()
            }
            if let free = columnEnds.firstIndex(where: { $0 <= entry.start }) {
                entry.column = free
                columnEnds[free] = entry.end
            } else {
                entry.column = columnEnds.count
                columnEnds.append(entry.end)
            }
            cluster.append(entry)
            clusterEnd = max(clusterEnd, entry.end)
        }
        flush()
        return result
    }

    /// 全天行的分道：每个条目占据 [startDay, endDay]（闭区间，按列索引），返回各自所在的道。
    static func allDayLanes(_ items: [(id: UUID, startDay: Int, endDay: Int)]) -> [UUID: Int] {
        let sorted = items.sorted { a, b in
            if a.startDay != b.startDay { return a.startDay < b.startDay }
            return (a.endDay - a.startDay) > (b.endDay - b.startDay)
        }
        var laneEnds: [Int] = []
        var result: [UUID: Int] = [:]
        for item in sorted {
            if let lane = laneEnds.firstIndex(where: { $0 < item.startDay }) {
                laneEnds[lane] = item.endDay
                result[item.id] = lane
            } else {
                result[item.id] = laneEnds.count
                laneEnds.append(item.endDay)
            }
        }
        return result
    }
}
