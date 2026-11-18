import SwiftUI

/// 菜单栏图标旁的文字：专注中显示剩余时间，否则只显示图标
struct MenuBarLabel: View {
    @Environment(FocusEngine.self) private var engine

    var body: some View {
        if let session = engine.session {
            let symbol = switch engine.phase {
            case .paused: "pause.circle"
            case .timeUp: "checkmark.circle"
            default: "record.circle"
            }
            // MenuBarExtra 的标签只认 Text / Image，用 Text 插值把图标和时间拼在一起
            Text("\(Image(systemName: symbol)) \(engine.phase == .timeUp ? "时间到" : DurationText.countdown(session.remaining(at: engine.now)))")
                .monospacedDigit()
        } else {
            Image(systemName: "calendar.badge.clock")
        }
    }
}

/// 点开菜单栏图标后的面板
struct MenuBarFocusView: View {
    @Environment(FocusEngine.self) private var engine
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.isActive {
                FocusControlPanel(style: .compact)
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    engine.isImmersivePresented = true
                } label: {
                    Label("进入沉浸模式", systemImage: "sparkles.tv")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            } else {
                todayList
            }
            Divider()
            HStack {
                Button("打开 Immerse") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 320)
    }

    private var todayList: some View {
        let tasks = todayTasks
        return VStack(alignment: .leading, spacing: 8) {
            Text("今天的任务")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("今天没有待办 🌿")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(tasks) { task in
                HStack(spacing: 8) {
                    Circle().fill(task.priority.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.displayTitle).font(.system(size: 13)).lineLimit(1)
                        Text(verbatim: "\(task.isAllDay ? "全天" : TimeText.hhmm(task.start)) · \(task.focusMinutes) 分钟")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        engine.requestStart(task)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("开始专注")
                }
            }
        }
    }

    private var todayTasks: [TaskSnapshot] {
        guard let today = calendarStore.calendar.dateInterval(of: .day, for: .now) else { return [] }
        return taskStore.tasks(in: today)
            .filter { $0.status != .done }
            .sorted { ($0.priority, $0.start) < ($1.priority, $1.start) }
    }
}

/// 专注控制面板：任务名 + 倒计时 + 进度 + 操作按钮。菜单栏和沉浸视图共用
struct FocusControlPanel: View {
    enum Style { case compact, immersive }
    let style: Style

    @Environment(FocusEngine.self) private var engine

    var body: some View {
        if let session = engine.session {
            VStack(alignment: style == .compact ? .leading : .center, spacing: style == .compact ? 10 : 28) {
                Text(session.taskTitle)
                    .font(style == .compact ? .system(size: 15, weight: .semibold) : .system(size: 28, weight: .semibold))
                    .multilineTextAlignment(style == .compact ? .leading : .center)
                    .lineLimit(3)

                Text(engine.phase == .timeUp ? "时间到" : DurationText.countdown(session.remaining(at: engine.now)))
                    .font(.system(size: style == .compact ? 44 : 120, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.snappy, value: engine.now)
                    .foregroundStyle(engine.isPaused ? .secondary : .primary)

                ProgressView(value: session.progress(at: engine.now))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: style == .compact ? .infinity : 420)

                statusLine(session)

                controls
            }
        }
    }

    private func statusLine(_ session: FocusSessionState) -> some View {
        let text: String = switch engine.phase {
        case .paused: "已暂停"
        case .timeUp: "已专注 \(DurationText.minutes(session.plannedSeconds))"
        default: "计划 \(DurationText.minutes(session.plannedSeconds))"
        }
        return HStack(spacing: 6) {
            Text(text)
            if let warning = engine.dndWarning {
                Text("· \(warning)").foregroundStyle(.orange).lineLimit(1)
            }
        }
        .font(.system(size: style == .compact ? 11 : 14))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var controls: some View {
        let size: ControlSize = style == .compact ? .regular : .large
        if engine.phase == .timeUp {
            HStack(spacing: 10) {
                Button("标记完成") { engine.complete() }
                    .buttonStyle(.borderedProminent)
                Button("再延长 15 分钟") { engine.extend() }
            }
            .controlSize(size)
        } else {
            HStack(spacing: 10) {
                Button {
                    engine.togglePause()
                } label: {
                    Label(engine.isPaused ? "继续" : "暂停", systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("+15 分钟") { engine.extend() }
                Button("提前完成") { engine.finishEarly() }
                Button("放弃", role: .destructive) { engine.abandon() }
            }
            .controlSize(size)
        }
    }
}

/// 时间到时浮在主窗口上的面板
struct FocusTimeUpOverlay: View {
    @Environment(FocusEngine.self) private var engine

    var body: some View {
        ZStack {
            if engine.phase == .timeUp, !engine.isImmersivePresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                FocusControlPanel(style: .compact)
                    .padding(24)
                    .frame(width: 380)
                    .glassSurface(.overlay, cornerRadius: 18)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(Motion.gentle, value: engine.phase)
    }
}
