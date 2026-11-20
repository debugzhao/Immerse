import Foundation

/// What kind of work a task is. Drives estimate calibration and the energy curve, so the set is fixed and small.
public enum TaskCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepWork
    case reading
    case writing
    case meeting
    case admin
    case learning
    case exercise
    case life

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deepWork: "深度工作"
        case .reading: "阅读"
        case .writing: "写作"
        case .meeting: "会议"
        case .admin: "杂务"
        case .learning: "学习"
        case .exercise: "运动"
        case .life: "生活"
        }
    }
}

/// How demanding a task is; hard tasks are placed in the user's high-energy hours
public enum TaskEffort: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case light = 1
    case medium = 2
    case hard = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .light: "轻松"
        case .medium: "一般"
        case .hard: "费脑"
        }
    }

    public static func < (lhs: TaskEffort, rhs: TaskEffort) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a task came from, for understanding which capture entries people actually use
public enum TaskSource: String, Codable, CaseIterable, Sendable {
    case manual
    case voice
    case clipboard
    case siri
    case share
    case agent
    case notionImport
}
