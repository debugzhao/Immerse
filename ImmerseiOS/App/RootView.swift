import ImmerseCore
import SwiftUI

/// Bottom tabs: 日程 / 规划 / 专注 / 统计, plus the floating "+" capture button and app-wide sheets
struct RootView: View {
    @Environment(ScheduleState.self) private var schedule
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine

    var body: some View {
        @Bindable var schedule = schedule
        @Bindable var focusEngine = focusEngine

        TabView(selection: $schedule.selectedTab) {
            ScheduleView()
                .tabItem { Label("日程", systemImage: "calendar") }
                .tag(AppTab.schedule)
            PlanningView()
                .tabItem { Label("规划", systemImage: "tray.full") }
                .tag(AppTab.planning)
            FocusView()
                .tabItem { Label("专注", systemImage: focusEngine.isActive ? "timer.circle.fill" : "timer") }
                .tag(AppTab.focus)
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.bar") }
                .tag(AppTab.stats)
        }
        .overlay(alignment: .bottomTrailing) {
            if schedule.selectedTab == .schedule || schedule.selectedTab == .planning {
                AddButton { schedule.isCapturePresented = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 64)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            ToastBanner()
                .padding(.bottom, 64)
        }
        .animation(Motion.snappy, value: schedule.selectedTab)
        .sheet(item: $schedule.editor) { target in
            TaskEditorSheet(target: target)
        }
        .sheet(isPresented: $schedule.isCapturePresented) {
            CaptureSheet()
        }
        .fullScreenCover(isPresented: $focusEngine.isImmersivePresented) {
            ImmersiveFocusView()
        }
        .alert("切换专注？", isPresented: Binding(
            get: { focusEngine.pendingSwitch != nil },
            set: { if !$0 { focusEngine.pendingSwitch = nil } }
        )) {
            Button("切换") { focusEngine.confirmSwitch() }
            Button("取消", role: .cancel) { focusEngine.pendingSwitch = nil }
        } message: {
            if let task = focusEngine.pendingSwitch, let current = focusEngine.session {
                Text("正在专注「\(current.taskTitle)」，要结束它并开始「\(task.displayTitle)」吗？")
            }
        }
    }
}

/// The floating "+" that opens the capture sheet (the phone's stand-in for ⌘K)
struct AddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Palette.brand, in: Circle())
                .shadow(color: Palette.brand.opacity(0.35), radius: 10, y: 4)
        }
        .accessibilityLabel("新建")
    }
}

/// Bottom toast with an optional "撤销" button, driven by `TaskStore.toast`
struct ToastBanner: View {
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        if let toast = taskStore.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .font(.subheadline)
                if toast.showsUndo {
                    Button("撤销") {
                        taskStore.undo()
                        taskStore.toast = nil
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(4))
                if taskStore.toast?.id == toast.id {
                    withAnimation(Motion.gentle) { taskStore.toast = nil }
                }
            }
        }
    }
}
