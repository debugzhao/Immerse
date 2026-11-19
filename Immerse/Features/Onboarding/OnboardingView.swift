import SwiftUI

/// First-launch guide: welcome → notification permission → Do Not Disturb shortcuts → Clock countdown shortcut.
/// Every step can be skipped; everything here can be redone later in Settings or via Help → 重新查看引导.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, notifications, doNotDisturb, clockTimer
    }

    let onFinish: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationService.self) private var notifications
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd
    @Environment(ClockTimerService.self) private var clockTimer
    @State private var step: Step

    init(startAt step: Step = .welcome, onFinish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                content
                    .padding(.horizontal, 36)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            Divider()
            bottomBar
        }
        .frame(width: 600, height: 560)
        .animation(Motion.snappy, value: step)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: item == step ? 22 : 8, height: 8)
                }
            }
            Spacer()
            if step != .clockTimer {
                Button("稍后设置", action: onFinish)
                    .buttonStyle(.link)
                    .help("跳过引导，之后可以在设置里完成")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var bottomBar: some View {
        HStack {
            if step != .welcome {
                Button("上一步") { move(-1) }
            }
            Spacer()
            if let skip = skipTitle {
                Button(skip) { skipCurrent() }
            }
            Button(step == .clockTimer ? "开始使用" : step == .welcome ? "开始设置" : "下一步") {
                step == .clockTimer ? onFinish() : move(1)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Steps 3/4 let the user turn the feature off instead of setting it up
    private var skipTitle: String? {
        switch step {
        case .doNotDisturb where settings.dndEnabled: "不使用自动勿扰"
        case .clockTimer where settings.clockTimerEnabled: "不使用时钟倒计时"
        default: nil
        }
    }

    private func skipCurrent() {
        switch step {
        case .doNotDisturb: settings.dndEnabled = false
        case .clockTimer: settings.clockTimerEnabled = false
        default: break
        }
        step == .clockTimer ? onFinish() : move(1)
    }

    private func move(_ offset: Int) {
        if let next = Step(rawValue: step.rawValue + offset) { step = next }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .notifications: notificationStep
        case .doNotDisturb: doNotDisturbStep
        case .clockTimer: clockTimerStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("欢迎使用「沉浸日程」")
                        .font(.system(size: 26, weight: .bold))
                    Text("用最轻的方式安排日程，用最强的方式进入专注。")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("calendar", .blue, "在日历上排日程", "拖拽框选、双击空白或 ⌘N 新建，⌘K 用一句话创建")
                feature("play.circle.fill", .purple, "一键开始专注", "按计划时长倒计时，菜单栏显示剩余时间")
                feature("moon.fill", .indigo, "自动开关勿扰", "专注时打开系统勿扰，时间到先关勿扰再提醒")
                feature("bell.badge.fill", .orange, "按时提醒", "专注过半、80%、时间到都会提醒，每晚 21:00 复盘没完成的任务")
            }
            Text("接下来用大约 2 分钟完成三项设置，每一步都可以跳过。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var notificationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("bell.badge.fill", .orange, "允许发送通知",
                       "进度提醒、时间到提醒和每晚的复盘都是系统通知。不允许的话，这些提醒都收不到。")
            VStack(alignment: .leading, spacing: 10) {
                bullet("专注进度：默认 50%、80% 各提醒一次（可在设置里改）")
                bullet("时间到：提醒你标记完成或再延长 15 分钟")
                bullet("每日复盘：21:00 列出当天还没完成的任务")
            }
            statusBox {
                switch notifications.permission {
                case .unknown:
                    ProgressView().controlSize(.small)
                    Text("正在检查通知权限…")
                    Spacer()
                case .notDetermined:
                    Image(systemName: "bell").foregroundStyle(.secondary)
                    Text("还没有授权")
                    Spacer()
                    Button("允许通知") { Task { await notifications.requestPermission() } }
                        .buttonStyle(.borderedProminent)
                case .authorized:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已允许通知")
                    Spacer()
                case .denied:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("通知被关闭了，需要到系统设置里打开")
                    Spacer()
                    Button("打开系统设置") { notifications.openSystemSettings() }
                }
            }
        }
        .task { await notifications.refreshPermission() }
        // Coming back from System Settings: refresh the status
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refreshPermission() }
        }
    }

    private var doNotDisturbStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("moon.fill", .indigo, "专注时自动开启勿扰",
                       "macOS 不允许 App 直接切换勿扰，需要在「快捷指令」里建两个快捷指令。建好后，开始专注时自动打开勿扰，时间到自动关闭。")
            if case .blocked = dnd.setupStatus {
                blockedNotice
            } else if settings.dndEnabled {
                DoNotDisturbSetupView(context: .settings)
            } else {
                disabledNotice("已关闭自动勿扰") { settings.dndEnabled = true }
            }
        }
        .onChange(of: dnd.setupStatus) { _, status in
            if case .blocked = status { settings.dndEnabled = false }
        }
    }

    private var clockTimerStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("timer", .teal, "同时在「时钟」里倒计时",
                       "开始专注时，自动在系统「时钟」App 里开一个同样时长的倒计时，到点由「时钟」响铃。可选，不设置也不影响专注。")
            if case .blocked = clockTimer.setupStatus {
                blockedNotice
            } else if settings.clockTimerEnabled {
                ClockTimerSetupView()
            } else {
                disabledNotice("已关闭时钟倒计时") { settings.clockTimerEnabled = true }
            }
        }
        .onChange(of: clockTimer.setupStatus) { _, status in
            if case .blocked = status { settings.clockTimerEnabled = false }
        }
    }

    // MARK: - Building blocks

    private func stepHeader(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .font(.system(size: 13))
            .labelStyle(BulletLabelStyle())
    }

    private func statusBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(.system(size: 13))
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Shortcuts can't run on this Mac at all: say so and keep the feature off
    private var blockedNotice: some View {
        statusBox {
            Image(systemName: "nosign").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("这台 Mac 无法运行快捷指令").font(.system(size: 13, weight: .semibold))
                Text("可能被公司的设备管理策略禁用了。已自动关闭这个功能，不影响计时和提醒。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func disabledNotice(_ text: String, enable: @escaping () -> Void) -> some View {
        statusBox {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
            Text(text)
            Spacer()
            Button("重新开启", action: enable)
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
            configuration.title
        }
    }
}
