import Foundation
import ImmerseCore

/// Places tasks into free slots: earliest deadline first, then priority, hard tasks into high-energy hours.
/// Long tasks are cut into blocks of at most `maxBlockMinutes`; each placement carries a one-line reason.
public enum Scheduler {
    public static let maxBlockMinutes = 90
    /// Breathing room left after each placed block
    public static let bufferMinutes = 10

    public struct Result: Sendable {
        public var items: [PlanProposal.Item]
        /// Tasks (or parts of them) that found no slot
        public var unplaced: [TaskSnapshot]
    }

    /// Orders tasks the way they should claim slots
    public static func ordered(_ tasks: [TaskSnapshot]) -> [TaskSnapshot] {
        tasks.sorted { a, b in
            switch (a.deadline, b.deadline) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.priority != b.priority { return a.priority < b.priority }
            if (a.effort ?? .medium) != (b.effort ?? .medium) { return (a.effort ?? .medium) > (b.effort ?? .medium) }
            return (a.sortOrder ?? .greatestFiniteMagnitude, a.start) < (b.sortOrder ?? .greatestFiniteMagnitude, b.start)
        }
    }

    /// Splits a duration into blocks: 150 → [90, 60]; 200 → [90, 90, 20→30]
    public static func blocks(for minutes: Int, maxBlock: Int = maxBlockMinutes) -> [Int] {
        guard minutes > maxBlock else { return [max(minutes, 15)] }
        var remaining = minutes
        var result: [Int] = []
        while remaining > 0 {
            let block = min(remaining, maxBlock)
            result.append(max(block, 30))
            remaining -= block
        }
        return result
    }

    public static func plan(_ tasks: [TaskSnapshot], into slots: [FreeSlot], context: PlanningContext) -> Result {
        let calendar = context.calendar
        let curve = context.energy
        let threshold = curve.highEnergyThreshold(workday: context.workday)
        var free = slots.map(\.interval).sorted { $0.start < $1.start }
        var items: [PlanProposal.Item] = []
        var unplaced: [TaskSnapshot] = []
        let today = calendar.startOfDay(for: context.now)

        for task in ordered(tasks) {
            let parts = blocks(for: context.estimatedMinutes(for: task))
            var placedDays: Set<Date> = []
            for (index, minutes) in parts.enumerated() {
                let duration = TimeInterval(minutes * 60)
                // Every placement worth considering: each slot's start plus each whole hour inside it
                var best: (slot: Int, start: Date, energy: Double, score: Double)?
                for (slotIndex, slot) in free.enumerated() {
                    // Parts of one task go on different days so a long task isn't crammed into one sitting
                    if parts.count > 1 && placedDays.contains(calendar.startOfDay(for: slot.start)) { continue }
                    for start in candidateStarts(in: slot, duration: duration, calendar: calendar) {
                        let end = start.addingTimeInterval(duration)
                        if let deadline = task.deadline, end > deadline { continue }
                        let energy = curve.score(for: DateInterval(start: start, end: end), calendar: calendar)
                        let value = score(start: start, energy: energy, task: task, threshold: threshold, today: today, calendar: calendar)
                        if best == nil || value > best!.score { best = (slotIndex, start, energy, value) }
                    }
                }
                guard let best else {
                    var rest = task
                    rest.plannedMinutes = parts[index...].reduce(0, +)
                    unplaced.append(rest)
                    break
                }
                let start = best.start
                let end = start.addingTimeInterval(duration)
                placedDays.insert(calendar.startOfDay(for: start))
                // Split the slot around the placement (with a buffer), keeping pieces long enough to use
                let slot = free.remove(at: best.slot)
                let buffer = TimeInterval(bufferMinutes * 60)
                let minimum = TimeInterval(SlotFinder.minimumMinutes * 60)
                let pieces = [DateInterval(start: slot.start, end: max(slot.start, start.addingTimeInterval(-buffer))),
                              DateInterval(start: min(end.addingTimeInterval(buffer), slot.end), end: slot.end)]
                free.append(contentsOf: pieces.filter { $0.duration >= minimum })
                free.sort { $0.start < $1.start }
                let reason = reasonText(task: task, start: start, energy: best.energy, threshold: threshold,
                                        part: parts.count > 1 ? (index + 1, parts.count) : nil, calendar: calendar)
                items.append(PlanProposal.Item(operation: operation(for: task, part: index, of: parts.count,
                                                                    start: start, end: end, minutes: minutes),
                                               reason: reason))
            }
        }
        return Result(items: items, unplaced: unplaced)
    }

