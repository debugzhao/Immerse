import SwiftUI

/// Setup steps for the Clock countdown shortcut, plus live status and a 1-minute test. Shared by Settings and onboarding
struct ClockTimerSetupView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ClockTimerService.self) private var clockTimer
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("「时钟」没有开放接口，需要在「快捷指令」里建一个快捷指令（只需做一次）：")
                Text("1. 新建快捷指令，添加操作「从输入中获取数字」")
                Text("2. 再添加「时钟 → 开始计时器」，时长选上一步的「数字」，单位选「分钟」")
                HStack {
                    Text("3. 命名为")
                    TextField("", text: Bindable(settings).clockTimerShortcut)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 200)
                        .onSubmit { Task { await clockTimer.checkSetup() } }
                }
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                statusLabel
                Spacer()
                Button("打开快捷指令") { dnd.openShortcutsApp() }
                Button("重新检测") { Task { await clockTimer.checkSetup() } }
                    .disabled(clockTimer.setupStatus == .checking)
                Button("试一下（1 分钟）") { test() }
            }
            .font(.system(size: 12))

            if let message = testResult ?? clockTimer.lastError.map({ "❌ 上次失败：\($0)" }) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await clockTimer.checkSetup() }
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
        case .blocked:
            Label("这台 Mac 无法运行快捷指令", systemImage: "nosign").foregroundStyle(.red)
        }
    }

    private func test() {
        testResult = "执行中…"
        Task {
            testResult = await clockTimer.start(minutes: 1) ? "✅ 已发送，看看「时钟」里有没有 1 分钟的计时器" : nil
        }
    }
}
