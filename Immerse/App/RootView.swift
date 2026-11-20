import ImmerseCore
import SwiftUI

/// Main window: sidebar + calendar, with a toast floating at the bottom and a reminder panel when time is up
struct RootView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(TaskStore.self) private var taskStore
    @Environment(UpdateChecker.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            CalendarContainerView()
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
        }
        .overlay {
            TaskEditorOverlay()
        }
        .overlay {
            CommandPaletteOverlay()
        }
        .overlay {
            ImmersiveOverlay()
        }
        .overlay {
            FocusTimeUpOverlay()
        }
        // First launch: Do Not Disturb setup guide
        .sheet(isPresented: Binding(
            get: {
                (!settings.onboardingCompleted && !PersistenceController.isEphemeral)
                    || calendarStore.isOnboardingPresented || DebugFlags.forceOnboarding
            },
            set: { if !$0 { finishOnboarding() } }
        )) {
            OnboardingView(startAt: DebugFlags.onboardingStep, onFinish: finishOnboarding)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { updater.availableUpdate != nil },
            set: { if !$0 { updater.availableUpdate = nil } }
        )) {
            if let release = updater.availableUpdate {
                UpdateSheet(release: release)
            }
        }
        .alert(
            manualResultTitle,
            isPresented: Binding(
                get: { updater.manualResult != nil },
                set: { if !$0 { updater.manualResult = nil } }
            )
        ) {
            Button("好") { updater.manualResult = nil }
        } message: {
            Text(manualResultMessage)
        }
        .sheet(item: Bindable(calendarStore).pendingImport) { preview in
            ImportPreviewView(preview: preview)
        }
        .sheet(isPresented: Bindable(calendarStore).isDailyPlanPresented) {
            DailyPlanView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            presentDailyPlanIfDue()
        }
        .onAppear {
            presentDailyPlanIfDue()
            AppIcon.install()
            if DebugFlags.openStats { openWindow(id: "stats") }
            if DebugFlags.openSettings { openSettings() }
        }
        .alert(
            "已有进行中的专注",
            isPresented: Binding(
                get: { focusEngine.pendingSwitch != nil },
                set: { if !$0 { focusEngine.pendingSwitch = nil } }
            ),
            presenting: focusEngine.pendingSwitch
        ) { _ in
            Button("结束当前并开始新的") { focusEngine.confirmSwitch() }
            Button("取消", role: .cancel) { focusEngine.pendingSwitch = nil }
        } message: { task in
            Text("「\(focusEngine.session?.taskTitle ?? "")」还在专注中。要放弃它，开始「\(task.displayTitle)」吗？")
        }
    }

    private var manualResultTitle: String {
        switch updater.manualResult {
        case .upToDate: "已是最新版本"
        case .failed: "检查更新失败"
        case nil: ""
        }
    }

    private var manualResultMessage: String {
        switch updater.manualResult {
        case .upToDate(let version): "当前版本 \(version) 就是最新版。"
        case .failed(let message): message
        case nil: ""
        }
    }

    /// Once a day, the first time the app comes to the front: the Inbox and lagging goals next to today's free time
    private func presentDailyPlanIfDue(now: Date = .now) {
        guard settings.onboardingCompleted, !PersistenceController.isEphemeral,
              !calendarStore.isDailyPlanPresented, !calendarStore.isEditorPresented else { return }
        let calendar = calendarStore.calendar
        let hasContent = !taskStore.ideas().isEmpty || !GoalsSection.behindGoals(
            GoalsSection.activeGoals(taskStore: taskStore, calendar: calendar),
            taskStore: taskStore, focusEngine: focusEngine, calendar: calendar).isEmpty
        guard DailyPlan.shouldPresent(lastShown: settings.dailyPlanLastShown, now: now, hasContent: hasContent,
                                      isEnabled: settings.dailyPlanEnabled, calendar: calendar) else { return }
        settings.dailyPlanLastShown = now
        calendarStore.isDailyPlanPresented = true
    }

    private func finishOnboarding() {
        settings.onboardingCompleted = true
        calendarStore.isOnboardingPresented = false
    }
}
