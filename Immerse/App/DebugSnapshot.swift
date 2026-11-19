import AppKit
import SwiftUI

enum DebugFlags {
    /// IMMERSE_STATS=1：截图时打开专注统计窗口
    static var openStats: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_STATS"] != nil
        #else
        false
        #endif
    }

    /// IMMERSE_ONBOARDING=1：截图时强制显示首次引导
    static var forceOnboarding: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_ONBOARDING"] != nil
        #else
        false
        #endif
    }
}

#if DEBUG

/// 开发用：App 自己把主窗口画成 PNG，不需要系统「屏幕录制」权限。
///
/// 用法：IMMERSE_SNAPSHOT=/tmp/shot.png open Immerse.app，截完图后自动退出。可选参数：
/// - IMMERSE_APPEARANCE=dark|light：外观
/// - IMMERSE_SELECT=<标题关键字>：选中第一个匹配的日程（打开详情面板）
/// - IMMERSE_SEARCH=<关键字>：在搜索框里输入
/// - IMMERSE_MODE=day|week|month：日历视图
/// - IMMERSE_FILTER=urgent：只显示紧急
/// - IMMERSE_EDIT=<标题关键字> / IMMERSE_CREATE=1：打开日程弹窗
///
/// 注意：透出桌面的毛玻璃（behindWindow）在截图里是纯色，真实效果以屏幕为准。
@MainActor
enum DebugSnapshot {
    private static var statsRequested = false

    static func scheduleIfRequested(environment: AppEnvironment) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IMMERSE_SNAPSHOT"] else { return }

        if let appearance = env["IMMERSE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let mode = env["IMMERSE_MODE"].flatMap(CalendarMode.init(rawValue:)) {
            environment.calendarStore.mode = mode
        }
        if env["IMMERSE_FILTER"] == "urgent" {
            environment.calendarStore.priorityFilter = [.urgent]
        }
        if let keyword = env["IMMERSE_SELECT"],
           let task = environment.taskStore.search(keyword).first {
            environment.calendarStore.reveal(task)
        }
        // IMMERSE_EDIT=<标题关键字>：打开日程弹窗（编辑）
        if let keyword = env["IMMERSE_EDIT"],
           let task = environment.taskStore.search(keyword).first {
            environment.calendarStore.reveal(task)
            environment.calendarStore.openEditor(task.id)
        }
        // IMMERSE_CREATE=1：打开新建弹窗（同 ⌘N）
        if env["IMMERSE_CREATE"] != nil {
            let interval = environment.calendarStore.defaultNewEventInterval()
            environment.calendarStore.draft = DraftEvent(start: interval.start, end: interval.end)
        }
        if let keyword = env["IMMERSE_SEARCH"] {
            environment.calendarStore.searchText = keyword
        }
        // IMMERSE_FOCUS=<标题关键字>[,秒数]：开始专注；秒数很短时可以截到「时间到」面板
        if let spec = env["IMMERSE_FOCUS"] {
            let parts = spec.split(separator: ",").map(String.init)
            if var task = environment.taskStore.search(parts[0]).first {
                if parts.count > 1, let seconds = Int(parts[1]) {
                    task.plannedMinutes = 1
                    environment.focusEngine.start(task)
                    environment.focusEngine.extend(seconds: seconds - 60)
                } else {
                    environment.focusEngine.start(task)
                }
            }
        }

        // IMMERSE_STATS=1：截专注统计窗口
        if env["IMMERSE_STATS"] != nil {
            statsRequested = true
        }
        // IMMERSE_PALETTE=<输入内容>：打开 ⌘K 命令面板（输入内容只能截到空面板，用于看样式）
        if env["IMMERSE_PALETTE"] != nil {
            environment.calendarStore.isCommandPalettePresented = true
        }
        // IMMERSE_IMMERSIVE=1：进入沉浸视图（需同时 IMMERSE_FOCUS）
        if env["IMMERSE_IMMERSIVE"] != nil {
            environment.focusEngine.isImmersivePresented = true
        }
        // IMMERSE_CHECK_SHORTCUTS=<输出文件>：在 App 进程里跑一次 shortcuts list，验证调用链路
        if let output = env["IMMERSE_CHECK_SHORTCUTS"] {
            Task { @MainActor in
                let result: String
                do {
                    let names = try await ShortcutsRunner.list()
                    result = "ok count=\(names.count)\n" + names.joined(separator: "\n")
                } catch {
                    result = "error \(error.localizedDescription)"
                }
                try? result.write(toFile: output, atomically: true, encoding: .utf8)
            }
        }

        Task { @MainActor in
            // 等窗口布局、滚动定位、动画都完成
            try? await Task.sleep(for: .seconds(2.5))
            let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }
            let preferred = statsRequested ? candidates.first { $0.title == "专注统计" } : candidates.first { $0.title != "专注统计" }
            guard let mainWindow = preferred ?? candidates.first else {
                exit(0)
            }
            // 有弹出的 sheet 时截 sheet
            let window = mainWindow.attachedSheet ?? mainWindow
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // 不用 NSApp.terminate：有 sheet 弹出时退出会被推迟
            exit(0)
        }
    }
}
#endif
