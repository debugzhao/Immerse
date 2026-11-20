import Foundation

/// Goal lookups that combine the task store with focus records (shared by both apps and the secretary)
@MainActor
public enum GoalQueries {
    public static func progress(of goal: TaskSnapshot, taskStore: TaskStore, focusEngine: FocusEngine,
                                calendar: Calendar, now: Date = .now) -> GoalProgress {
        GoalProgress(goal: goal,
                     linkedEvents: taskStore.events(linkedTo: goal.id),
                     records: focusEngine.records(in: goal.displayInterval(in: calendar)),
                     now: now, calendar: calendar)
    }

    /// Goals whose period isn't over, unfinished first; within each group the hand-made order,
    /// then goals never reordered by end date
    public static func active(taskStore: TaskStore, calendar: Calendar, now: Date = .now) -> [TaskSnapshot] {
        taskStore.goals()
            .filter { $0.isActiveGoal(now: now, calendar: calendar) }
            .sorted { a, b in
                if (a.status == .done) != (b.status == .done) { return b.status == .done }
                switch (a.sortOrder, b.sortOrder) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.displayInterval(in: calendar).end < b.displayInterval(in: calendar).end
                }
            }
    }

    /// Unfinished goals that are clearly behind schedule
    public static func behind(_ goals: [TaskSnapshot], taskStore: TaskStore, focusEngine: FocusEngine,
                              calendar: Calendar, now: Date = .now) -> [TaskSnapshot] {
        goals.filter {
            $0.status != .done
                && progress(of: $0, taskStore: taskStore, focusEngine: focusEngine, calendar: calendar, now: now).isBehind
        }
    }
}
