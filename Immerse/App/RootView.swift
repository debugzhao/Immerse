import SwiftUI

/// Main window: sidebar + calendar, with a toast floating at the bottom and a reminder panel when time is up
struct RootView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarStore.self) private var calendarStore
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
        .sheet(item: Bindable(calendarStore).pendingImport) { preview in
            ImportPreviewView(preview: preview)
        }
        .onAppear {
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

    private func finishOnboarding() {
        settings.onboardingCompleted = true
        calendarStore.isOnboardingPresented = false
    }
}
