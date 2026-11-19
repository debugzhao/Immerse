import Foundation
import Observation
import OSLog

/// A toast at the bottom, optionally with an "Undo" button
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var showsUndo: Bool = false
}

/// Entry point for reading and writing task data.
///
/// - Reads: views call methods like `tasks(in:)`, which read `revision` internally to establish a dependency, so views refresh when data changes.
/// - Writes: every write registers an inverse operation with `undoManager`, and running it registers the original back, so undo / redo come for free.
@MainActor
@Observable
final class TaskStore {
    @ObservationIgnored private let repository: TaskRepository
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "TaskStore")
    @ObservationIgnored let undoManager: UndoManager
    /// Merges consecutive edits to the same field (e.g. typing in the detail panel) into one undo step
    @ObservationIgnored private var lastCoalescing: (key: String, at: Date)?
    @ObservationIgnored private let coalescingWindow: TimeInterval = 2

    /// Data revision number. Read methods access it internally so SwiftUI establishes a dependency.
    private(set) var revision = 0
    var toast: Toast?

    init(repository: TaskRepository, undoManager: UndoManager = UndoManager()) {
        self.repository = repository
        self.undoManager = undoManager
        undoManager.levelsOfUndo = 100
        // By default all changes in one run-loop turn merge into a single undo step; group each operation explicitly for predictable behavior
        undoManager.groupsByEvent = false
    }

    // MARK: - Reading

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

    /// Inbox ideas, newest first
    func ideas() -> [TaskSnapshot] {
        _ = revision
        return (attempt("读取收集箱") { try repository.tasks(kind: .idea) } ?? []).reversed()
    }

    func goals() -> [TaskSnapshot] {
        _ = revision
        return attempt("读取目标") { try repository.tasks(kind: .goal) } ?? []
    }

    func events(linkedTo goalID: UUID) -> [TaskSnapshot] {
        _ = revision
        return attempt("读取目标日程") { try repository.events(linkedTo: goalID) } ?? []
    }

    // MARK: - Writing

    @discardableResult
    func create(_ snapshot: TaskSnapshot, actionName: String = "新建日程") -> TaskSnapshot {
        breakCoalescing()
        undoStep(actionName) { applyUpsert(snapshot, previous: nil) }
        return snapshot
    }

    /// Bulk import: undone as a single step
    func importTasks(_ snapshots: [TaskSnapshot]) {
        guard !snapshots.isEmpty else { return }
        breakCoalescing()
        undoStep("导入 \(snapshots.count) 个日程") {
            for snapshot in snapshots {
                applyUpsert(snapshot, previous: nil)
            }
        }
    }

    /// - Parameter coalescingKey: consecutive edits with the same key within a short window merge into one undo step
    func update(_ snapshot: TaskSnapshot, actionName: String = "修改日程", coalescingKey: String? = nil) {
        guard let previous = task(id: snapshot.id), previous != snapshot else { return }

        if let key = coalescingKey,
           let last = lastCoalescing, last.key == key,
           Date.now.timeIntervalSince(last.at) < coalescingWindow {
            // Coalesce: only write data without registering a new undo step, so undo goes straight back to before this run of edits
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

    /// Focus engine state changes: kept off the undo stack, otherwise ⌘Z would revert "in progress" and fall out of sync with the timer state
    func setStatusWithoutUndo(_ status: TaskStatus, for id: UUID) {
        guard var snapshot = task(id: id), snapshot.status != status else { return }
        snapshot.status = status
        breakCoalescing()
        undoManager.disableUndoRegistration()
        defer { undoManager.enableUndoRegistration() }
        applyUpsert(snapshot, previous: nil)
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

    // MARK: - Undo

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

    /// Call before editing something else, so unrelated changes are not merged into one undo step
    func breakCoalescing() {
        lastCoalescing = nil
    }

    /// One user action = one undo step
    private func undoStep(_ name: String, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    // MARK: - Atomic operations (inverse registered automatically)

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
    /// Display text when the title is empty
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（无标题）" : trimmed
    }
}
