import SwiftUI

/// 设置窗口（⌘,）
struct SettingsView: View {
    var body: some View {
        TabView {
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
