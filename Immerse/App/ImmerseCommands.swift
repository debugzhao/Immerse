import AppKit
import SwiftUI

/// 菜单栏命令：新建、删除、撤销 / 重做、搜索、专注
struct ImmerseCommands: Commands {
    let environment: AppEnvironment

    private var taskStore: TaskStore { environment.taskStore }
    private var calendarStore: CalendarStore { environment.calendarStore }
    private var focusEngine: FocusEngine { environment.focusEngine }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建日程") { newTask() }
                .keyboardShortcut("n")
        }

        CommandGroup(replacing: .importExport) {
            Button("导入 Notion CSV…") { importNotion() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
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
                // 正在输入文字时 ⌘⌫ 是删除到行首
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    textView.deleteToBeginningOfLine(nil)
                    return
                }
                guard let id = calendarStore.selectedTaskID else { return }
                calendarStore.select(nil)
                taskStore.delete(id: id)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("搜索日程") { calendarStore.wantsSearchFocus = true }
                .keyboardShortcut("f")
            Button("命令面板") { calendarStore.isCommandPalettePresented.toggle() }
                .keyboardShortcut("k")
        }

        CommandGroup(after: .toolbar) {
            Button("回到今天") { calendarStore.goToToday() }
            Button("日视图") { calendarStore.mode = .day }
            Button("周视图") { calendarStore.mode = .week }
            Button("月视图") { calendarStore.mode = .month }
            Divider()
            Button("进入沉浸模式") { focusEngine.isImmersivePresented = true }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!focusEngine.isActive)
            Divider()
        }

        CommandMenu("专注") {
            Button("开始专注选中的日程") {
                if let submit = calendarStore.submitDraft {
                    submit()
                } else if let task = taskStore.task(id: calendarStore.selectedTaskID) {
                    focusEngine.requestStart(task)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("暂停 / 继续") { focusEngine.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("延长 15 分钟") { focusEngine.extend() }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("提前完成") { focusEngine.finishEarly() }
            Button("放弃本次专注") { focusEngine.abandon() }
        }
    }

    private func newTask() {
        let interval = calendarStore.defaultNewEventInterval()
        let hour = calendarStore.calendar.component(.hour, from: interval.start)
        calendarStore.select(nil)
        calendarStore.anchorDate = interval.start
        calendarStore.scrollRequest = ScrollRequest(hour: max(hour - 1, 0))
        calendarStore.draft = DraftEvent(start: interval.start, end: interval.end)
    }

    private func importNotion() {
        switch NotionImport.pickAndParse(existing: taskStore.allTasks()) {
        case .success(let preview): calendarStore.pendingImport = preview
        case .failure(let error): taskStore.toast = Toast(message: "导入失败：\(error.localizedDescription)")
        case nil: break
        }
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
