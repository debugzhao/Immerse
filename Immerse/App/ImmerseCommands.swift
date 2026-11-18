import AppKit
import SwiftUI

/// 菜单栏命令：新建、删除、撤销 / 重做、搜索
struct ImmerseCommands: Commands {
    let taskStore: TaskStore
    let calendarStore: CalendarStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建日程") { newTask() }
                .keyboardShortcut("n")
        }

        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { performUndo() }
                .keyboardShortcut("z")
            Button("重做") { performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("删除日程") {
                guard let id = calendarStore.selectedTaskID else { return }
                calendarStore.select(nil)
                taskStore.delete(id: id)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("搜索日程") { calendarStore.wantsSearchFocus = true }
                .keyboardShortcut("f")
        }
    }

    private func newTask() {
        let interval = calendarStore.defaultNewEventInterval()
        let task = taskStore.create(TaskSnapshot(
            title: "",
            start: interval.start,
            end: interval.end,
            isAllDay: false
        ))
        calendarStore.anchorDate = interval.start
        calendarStore.wantsTitleFocus = true
        calendarStore.select(task.id)
    }

    /// 正在编辑文字时，撤销交给文本框自己；否则撤销日程操作
    private func performUndo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let manager = textView.undoManager, manager.canUndo {
            manager.undo()
        } else {
            taskStore.undo()
        }
    }

    private func performRedo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let manager = textView.undoManager, manager.canRedo {
            manager.redo()
        } else {
            taskStore.redo()
        }
    }
}