    /// The slot's own start, then every whole hour after it where the block still fits
    static func candidateStarts(in slot: DateInterval, duration: TimeInterval, calendar: Calendar) -> [Date] {
        guard slot.duration >= duration else { return [] }
        var starts = [slot.start]
        var hour = calendar.dateInterval(of: .hour, for: slot.start).map { $0.end } ?? slot.start
        while hour.addingTimeInterval(duration) <= slot.end {
            if hour > slot.start { starts.append(hour) }
            hour = hour.addingTimeInterval(3600)
        }
        return starts
    }

    /// Higher is better. Hard tasks chase energy, light ones are happy in low-energy time; sooner beats later,
    /// and within a day earlier beats later so ordinary tasks land at the front of a free stretch.
    static func score(start: Date, energy: Double, task: TaskSnapshot, threshold: Double, today: Date, calendar: Calendar) -> Double {
        let days = Double(calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: start)).day ?? 0)
        let hours = start.timeIntervalSince(calendar.startOfDay(for: start)) / 3600
        let energyTerm: Double = switch task.effort {
        case .hard: energy >= threshold ? 2 + energy : energy
        case .light: (1 - energy) * 0.4
        default: energy * 0.6
        }
        // Urgent work goes as early as possible; a deadline pulls the same way
        let urgency = task.priority == .urgent || task.deadline != nil ? 0.5 : 0.15
        return energyTerm - urgency * days - 0.02 * hours
    }

    /// The first part converts the task itself (an idea becomes an event); later parts are new linked events
    static func operation(for task: TaskSnapshot, part: Int, of count: Int, start: Date, end: Date, minutes: Int) -> PlanProposal.Operation {
        if part == 0 {
            var event = task
            event.kind = .event
            event.isAllDay = false
            event.start = start
            event.end = end
            event.plannedMinutes = minutes
            if count > 1 { event.title = "\(task.title)（1/\(count)）" }
            return .update(event)
        }
        return .create(TaskSnapshot(
            title: "\(task.title)（\(part + 1)/\(count)）", start: start, end: end, isAllDay: false,
            priority: task.priority, plannedMinutes: minutes, kind: .event, goalID: task.goalID,
            deadline: task.deadline, category: task.category, effort: task.effort, parentID: task.id, source: .agent))
    }

    static func reasonText(task: TaskSnapshot, start: Date, energy: Double, threshold: Double,
                           part: (Int, Int)?, calendar: Calendar) -> String {
        let when = "\(TimeText.weekday(start, calendar: calendar)) \(TimeText.hhmm(start, calendar: calendar))"
        if task.effort == .hard && energy >= threshold {
            return "排在\(when)，这是你精力最好的时段之一"
        }
        if let deadline = task.deadline {
            let due = TimeText.weekday(deadline, calendar: calendar)
            return part.map { "第 \($0.0)/\($0.1) 块，赶在\(due)截止前完成" } ?? "排在\(when)，赶在\(due)截止前完成"
        }
        if let part {
            return "拆成 \(part.1) 块分天做，这是第 \(part.0) 块"
        }
        if task.priority == .urgent { return "紧急，放进最早的空档：\(when)" }
        return "放进\(when)的空档"
    }
}
