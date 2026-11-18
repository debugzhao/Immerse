import Foundation

/// 任务状态。Notion 里的「完成」复选框与它重复，已合并到这里。
enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo
    case inProgress
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: "未开始"
        case .inProgress: "进行中"
        case .done: "已完成"
        }
    }
}
