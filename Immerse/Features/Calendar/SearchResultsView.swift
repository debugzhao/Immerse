import SwiftUI

/// 搜索结果浮层：按标题或备注匹配，点击跳转到对应日期并选中
struct SearchResultsView: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let results = taskStore.search(store.searchText)
        VStack(alignment: .leading, spacing: 0) {
            Text(results.isEmpty ? "没有找到「\(store.searchText)」" : "找到 \(results.count) 个日程")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if !results.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { task in
                            Button {
                                store.reveal(task)
                                store.searchText = ""
                            } label: {
                                row(task)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                // 按结果数量算高度，最多 360，避免结果少时下面空一大块
                .frame(height: min(CGFloat(results.count) * 50 + 12, 360))
            }
        }
        .frame(width: 340)
        .glassSurface(.overlay)
    }

    private func row(_ task: TaskSnapshot) -> some View {
        let calendar = store.calendar
        let date = "\(calendar.component(.month, from: task.start))月\(calendar.component(.day, from: task.start))日"
        let time = task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: calendar)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(task.priority.color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(task.status == .done)
                    .lineLimit(1)
                Text(verbatim: "\(date) \(TimeText.weekday(task.start, calendar: calendar)) · \(time)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(HoverHighlight())
    }
}

/// 鼠标悬停时的浅色高亮背景
struct HoverHighlight: View {
    @State private var isHovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            .onHover { isHovering = $0 }
    }
}
