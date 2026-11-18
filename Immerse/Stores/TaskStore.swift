import Foundation
import Observation
import OSLog

/// 底部的轻提示，可带「撤销」按钮
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var showsUndo: Bool = false
}

/// 任务数据的读写入口。
///
/// - 读：视图调用 `tasks(in:)` 等方法，方法内部读取 `revision` 建立依赖，数据一变视图自动刷新。
/// - 写：每个写操作都向 `undoManager` 注册逆操作，逆操作执行时又会注册回来，于是撤销 / 重做都是免费的。
@MainActor
@Observable
final class TaskStore {
    @ObservationIgnored private let repository: TaskRepository
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "TaskStore")
    @ObservationIgnored let undoManager: UndoManager
    /// 连续编辑同一个字段（比如在详情面板里打字）时合并成一步撤销
    @ObservationIgnored private var lastCoalescing: (key: String, at: Date)?
    @ObservationIgnored private let coalescingWindow: TimeInterval = 2

    /// 数据版本号。读取方法内部会访问它，从而让 SwiftUI 建立依赖。
    private(set) var revision = 0
    var toast: Toast?

    init(repository: TaskRepository, undoManager: UndoManager = UndoManager()) {
        self.repository = repository
        self.undoManager = undoManager
        undoManager.levelsOfUndo = 100
        // 默认会把同一个事件循环里的所有修改合并成一步撤销；改成每个操作显式分组，行为可预期
        undoManager.groupsByEvent = false
    }

    // MARK: - 读取

    func tasks(in interval: DateInterval) -> [TaskSnapshot] {
        _ = revision
        return attempt("读取任务") { try repository.tasks(in: interval) } ?? []
    }

    func task(id: UUID?) -> TaskSnapshot? {
        _ = revision
        guard let id else { return nil }
        return attempt("读取任务") { try repository.task(id: id) } ?? nil
    }

    func search(_ keyword: String, limit: Int = 50) -> [TaskSnapshot] {
        _ = revision
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return attempt("搜索") { try repository.search(trimmed, limit: limit) } ?? []
    }

    func allTasks() -> [TaskSnapshot] {
        _ = revision
        return attempt("读取任务") { try repository.allTasks() } ?? []
    }

    // MARK: - 写入

    @discardableResult
    func create(_ snapshot: TaskSnapshot, actionName: String = "新建日程") -> TaskSnapshot {
        breakCoalescing()
        undoStep(actionName) { applyUpsert(snapshot, previous: nil) }
        return snapshot
    }

    /// 批量导入：整体作为一步撤销
    func importTasks(_ snapshots: [TaskSnapshot]) {
        guard !snapshots.isEmpty else { return }
        breakCoalescing()
        undoStep("导入 \(snapshots.count) 个日程") {
            for snapshot in snapshots {
                applyUpsert(snapshot, previous: nil)
            }
        }
    }

    /// - Parameter coalescingKey: 相同 key 在短时间内的连续修改合并成一步撤销
    func update(_ snapshot: TaskSnapshot, actionName: String = "修改日程", coalescingKey: String? = nil) {
        guard let previous = task(id: snapshot.id), previous != snapshot else { return }

        if let key = coalescingKey,
           let last = lastCoalescing, last.key == key,
           Date.now.timeIntervalSince(last.at) < coalescingWindow {
            // 合并：只写数据，不注册新的撤销步骤，撤销时直接回到这一串编辑之前
            lastCoalescing = (key, .now)
            undoManager.disableUndoRegistration()
            applyUpsert(snapshot, previous: previous)
            undoManager.enableUndoRegistration()
            return
        }

        lastCoalescing = coalescingKey.map { ($0, .now) }
        undoStep(actionName) { applyUpsert(snapshot, previous: previous) }
    }

    func delete(id: UUID, showsToast: Bool = true) {
        guard let previous = task(id: id) else { return }
        breakCoalescing()
        undoStep("删除日程") { applyDelete(previous) }
        if showsToast {
            toast = Toast(message: "已删除「\(previous.displayTitle)」", showsUndo: true)
        }
    }

    func setStatus(_ status: TaskStatus, for id: UUID) {
        guard var snapshot = task(id: id), snapshot.status != status else { return }
        snapshot.status = status
        update(snapshot, actionName: status == .done ? "标记完成" : "修改状态")
    }

    func toggleDone(_ id: UUID) {
        guard let snapshot = task(id: id) else { return }
        setStatus(snapshot.status == .done ? .todo : .done, for: id)
    }

    func setPriority(_ priority: Priority, for id: UUID) {
        guard var snapshot = task(id: id) else { return }
        snapshot.priority = priority
        update(snapshot, actionName: "修改优先级")
    }

    // MARK: - 撤销

    var canUndo: Bool { _ = revision; return undoManager.canUndo }
    var canRedo: Bool { _ = revision; return undoManager.canRedo }

    func undo() {
        breakCoalescing()
        guard undoManager.canUndo else { return }
        let name = undoManager.undoActionName
        undoManager.undo()
        toast = Toast(message: name.isEmpty ? "已撤销" : "已撤销：\(name)")
    }

    func redo() {
        breakCoalescing()
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    /// 在编辑别的东西前调用，避免把不相关的修改合并到一步撤销里
    func breakCoalescing() {
        lastCoalescing = nil
    }

    /// 一个用户操作 = 一步撤销
    private func undoStep(_ name: String, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    // MARK: - 原子操作（自动注册逆操作）

    private func applyUpsert(_ snapshot: TaskSnapshot, previous: TaskSnapshot?) {
        guard attempt("保存", { try repository.upsert(snapshot) }) != nil else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                if let previous {
                    store.applyUpsert(previous, previous: snapshot)
                } else {
                    store.applyDelete(snapshot)
                }
            }
        }
        revision += 1
    }

    private func applyDelete(_ snapshot: TaskSnapshot) {
        guard attempt("删除", { try repository.delete(id: snapshot.id) }) != nil else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.applyUpsert(snapshot, previous: nil)
            }
        }
        revision += 1
    }

    @discardableResult
    private func attempt<T>(_ label: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            logger.error("\(label, privacy: .public)失败：\(error.localizedDescription, privacy: .public)")
            toast = Toast(message: "\(label)失败：\(error.localizedDescription)")
            return nil
        }
    }
}

extension TaskSnapshot {
    /// 标题为空时的显示文字
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（无标题）" : trimmed
    }
}
