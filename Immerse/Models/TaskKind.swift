import Foundation

/// What a task is.
/// - event: has a concrete time, lives on the calendar (everything before this feature)
/// - idea: captured in the Inbox, not scheduled yet
/// - goal: spans a period (this week / this month), pushed forward by calendar events linked to it
enum TaskKind: String, Codable, CaseIterable, Sendable {
    case event
    case idea
    case goal
}
