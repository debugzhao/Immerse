#if DEBUG
import AppKit
import SwiftUI

/// 开发用：App 自己把主窗口画成 PNG，不需要系统「屏幕录制」权限。
///
/// 用法：IMMERSE_SNAPSHOT=/tmp/shot.png open Immerse.app，截完图后自动退出。可选参数：
/// - IMMERSE_APPEARANCE=dark|light：外观
/// - IMMERSE_SELECT=<标题关键字>：选中第一个匹配的日程（打开详情面板）
/// - IMMERSE_SEARCH=<关键字>：在搜索框里输入
/// - IMMERSE_MODE=day|week|month：日历视图
/// - IMMERSE_FILTER=urgent：只显示紧急
///
/// 注意：透出桌面的毛玻璃（behindWindow）在截图里是纯色，真实效果以屏幕为准。
@MainActor
enum DebugSnapshot {
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
        if let keyword = env["IMMERSE_SEARCH"] {
            environment.calendarStore.searchText = keyword
        }

        Task { @MainActor in
            // 等窗口布局、滚动定位、动画都完成
            try? await Task.sleep(for: .seconds(2.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
#endif
