import ImmerseCore
import SwiftUI

/// Settings window (⌘,)
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

/// Reminders: focus progress, daily review, system clock countdown
private struct ReminderSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("日程开始时自动开始专注", isOn: $settings.autoFocusEnabled)
            } header: {
                Text("自动专注")
            } footer: {
                footnote("有具体时间的日程到点后自动开始专注，任务转为进行中，并发系统通知；开始前 1 分钟会先提醒，可以推迟 5 分钟或跳过。已有专注在进行时不会打断，会发通知问你要不要切换。App 没开着或电脑在睡眠时错过的，下次打开或唤醒时如果日程还没结束，会按剩余时间补上。") { EmptyView() }
            }

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
                footnote("专注时开着勿扰的话，需要把「沉浸日程」加入勿扰的「允许的 App」，提醒才会弹出。") {
                    Button("打开专注模式设置") { dnd.openFocusSettings() }
                        .buttonStyle(.link)
                }
            }

            Section {
                Toggle("每天第一次打开时弹出今日规划", isOn: $settings.dailyPlanEnabled)
            } header: {
                Text("今日规划")
            } footer: {
                footnote("列出收集箱里的想法和进度落后的目标，点「安排」放进今天的空闲时段。也可以从菜单「显示 → 今日规划…」随时打开。") { EmptyView() }
            }

            Section {
                Toggle("每天提醒我还没完成的任务", isOn: $settings.dailyReviewEnabled)
                if settings.dailyReviewEnabled {
                    DatePicker("提醒时间", selection: reviewTime, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("每日复盘")
            } footer: {
                footnote("到点列出当天没完成的任务、进度落后的目标和收集箱里的想法；全部完成会发一条祝贺。当天没有任务时，只在有目标落后或想法搁置超过 7 天时提醒。App 没开着也会按时提醒。") { EmptyView() }
            }

            Section {
                Toggle("开始专注时在「时钟」里开一个倒计时", isOn: $settings.clockTimerEnabled)
                if settings.clockTimerEnabled {
                    ClockTimerSetupView()
                }
            } header: {
                Text("系统时钟倒计时")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 700)
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

    private func footnote<Accessory: View>(_ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// Reminder time: stored in settings as minutes, but DatePicker needs a Date
    private var reviewTime: Binding<Date> {
        Binding(
            get: { Calendar.app.startOfDay(for: .now).addingTimeInterval(TimeInterval(settings.dailyReviewMinutes * 60)) },
            set: { date in
                let c = Calendar.app.dateComponents([.hour, .minute], from: date)
                settings.dailyReviewMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 0)
            }
        )
    }
}

private struct AboutTab: View {
    @Environment(UpdateChecker.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        VStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 64, height: 64)
            Text("沉浸日程").font(.system(size: 20, weight: .semibold))
            Text("用最轻的方式安排日程，用最强的方式进入专注。")
                .foregroundStyle(.secondary)
            Text(verbatim: "版本 \(updater.currentVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 8)

            HStack(spacing: 12) {
                Toggle("自动检查更新", isOn: $updater.autoCheckEnabled)
                    .toggleStyle(.checkbox)
                Button {
                    Task { await updater.checkManually() }
                } label: {
                    if updater.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("检查更新")
                    }
                }
                .disabled(updater.isChecking)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
