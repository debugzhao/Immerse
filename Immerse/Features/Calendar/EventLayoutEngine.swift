import Foundation

/// An event segment awaiting layout in the time grid
struct LayoutItem: Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let priority: Priority
}

/// Layout result: which column it sits in, how many columns its cluster has, and how many columns it spans to the right
struct LayoutPlacement: Equatable, Sendable {
    let column: Int
    let columnCount: Int
    let span: Int
}

/// Overlapping-event layout algorithm (same approach as Google Calendar / Notion Calendar). Pure function, easy to unit test.
///
/// 1. Sort by start time (ties: higher priority first, then longer first)
/// 2. Cluster: events that overlap directly or transitively form a cluster that shares a column count
/// 3. Assign columns: put each event in the first column that has freed up, or open a new one
/// 4. Expand: if adjacent columns to the right are empty during its span, extend rightward to fill them
enum EventLayoutEngine {
    static func layout(_ items: [LayoutItem], minimumDuration: TimeInterval = 0) -> [UUID: LayoutPlacement] {
        struct Entry {
            let id: UUID
            let start: Date
            let end: Date
            let priority: Priority
            var column = 0
        }

        // Very short events still render at a minimum height, so use that height for overlap checks to keep text from colliding
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

    /// Lane assignment for the all-day row: each item spans [startDay, endDay] (closed interval, by column index); returns the lane for each.
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
