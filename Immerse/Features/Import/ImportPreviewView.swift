import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 待确认的导入
struct ImportPreview: Identifiable {
    let id = UUID()
    let fileName: String
    /// 去重后要导入的
    let tasks: [TaskSnapshot]
    /// 和已有日程重复、被跳过的数量
    let duplicateCount: Int
    let skipped: [(row: Int, reason: String)]
}

@MainActor
enum NotionImport {
    /// 选文件 → 解析 → 去重，返回预览；用户取消返回 nil
    static func pickAndParse(existing: [TaskSnapshot]) -> Result<ImportPreview, Error>? {
        let panel = NSOpenPanel()
        panel.title = "导入 Notion 导出的 CSV"
        panel.message = "在 Notion 数据库右上角 ⋯ → 导出 → Markdown & CSV，解压后选择其中的 .csv 文件"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Result {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try NotionCSVImporter.parse(text)
            let unique = NotionCSVImporter.removingDuplicates(parsed.tasks, existing: existing)
            return ImportPreview(fileName: url.lastPathComponent, tasks: unique,
                                 duplicateCount: parsed.tasks.count - unique.count, skipped: parsed.skipped)
        }
    }
}

/// 导入前的确认面板
struct ImportPreviewView: View {
    let preview: ImportPreview
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("导入「\(preview.fileName)」", systemImage: "square.and.arrow.down")
                .font(.system(size: 17, weight: .semibold))

            HStack(spacing: 12) {
                stat("\(preview.tasks.count)", "将导入", .accentColor)
                stat("\(preview.duplicateCount)", "已存在，跳过", .secondary)
                stat("\(preview.skipped.count)", "无法识别", preview.skipped.isEmpty ? .secondary : .orange)
            }

            if !preview.tasks.isEmpty {
                List(preview.tasks.prefix(50)) { task in
                    HStack {
                        Circle().fill(task.priority.color).frame(width: 7, height: 7)
                        Text(task.displayTitle).lineLimit(1)
                        Spacer()
                        Text(dateText(task)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
                .frame(height: 200)
            }

            if !preview.skipped.isEmpty {
                DisclosureGroup("查看无法识别的行") {
                    ForEach(preview.skipped, id: \.row) { item in
                        Text(verbatim: "第 \(item.row) 行：\(item.reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 12))
            }

            HStack {
                Text("导入后可以用 ⌘Z 一次性撤销")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(preview.tasks.count) 个日程") {
                    taskStore.importTasks(preview.tasks)
                    taskStore.toast = Toast(message: "已导入 \(preview.tasks.count) 个日程", showsUndo: true)
                    if let first = preview.tasks.min(by: { $0.start < $1.start }) {
                        store.anchorDate = first.start
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.tasks.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func dateText(_ task: TaskSnapshot) -> String {
        let calendar = store.calendar
        let day = "\(calendar.component(.year, from: task.start))/\(calendar.component(.month, from: task.start))/\(calendar.component(.day, from: task.start))"
        return task.isAllDay ? day : "\(day) \(TimeText.hhmm(task.start, calendar: calendar))"
    }
}
