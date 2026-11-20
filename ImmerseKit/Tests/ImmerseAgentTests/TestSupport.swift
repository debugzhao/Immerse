import Foundation
import ImmerseCore
@testable import ImmerseAgent

/// Fixed clock and calendar for the agent tests: Wednesday 2026-11-18 08:00 in Asia/Shanghai
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar.app
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static let now = date(18, 8)

    static func event(_ title: String, _ day: Int, _ hour: Int, _ minute: Int = 0, minutes: Int = 60,
                      priority: Priority = .normal, status: TaskStatus = .todo, place: String? = nil,
                      category: TaskCategory? = nil) -> TaskSnapshot {
        let start = date(day, hour, minute)
        return TaskSnapshot(title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: false,
                            priority: priority, status: status, place: place, category: category)
    }

    static func idea(_ title: String, minutes: Int? = nil, priority: Priority = .normal, deadline: Date? = nil,
                     effort: TaskEffort? = nil, category: TaskCategory? = nil) -> TaskSnapshot {
        TaskSnapshot(title: title, start: now, isAllDay: false, priority: priority, plannedMinutes: minutes, kind: .idea,
                     deadline: deadline, category: category, effort: effort)
    }

    static func record(_ task: TaskSnapshot?, day: Int, hour: Int, minutes: Int, reason: FocusEndReason = .completed) -> FocusRecord {
        let start = date(day, hour)
        return FocusRecord(id: UUID(), taskID: task?.id, taskTitle: task?.title ?? "", startedAt: start,
                           endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)), focusedSeconds: minutes * 60, reason: reason)
    }

    static func context(tasks: [TaskSnapshot] = [], records: [FocusRecord] = [], external: [ExternalEvent] = [],
                        constraints: [MemoryConstraint] = [], multipliers: [TaskCategory: Double] = [:],
                        now: Date = now) -> PlanningContext {
        PlanningContext(tasks: tasks, records: records, externalEvents: external, constraints: constraints,
                        multipliers: multipliers, now: now, calendar: calendar)
    }
}

/// Plays back scripted responses and records every request it was sent
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    private var responses: [Result<LLMResponse, LLMError>]
    private(set) var requests: [LLMRequest] = []
    private let lock = NSLock()

    init(_ responses: [Result<LLMResponse, LLMError>]) {
        self.responses = responses
    }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        let next: Result<LLMResponse, LLMError> = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? .failure(.invalidResponse) : responses.removeFirst()
        }
        return try next.get()
    }

    static func toolUse(_ calls: [(String, JSONValue)], text: String = "", thinking: Bool = true) -> LLMResponse {
        var content: [JSONValue] = []
        if thinking { content.append(["type": "thinking", "thinking": "", "signature": "sig-abc"]) }
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        for (index, call) in calls.enumerated() {
            content.append(["type": "tool_use", "id": .string("toolu_\(index)_\(call.0)"), "name": .string(call.0), "input": call.1])
        }
        return LLMResponse(content: content, stopReason: "tool_use", usage: { var u = LLMUsage(); u.inputTokens = 100; u.outputTokens = 20; return u }())
    }

    static func text(_ text: String, stopReason: String = "end_turn") -> LLMResponse {
        LLMResponse(content: [["type": "text", "text": .string(text)]], stopReason: stopReason)
    }
}
