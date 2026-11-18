import SwiftUI

/// 底部轻提示：显示 4 秒后自动消失，可带「撤销」按钮
struct ToastOverlay: View {
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        ZStack {
            if let toast = taskStore.toast {
                HStack(spacing: 14) {
                    Text(toast.message)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if toast.showsUndo {
                        Button("撤销") {
                            taskStore.toast = nil
                            taskStore.undo()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassSurface(.overlay, cornerRadius: 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if taskStore.toast?.id == toast.id {
                        taskStore.toast = nil
                    }
                }
            }
        }
        .animation(Motion.gentle, value: taskStore.toast)
        .padding(.bottom, 24)
    }
}
