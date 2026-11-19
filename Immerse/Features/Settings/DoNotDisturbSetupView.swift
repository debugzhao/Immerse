import SwiftUI

/// Do Not Disturb setup guide: explains why the Shortcut is needed, how to create it, and checks whether it exists. Shared by first launch and Settings
struct DoNotDisturbSetupView: View {
    enum Context { case onboarding, settings }
    let context: Context
    var onFinish: (() -> Void)?

    @Environment(SettingsStore.self) private var settings
    @Environment(ShortcutsDoNotDisturbService.self) private var dnd

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if context == .onboarding {
                header
            }
            steps
            statusRow
            if context == .onboarding {
                footer
            }
        }
        .task { await dnd.checkSetup() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "moon.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("专注时自动开启勿扰")
                .font(.system(size: 22, weight: .semibold))
            Text("开始专注后，Immerse 会帮你打开系统的「勿扰模式」，时间到了再自动关闭。macOS 不允许 App 直接切换勿扰，所以需要你在「快捷指令」里建两个快捷指令，只需要做一次。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "打开「快捷指令」App，点右上角「＋」新建快捷指令。") {
                Button("打开快捷指令") { dnd.openShortcutsApp() }
            }
            step(2, "搜索并添加操作「设定专注模式」，设为「打开」「勿扰模式」「直到关闭」，把快捷指令命名为：") {
                nameField(text: Bindable(settings).dndOnShortcut)
            }
            step(3, "再建一个，操作设为「关闭」「勿扰模式」，命名为：") {
                nameField(text: Bindable(settings).dndOffShortcut)
            }
            step(4, "建议在「系统设置 → 专注模式 → 勿扰模式 → 允许的 App」里加入 Immerse，这样即使勿扰没关掉，时间到的提醒也能送达。") {
                Button("打开专注模式设置") { dnd.openFocusSettings() }
            }
        }
    }

    private func step<Accessory: View>(_ index: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }

    private func nameField(text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, design: .monospaced))
            .frame(maxWidth: 240)
            .onSubmit { Task { await dnd.checkSetup() } }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch dnd.setupStatus {
            case .unknown, .checking:
                ProgressView().controlSize(.small)
                Text("正在检测快捷指令…")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("两个快捷指令都已就绪")
            case .missing(let names):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("还没找到：\(names.map { "「\($0)」" }.joined(separator: "、"))")
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("检测失败：\(message)").lineLimit(2)
            }
            Spacer()
            Button("重新检测") { Task { await dnd.checkSetup() } }
                .disabled(dnd.setupStatus == .checking)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Button("暂不开启") {
                settings.dndEnabled = false
                onFinish?()
            }
            Spacer()
            Button("完成") { onFinish?() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// First-launch onboarding sheet
struct OnboardingSheet: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        DoNotDisturbSetupView(context: .onboarding) {
            settings.onboardingCompleted = true
        }
        .padding(28)
        .frame(width: 520)
    }
}
