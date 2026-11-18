import AppKit
import SwiftUI

/// 全屏沉浸视图：只显示任务名、大号倒计时、进度和备注，背景是毛玻璃 + 优先级色的柔光。
/// 进入时窗口切到全屏，Esc 或「退出沉浸」回到日历。
struct ImmersiveFocusView: View {
    @Environment(FocusEngine.self) private var engine
    @Environment(TaskStore.self) private var taskStore
    @FocusState private var isFocused: Bool

    var body: some View {
        let task = taskStore.task(id: engine.session?.taskID)
        let tint = task?.priority.color ?? .accentColor

        ZStack {
            // 厚毛玻璃打底：日历被充分模糊，只留一点色彩氛围，不干扰注意力
            Rectangle().fill(.ultraThickMaterial)
            // 优先级色的柔光，随专注进度缓慢扩散
            RadialGradient(colors: [tint.opacity(0.35), tint.opacity(0.05), .clear],
                           center: .center, startRadius: 40,
                           endRadius: 300 + 400 * engine.progress)
                .animation(.easeInOut(duration: 1), value: engine.progress)

            VStack(spacing: 36) {
                Spacer()
                FocusControlPanel(style: .immersive)
                if let notes = task?.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 560, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 600, maxHeight: 160)
                    .padding(18)
                    .glassSurface(.immersive, cornerRadius: 14)
                }
                Spacer()
                Button {
                    engine.isImmersivePresented = false
                } label: {
                    Label("退出沉浸（Esc）", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            engine.isImmersivePresented = false
            return .handled
        }
        .onKeyPress(.space) {
            engine.togglePause()
            return .handled
        }
    }
}

/// 沉浸视图的容器：盖住整个主窗口，并联动窗口全屏
struct ImmersiveOverlay: View {
    @Environment(FocusEngine.self) private var engine

    var body: some View {
        ZStack {
            if engine.isImmersivePresented && engine.isActive {
                ImmersiveFocusView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(Motion.gentle, value: engine.isImmersivePresented)
        .onChange(of: engine.isImmersivePresented) { _, presented in
            setFullScreen(presented)
        }
        .onChange(of: engine.isActive) { _, active in
            if !active { engine.isImmersivePresented = false }
        }
    }

    private func setFullScreen(_ on: Bool) {
        // 截图模式下不切全屏，避免影响截图
        guard !PersistenceController.isSnapshotMode,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && !($0 is NSPanel) }) else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on != isFull { window.toggleFullScreen(nil) }
    }
}
