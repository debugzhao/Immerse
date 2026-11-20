import ImmerseAgent
import ImmerseCore
import SwiftUI

/// 设置 → 秘书 AI: on/off, the API key (with the data notice), this month's usage, the system calendar
struct AISettingsSection: View {
    @Environment(AISettings.self) private var ai
    @Environment(EventKitCalendarSource.self) private var systemCalendar

    var body: some View {
        @Bindable var ai = ai
        Section {
            Toggle("AI 秘书", isOn: $ai.isEnabled)
            if ai.isEnabled {
                if ai.hasKey {
                    LabeledContent("API Key", value: ai.maskedKey ?? "已保存")
                    if ai.isKeyInvalid {
                        Label("这个 Key 无效了，请重新填写", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    NavigationLink("更换 API Key") { APIKeyView() }
                    Button("删除 API Key", role: .destructive) { ai.removeKey() }
                } else {
                    NavigationLink { APIKeyView() } label: {
                        Label("填写 API Key 开启智能功能", systemImage: "key.fill")
                    }
                }
                if ai.monthUsage.inputTokens + ai.monthUsage.outputTokens > 0 {
                    LabeledContent("本月用量", value: usageText)
                }
            }
        } header: {
            Text("秘书 AI")
        } footer: {
            Text(ai.isAvailable
                 ? "一句话整理、拆分大任务、自由提问会调用 Claude。排期、重排、预警等计算都在本机完成。"
                 : "没有 API Key 时，排期、重排、预警、复盘都按规则在本机完成；填写 Key 后可以用一句话整理、拆分大任务和自由提问。")
        }

        Section {
            NavigationLink { MemoryListView() } label: { Label("秘书记忆", systemImage: "brain") }
        } footer: {
            Text("秘书记住的固定安排和偏好，可以随时查看、修改或删除。")
        }

        Section {
            switch systemCalendar.status {
            case .fullAccess:
                Label("已读取系统日历，排期会避开会议", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("读取系统日历的会议") { Task { await systemCalendar.requestAccess() } }
            default:
                Button("系统日历未授权，去设置打开") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("系统日历")
        } footer: {
            Text("只读取，不会修改你的系统日历。")
        }
    }

    private var usageText: String {
        let input = Double(ai.monthUsage.inputTokens + ai.monthUsage.cacheReadInputTokens + ai.monthUsage.cacheCreationInputTokens) / 1000
        let output = Double(ai.monthUsage.outputTokens) / 1000
        return String(format: "输入 %.1fk · 输出 %.1fk tokens", input, output)
    }
}

/// Enter and verify the key. Saving is also where the user agrees to the data notice (design §3.5, App Review 5.1.2)
struct APIKeyView: View {
    @Environment(AISettings.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var agreed = false
    @State private var state: VerifyState = .idle

    enum VerifyState: Equatable {
        case idle, checking
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Link("在 Anthropic 控制台创建 API Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }

            Section("开启前请了解") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("使用 AI 功能时，沉浸日程会把以下内容发送给 Anthropic（Claude）处理：")
                    Text("· 你输入或说出的那句话\n· 相关任务的标题、时间、分类、优先级\n· 统计数字（例如负载、完成率）")
                    Text("备注正文默认不发送；只有你主动「拆成小步骤」时，才会附上那条任务的备注。API Key 只保存在这台设备的钥匙串里，费用由你的 Anthropic 账户承担。")
                }
                .font(.footnote)
                Toggle("我已了解并同意", isOn: $agreed)
            }

            Section {
                Button {
                    Task { await verifyAndSave() }
                } label: {
                    HStack {
                        Text("验证并保存")
                        if state == .checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).count < 10 || !agreed || state == .checking)
                if case .failed(let message) = state {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func verifyAndSave() async {
        state = .checking
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await AnthropicHTTPProvider(apiKey: candidate).validateKey()
            ai.saveKey(candidate, consent: true)
            Haptics.success()
            dismiss()
        } catch let error as LLMError where error == .invalidKey {
            state = .failed("这个 Key 无效，请检查后重试")
        } catch {
            // Offline or the service is busy: keep the key, it is checked again on first use
            ai.saveKey(candidate, consent: true)
            state = .failed("暂时无法验证（\(error.localizedDescription)），已先保存")
        }
    }
}
