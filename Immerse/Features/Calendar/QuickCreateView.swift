import SwiftUI

/// 框选 / 双击创建后弹出的快速创建浮层：输入标题回车即可创建
struct QuickCreateView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    @State private var title = ""
    @State private var priority: Priority = .normal
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("日程标题", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($isTitleFocused)
                .onSubmit(create)

            if let draft = store.draft {
                Label(timeText(draft), systemImage: draft.isAllDay ? "sun.max" : "clock")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Picker("优先级", selection: $priority) {
                ForEach(Priority.allCases) { priority in
                    Text(priority.title).tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { isTitleFocused = true }
    }

    private func timeText(_ draft: DraftEvent) -> String {
        let calendar = store.calendar
        let day = "\(calendar.component(.month, from: draft.start))月\(calendar.component(.day, from: draft.start))日 \(TimeText.weekday(draft.start, calendar: calendar))"
        return draft.isAllDay ? "\(day) · 全天" : "\(day) · \(TimeText.range(draft.start, draft.end, calendar: calendar))"
    }

    private func create() {
        guard let draft = store.draft else { return }
        let task = taskStore.create(TaskSnapshot(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: draft.start,
            end: draft.isAllDay ? nil : draft.end,
            isAllDay: draft.isAllDay,
            priority: priority
        ))
        store.draft = nil
        store.select(task.id)
    }
}
