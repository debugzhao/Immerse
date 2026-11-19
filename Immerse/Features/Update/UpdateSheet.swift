import SwiftUI

/// "New version available" sheet: version, release notes, download / skip / later
struct UpdateSheet: View {
    let release: AppRelease
    @Environment(UpdateChecker.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(release.version)")
                        .font(.system(size: 18, weight: .semibold))
                    Text("当前版本 \(updater.currentVersion)。下载后把新的 App 拖进「应用程序」替换即可，日程数据会保留。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                ReleaseNotesView(markdown: release.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 220)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Button("跳过此版本") { updater.skip(release) }
                Link("在网页查看", destination: release.pageURL)
                    .font(.system(size: 12))
                Spacer()
                Button("以后再说") { updater.availableUpdate = nil }
                    .keyboardShortcut(.cancelAction)
                Button("下载新版本") { updater.download(release) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Minimal Markdown for GitHub release notes: headings, bullet lists, inline bold / code / links
private struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let lines = markdown.isEmpty ? ["（这个版本没有写更新说明）"] : markdown.components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            Text(inline(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(.system(size: level <= 2 ? 15 : 13, weight: .semibold))
                .padding(.top, level <= 2 ? 0 : 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(2))))
            }
            .font(.system(size: 13))
        } else {
            Text(inline(line)).font(.system(size: 13))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
