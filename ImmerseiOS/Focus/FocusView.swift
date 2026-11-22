import ImmerseAgent
import ImmerseCore
import SwiftUI
import UIKit

/// The 专注 tab: the running session with its controls, or today's unfinished tasks ready to start
struct FocusView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(TaskStore.self) private var taskStore
    @Environment(ScheduleState.self) private var schedule

    var body: some View {
        NavigationStack {
            Group {
                if let session = focusEngine.session {
                    ActiveFocusPanel(session: session)
                } else {
                    TodayStartList()
                }
            }
            .navigationTitle("专注")
        }
    }
}

/// Countdown ring + pause / +15 / finish / give up
struct ActiveFocusPanel: View {
    let session: FocusSessionState
    @Environment(FocusEngine.self) private var focusEngine
    @State private var confirmsAbandon = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(session.taskTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ZStack {
                ProgressRing(fraction: focusEngine.progress, color: Palette.brand, lineWidth: 14)
                VStack(spacing: 6) {
                    Text(focusEngine.phase == .timeUp ? "时间到" : focusEngine.remainingText)
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if focusEngine.isPaused {
                        Text("已暂停").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 260, height: 260)
            .animation(.linear(duration: 1), value: focusEngine.remainingText)

            HStack(spacing: 18) {
                controlButton(focusEngine.isPaused ? "继续" : "暂停", icon: focusEngine.isPaused ? "play.fill" : "pause.fill") {
                    focusEngine.togglePause()
                }
                .disabled(focusEngine.phase == .timeUp)
                controlButton("+15 分钟", icon: "plus") { focusEngine.extend() }
                controlButton("完成", icon: "checkmark") {
                    if focusEngine.phase == .timeUp { focusEngine.complete() } else { focusEngine.finishEarly() }
                    Haptics.success()
                }
            }

            HStack(spacing: 24) {
                Button {
                    focusEngine.isImmersivePresented = true
                } label: {
                    Label("沉浸模式", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                if focusEngine.phase == .timeUp {
                    Button("关闭") { focusEngine.close() }
                } else {
                    Button("放弃本次", role: .destructive) { confirmsAbandon = true }
                }
            }
            .font(.callout)
            Spacer()
        }
        .confirmationDialog("放弃这次专注？任务会恢复为未开始。", isPresented: $confirmsAbandon, titleVisibility: .visible) {
            Button("放弃", role: .destructive) { focusEngine.abandon() }
        }
    }

    private func controlButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(Palette.brand.opacity(0.14), in: Circle())
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.brand)
    }
}

/// Today's unfinished events, each with a start button
struct TodayStartList: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(TaskStore.self) private var taskStore
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary

    var body: some View {
        let calendar = schedule.calendar
        let today = calendar.startOfDay(for: .now)
        let tasks = taskStore.tasks(in: DateInterval(start: today, end: calendar.date(byAdding: .day, value: 1, to: today) ?? today))
            .filter { $0.status != .done }
            .sorted { a, b in a.priority != b.priority ? a.priority < b.priority : a.start < b.start }

        if tasks.isEmpty {
            ContentUnavailableView("今天没有待专注的任务", systemImage: "sparkles",
                                   description: Text("在日程里新建一个，或者从收集箱安排一条想法"))
        } else {
            List(tasks) { task in
                HStack {
                    Circle().fill(task.priority.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.displayTitle)
                        Text(task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: calendar))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        startFocusWithBriefing(task, secretary: secretary, schedule: schedule, focusEngine: focusEngine)
                    } label: {
                        Label(DurationText.minutes(task.focusMinutes * 60), systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// Full-screen countdown with nothing else on screen; keeps the phone awake while it is shown
struct ImmersiveFocusView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x6A63F0), Color(hex: 0x231C66)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Text(focusEngine.session?.taskTitle ?? "")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                ZStack {
                    ProgressRing(fraction: focusEngine.progress, color: .white, lineWidth: 10)
                    Text(focusEngine.phase == .timeUp ? "时间到" : focusEngine.remainingText)
                        .font(.system(size: 64, weight: .ultraLight, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 280, height: 280)
                Button {
                    focusEngine.togglePause()
                } label: {
                    Image(systemName: focusEngine.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .disabled(focusEngine.phase == .timeUp)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(12)
            }
            .accessibilityLabel("退出沉浸模式")
            .padding()
        }
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: focusEngine.isActive) { _, isActive in
            if !isActive { dismiss() }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}
