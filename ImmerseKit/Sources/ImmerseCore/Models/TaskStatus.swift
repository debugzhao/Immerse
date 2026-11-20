import Foundation

/// Task status. The Notion "Done" checkbox duplicates it and has been merged in here.
public enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo
    case inProgress
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "未开始"
        case .inProgress: "进行中"
        case .done: "已完成"
        }
    }
}
