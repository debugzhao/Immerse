import SwiftUI

/// 设置窗口（⌘,）
struct SettingsView: View {
    var body: some View {
        TabView {
            ReminderSettingsTab()
                .tabItem { Label("提醒", systemImage: "bell") }
            DoNotDisturbSettingsTab()
                .tabItem { Label("勿扰", systemImage: "moon") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560)
    }
}

private struct DoNotDisturbSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            Toggle("专注时自动开启勿扰", isOn: $settings.dndEnabled)
                .toggleStyle(.switch)
            if settings.dndEnabled {
                DoNotDisturbSetupView(context: .settings)
                HStack {
                    Button("试一下：开启勿扰") { test(on: true) }
                    Button("关闭勿扰") { test(on: false) }
                    if let testResult {
                        Text(testResult).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
    }

    private func test(on: Bool) {
        testResult = "执行中…"
        Task {
            do {
                if on { try await dnd.activate() } else { try await dnd.deactivate() }
                testResult = on ? "✅ 已开启" : "✅ 已关闭"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
        }
    }
}

/// 提醒：专注进度、每日复盘、系统时钟倒计时
private struct ReminderSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ClockTimerService.self) private var clockTimer
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("专注到这些进度时提醒我（时间到总会提醒）")
                        .font(.system(size: 13))
                    HStack(spacing: 8) {
                        ForEach(SettingsStore.milestoneOptions, id: \.self) { percent in
                            milestoneChip(percent)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("专注进度")
            } footer: {
                footnote("专注时开着勿扰的话，需要把 Immerse 加入勿扰的「允许的 App」，提醒才会弹出。") {
                    Button("打开专注模式设置") { dnd.openFocusSettings() }
                        .buttonStyle(.link)
                }
            }

            Section {
                Toggle("每天提醒我还没完成的任务", isOn: $settings.dailyReviewEnabled)
                if settings.dailyReviewEnabled {
                    DatePicker("提醒时间", selection: reviewTime, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("每日复盘")
            } footer: {
                footnote("到点列出当天没完成的任务；全部完成会发一条祝贺，当天没有任务则不提醒。App 没开着也会按时提醒。") { EmptyView() }
            }

            Section {
                Toggle("开始专注时在「时钟」里开一个倒计时", isOn: $settings.clockTimerEnabled)
                if settings.clockTimerEnabled {
                    clockTimerSetup(name: $settings.clockTimerShortcut)
                }
            } header: {
                Text("系统时钟倒计时")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 700)
        .task { await clockTimer.checkSetup() }
    }

    private func milestoneChip(_ percent: Int) -> some View {
        let isOn = settings.progressMilestones.contains(percent)
        return Button {
            settings.toggleMilestone(percent)
        } label: {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(verbatim: "\(percent)%")
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func clockTimerSetup(name: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("「时钟」没有开放接口，需要在「快捷指令」里建一个快捷指令（只需做一次）：")
            Text("1. 新建快捷指令，添加操作「从输入中获取数字」")
            Text("2. 再添加「时钟 → 开始计时器」，时长选上一步的「数字」，单位选「分钟」")
            HStack {
                Text("3. 命名为")
                TextField("", text: name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

        HStack(spacing: 10) {
            statusLabel
            Spacer()
            Button("打开快捷指令") { dnd.openShortcutsApp() }
            Button("重新检测") { Task { await clockTimer.checkSetup() } }
            Button("试一下（1 分钟）") { test() }
        }
        if let message = testResult ?? clockTimer.lastError.map({ "❌ 上次失败：\($0)" }) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch clockTimer.setupStatus {
        case .unknown, .checking:
            Label("检测中…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .ready:
            Label("快捷指令已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Label("还没找到「\(settings.clockTimerShortcut)」", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func footnote<Accessory: View>(_ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// 提醒时间：设置里存的是分钟数，DatePicker 需要 Date
    private var reviewTime: Binding<Date> {
        Binding(
            get: { Calendar.app.startOfDay(for: .now).addingTimeInterval(TimeInterval(settings.dailyReviewMinutes * 60)) },
            set: { date in
                let c = Calendar.app.dateComponents([.hour, .minute], from: date)
                settings.dailyReviewMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func test() {
        testResult = "执行中…"
        Task {
            testResult = await clockTimer.start(minutes: 1) ? "✅ 已发送，看看「时钟」里有没有 1 分钟的计时器" : nil
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Immerse").font(.system(size: 20, weight: .semibold))
            Text("用最轻的方式安排日程，用最强的方式进入专注。")
                .foregroundStyle(.secondary)
            Text(verbatim: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
