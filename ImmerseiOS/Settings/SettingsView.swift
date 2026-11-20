import ImmerseCore
import SwiftUI
import UIKit

/// Notification, review and focus settings (the iPhone subset of the macOS settings window)
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                AISettingsSection()

                Section {
                    switch notifications.permission {
                    case .authorized:
                        Label("通知已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("通知被关闭了，去系统设置打开") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    default:
                        Button("开启通知") { Task { await notifications.requestPermission() } }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("专注结束、进度提醒和每晚复盘都通过通知送达，App 不在前台时也能准时提醒")
                }

                Section("专注") {
                    Toggle("日程到点自动开始专注", isOn: $settings.autoFocusEnabled)
                    NavigationLink {
                        MilestonePicker()
                    } label: {
                        LabeledContent("进度提醒", value: settings.progressMilestones.sorted().map { "\($0)%" }.joined(separator: " / "))
                    }
                }

                Section("每晚复盘") {
                    Toggle("提醒当天没完成的任务", isOn: $settings.dailyReviewEnabled)
                    if settings.dailyReviewEnabled {
                        DatePicker("提醒时间", selection: reviewTime, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await notifications.refreshPermission() }
        }
    }

    private var reviewTime: Binding<Date> {
        Binding(
            get: { Calendar.app.startOfDay(for: .now).addingTimeInterval(TimeInterval(settings.dailyReviewMinutes * 60)) },
            set: {
                let parts = Calendar.app.dateComponents([.hour, .minute], from: $0)
                settings.dailyReviewMinutes = (parts.hour ?? 21) * 60 + (parts.minute ?? 0)
            })
    }
}

private struct MilestonePicker: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        List(SettingsStore.milestoneOptions, id: \.self) { percent in
            Button {
                settings.toggleMilestone(percent)
            } label: {
                HStack {
                    Text("专注到 \(percent)% 时提醒")
                    Spacer()
                    if settings.progressMilestones.contains(percent) {
                        Image(systemName: "checkmark").foregroundStyle(Palette.brand)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle("进度提醒")
    }
}
