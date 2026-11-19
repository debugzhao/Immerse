import AppKit
import SwiftUI

enum DebugFlags {
    /// IMMERSE_STATS=1: open the focus stats window when taking the screenshot
    static var openStats: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_STATS"] != nil
        #else
        false
        #endif
    }

    /// IMMERSE_SETTINGS=1: open the settings window when taking the screenshot
    static var openSettings: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_SETTINGS"] != nil
        #else
        false
        #endif
    }

    /// IMMERSE_ONBOARDING=1: force the first-run onboarding when taking the screenshot
    /// IMMERSE_ONBOARDING=<0-3>: which onboarding step to show
    static var onboardingStep: OnboardingView.Step {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_ONBOARDING"].flatMap(Int.init).flatMap(OnboardingView.Step.init) ?? .welcome
        #else
        .welcome
        #endif
    }

    static var forceOnboarding: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_ONBOARDING"] != nil
        #else
        false
        #endif
    }
}

#if DEBUG

/// Dev only: the app renders its own main window to a PNG, so no system "Screen Recording" permission is needed.
///
/// Usage: IMMERSE_SNAPSHOT=/tmp/shot.png open Immerse.app; it quits automatically after the capture. Optional parameters:
/// - IMMERSE_APPEARANCE=dark|light: appearance
/// - IMMERSE_SELECT=<title keyword>: select the first matching event (opens the detail panel)
/// - IMMERSE_SEARCH=<keyword>: type into the search field
/// - IMMERSE_MODE=day|week|month: calendar view
/// - IMMERSE_FILTER=urgent: show urgent only
/// - IMMERSE_EDIT=<title keyword> / IMMERSE_CREATE=1: open the event sheet
///
/// Note: the frosted glass that shows the desktop through (behindWindow) renders as a solid color in screenshots; the real effect is as seen on screen.
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
        // IMMERSE_EDIT=<title keyword>: open the event sheet (edit)
        if let keyword = env["IMMERSE_EDIT"],
           var task = environment.taskStore.search(keyword).first {
            // IMMERSE_NOTES=<text>: write the notes first (\n for newline), to check Markdown highlighting
            if let notes = env["IMMERSE_NOTES"] {
                task.notes = notes.replacingOccurrences(of: "\\n", with: "\n")
                environment.taskStore.update(task)
            }
            environment.calendarStore.reveal(task)
            environment.calendarStore.openEditor(task.id)
        }
        // IMMERSE_UNSAVED=<title>: simulate unsaved create content from last time (use with IMMERSE_CREATE)
        if let title = env["IMMERSE_UNSAVED"] {
            environment.calendarStore.unsavedDraft = TaskSnapshot(title: title, start: .now, end: nil, isAllDay: false,
                                                                  priority: .important, notes: "- [ ] 列提纲\n- [ ] 写初稿")
        }
        // IMMERSE_CREATE=1: open the create sheet (same as ⌘N)
        if env["IMMERSE_CREATE"] != nil {
            let interval = environment.calendarStore.defaultNewEventInterval()
            environment.calendarStore.draft = DraftEvent(start: interval.start, end: interval.end, usesDefaultTime: true)
        }
        // IMMERSE_HOVER=<title keyword>: simulate the mouse hovering over an event
        if let keyword = env["IMMERSE_HOVER"], let task = environment.taskStore.search(keyword).first {
            environment.calendarStore.hoveredTaskID = task.id
        }
        if let keyword = env["IMMERSE_SEARCH"] {
            environment.calendarStore.searchText = keyword
        }
        // IMMERSE_FOCUS=<title keyword>[,seconds]: start focus; with a very short duration you can capture the "time up" panel
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

        // IMMERSE_STATS=1: capture the focus stats window
        if env["IMMERSE_STATS"] != nil {
            statsRequested = true
        }
        // IMMERSE_SETTINGS=1: capture the settings window (Reminders page)
        let settingsRequested = DebugFlags.openSettings
        // IMMERSE_PALETTE=<input>: open the ⌘K command palette (typed input cannot be captured, only an empty palette, for checking styling)
        if env["IMMERSE_PALETTE"] != nil {
            environment.calendarStore.isCommandPalettePresented = true
        }
        // IMMERSE_IMMERSIVE=1: enter the immersive view (requires IMMERSE_FOCUS too)
        if env["IMMERSE_IMMERSIVE"] != nil {
            environment.focusEngine.isImmersivePresented = true
        }
        // IMMERSE_CHECK_SHORTCUTS=<output file>: run `shortcuts list` once inside the app process to verify the call chain
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
            // Wait for the window layout, scroll positioning, and animations to finish
            try? await Task.sleep(for: .seconds(2.5))
            let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 500 }
            let preferred = settingsRequested ? candidates.first { $0.title == "提醒" }
                : statsRequested ? candidates.first { $0.title == "专注统计" }
                : candidates.first { $0.title != "专注统计" && $0.frame.width > 600 }
            guard let mainWindow = preferred ?? candidates.first else {
                exit(0)
            }
            // When a sheet is presented, capture the sheet
            let window = mainWindow.attachedSheet ?? mainWindow
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // Do not use NSApp.terminate: quitting is deferred while a sheet is presented
            exit(0)
        }
    }
}
#endif
