import Foundation
import ImmerseCore

/// Checks a proposal before it is shown: drops items that can't apply, and lists conflicts and overload as warnings
public enum ProposalValidator {
    public static func validate(_ proposal: PlanProposal, context: PlanningContext) -> PlanProposal {
        var result = proposal
        let known = Dictionary(context.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let calendar = context.calendar
        result.items = proposal.items.filter { item in
            guard !item.reason.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            switch item.operation {
            case .create(let task):
                return !task.title.trimmingCharacters(in: .whitespaces).isEmpty && known[task.id] == nil
            case .move(let id, let start, let end):
                return known[id] != nil && (end.map { $0 >= start } ?? true)
            case .update(let task):
                return known[task.id] != nil && !task.title.trimmingCharacters(in: .whitespaces).isEmpty
            case .toInbox(let id):
                return known[id] != nil
            }
        }

        // What the calendar would look like with every selected item applied
        var after = known
        for item in result.selectedItems {
            switch item.operation {
            case .create(let task), .update(let task): after[task.id] = task
            case .move(let id, let start, let end):
                after[id]?.start = start
                after[id]?.end = end
                after[id]?.isAllDay = false
                if after[id]?.kind == .idea { after[id]?.kind = .event }
            case .toInbox(let id): after[id]?.kind = .idea
            }
        }
        var warnings: [String] = []
        let fixedExternal = context.externalEvents.filter { !$0.isAllDay }
        let affected = Set(result.selectedItems.map(\.operation.taskID))
        for id in affected {
            guard let task = after[id], task.kind == .event, !task.isAllDay else { continue }
            let interval = task.displayInterval(in: calendar)
            if let clash = fixedExternal.first(where: { DateInterval(start: $0.start, end: $0.end).overlapsHalfOpen(interval) }) {
                warnings.append("「\(task.displayTitle)」和「\(clash.title)」时间冲突")
            }
            if let clash = after.values.first(where: { other in
                // A pair of proposed items would be found from both sides; report it once
                other.id != id && !(affected.contains(other.id) && other.id.uuidString < id.uuidString)
                    && other.kind == .event && !other.isAllDay && other.status != .done
                    && other.displayInterval(in: calendar).overlapsHalfOpen(interval)
            }) {
                warnings.append("「\(task.displayTitle)」和「\(clash.displayTitle)」时间重叠")
            }
        }
        var afterContext = context
        afterContext.tasks = Array(after.values)
        let days = Set(affected.compactMap { after[$0] }.filter { $0.kind == .event }.map { calendar.startOfDay(for: $0.start) })
        for day in days.sorted() {
            let load = LoadEstimator.load(on: day, context: afterContext)
            if load.isOverloaded {
                warnings.append("\(TimeText.weekday(day, calendar: calendar))将过载 \(DurationText.minutes(load.overloadMinutes * 60))")
            }
        }
        var seen: Set<String> = []
        result.warnings = warnings.filter { seen.insert($0).inserted }
        return result
    }
}

/// Writes a proposal's selected items as one undo step
@MainActor
public enum ProposalApplier {
    @discardableResult
    public static func apply(_ proposal: PlanProposal, to store: TaskStore) -> Int {
        var upserts: [TaskSnapshot] = []
        for item in proposal.selectedItems {
            switch item.operation {
            case .create(var task):
                task.proposalID = proposal.id
                task.source = task.source ?? .agent
                upserts.append(task)
            case .update(var task):
                task.proposalID = proposal.id
                upserts.append(task)
            case .move(let id, let start, let end):
                guard var task = upserts.first(where: { $0.id == id }) ?? store.task(id: id) else { continue }
                upserts.removeAll { $0.id == id }
                task.start = start
                task.end = end
                task.isAllDay = false
                if task.kind == .idea { task.kind = .event }
                task.proposalID = proposal.id
                upserts.append(task)
            case .toInbox(let id):
                guard var task = store.task(id: id) else { continue }
                task.kind = .idea
                task.isAllDay = false
                task.end = nil
                task.proposalID = proposal.id
                upserts.append(task)
            }
        }
        store.applyBatch(upserts: upserts, actionName: "应用秘书提案")
        return upserts.count
    }
}

/// Keeps pending proposals on disk (e.g. the evening review's, opened later from a notification).
/// Device-local on purpose: proposals are short-lived and never synced.
public final class ProposalStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(directory: URL) {
        url = directory.appendingPathComponent("proposals.json")
    }

    public func all(now: Date = .now) -> [PlanProposal] {
        lock.withLock { load().filter { !$0.isExpired(at: now) } }
    }

    public func proposal(id: UUID) -> PlanProposal? { all().first { $0.id == id } }

    public func save(_ proposal: PlanProposal) {
        lock.withLock {
            var proposals = load().filter { $0.id != proposal.id && !$0.isExpired(at: .now) }
            proposals.append(proposal)
            write(proposals)
        }
    }

    public func remove(id: UUID) {
        lock.withLock { write(load().filter { $0.id != id }) }
    }

    private func load() -> [PlanProposal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlanProposal].self, from: data)) ?? []
    }

    private func write(_ proposals: [PlanProposal]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(proposals).write(to: url, options: .atomic)
    }
}
