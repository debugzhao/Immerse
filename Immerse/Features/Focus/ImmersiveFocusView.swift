import AppKit
import ImmerseCore
import SwiftUI

/// Fullscreen immersive view: shows only the task name, large countdown, progress, and notes, over vibrancy + a soft priority-colored glow.
/// Entering switches the window to fullscreen; Esc or "退出沉浸" (exit immersive) returns to the calendar.
struct ImmersiveFocusView: View {
    @Environment(FocusEngine.self) private var engine
    @Environment(TaskStore.self) private var taskStore
    @FocusState private var isFocused: Bool

    var body: some View {
        let task = taskStore.task(id: engine.session?.taskID)
        let tint = task?.priority.color ?? .accentColor

        ZStack {
            // Thick vibrancy as the base: the calendar is heavily blurred, leaving just a hint of color without distracting
            Rectangle().fill(.ultraThickMaterial)
            // Soft priority-colored glow that slowly spreads as focus progresses
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

/// Immersive view container: covers the whole main window and drives window fullscreen
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
        // Don't enter fullscreen in screenshot mode, to avoid affecting screenshots
        guard !PersistenceController.isSnapshotMode,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && !($0 is NSPanel) }) else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on != isFull { window.toggleFullScreen(nil) }
    }
}
