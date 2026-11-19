import SwiftUI

/// Sidebar panels. Only one is shown at a time so the sidebar stays short and calm
enum SidebarTab: String, CaseIterable, Identifiable {
    case today, inbox, goals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .inbox: "收集箱"
        case .goals: "目标"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max.fill"
        case .inbox: "tray.fill"
        case .goals: "target"
        }
    }

    /// Theme color of the tab icon: warm for today, blue for the inbox, red to match the goal ribbon's target
    var color: Color {
        switch self {
        case .today: .orange
        case .inbox: .blue
        case .goals: .red
        }
    }
}

/// Left sidebar: mini month on top, one switchable panel (Today / Inbox / Goals), then the focus summary card. The system sidebar vibrancy comes from NavigationSplitView.
struct SidebarView: View {
    /// Remembered across launches so the sidebar reopens where the user left it
    @AppStorage("sidebar.tab") private var tab: SidebarTab = .today

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MiniMonthView()
                SidebarTabPicker(selection: $tab)
                panel
                    .id(tab)
                    .transition(.opacity)
                FocusSummaryView()
                    .padding(.top, 10)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .animation(Motion.snappy, value: tab)
        .onAppear(perform: applyDebugTab)
    }

    @ViewBuilder
    private var panel: some View {
        switch tab {
        case .today: TodayTaskList()
        case .inbox: InboxSection()
        case .goals: GoalsSection()
        }
    }

    /// IMMERSE_SIDEBAR=today|inbox|goals picks the panel for debug snapshots
    private func applyDebugTab() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["IMMERSE_SIDEBAR"], let debugTab = SidebarTab(rawValue: raw) {
            tab = debugTab
        }
        #endif
    }
}

/// Segmented switch with a count on each segment, so the hidden panels still say how much is in them
private struct SidebarTabPicker: View {
    @Binding var selection: SidebarTab
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let isOn = selection == tab
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tab.color.opacity(isOn ? 1 : 0.6))
                        Text(tab.title)
                            .foregroundStyle(isOn ? .primary : .secondary)
                        if let count = count(for: tab), count > 0 {
                            Text(verbatim: "\(count)")
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.background.opacity(0.9))
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Today: unfinished tasks; Inbox: all ideas; Goals: active goals not done yet
    private func count(for tab: SidebarTab) -> Int? {
        switch tab {
        case .today:
            TodayTaskList.tasks(taskStore: taskStore, calendar: store.calendar).filter { $0.status != .done }.count
        case .inbox:
            taskStore.ideas().count
        case .goals:
            GoalsSection.activeGoals(taskStore: taskStore, calendar: store.calendar).filter { $0.status != .done }.count
        }
    }
}

/// Sidebar section title
struct SidebarSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

/// Empty-state hint shown when a panel has nothing in it
struct SidebarEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// Shared row background for the Today / Inbox / Goals lists:
/// a soft gray wash on hover, the accent tint when selected (selection wins over hover)
private struct SidebarRowBackground: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovering ? 0.07 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

extension View {
    func sidebarRowBackground(isSelected: Bool) -> some View {
        modifier(SidebarRowBackground(isSelected: isSelected))
    }
}
