import ImmerseCore
import SwiftUI

extension View {
    /// Accept ideas / goals dragged from the sidebar. `time(location)` turns the drop point into a start time;
    /// `allDay` drops create all-day events (all-day row, month view).
    func acceptsPlanningDrop(allDay: Bool, time: @escaping (CGPoint) -> Date) -> some View {
        modifier(PlanningDropModifier(allDay: allDay, time: time))
    }
}

private struct PlanningDropModifier: ViewModifier {
    let allDay: Bool
    let time: (CGPoint) -> Date

    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                // Light highlight on the column / cell under the pointer
                if isTargeted {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { items, location in
                guard let id = items.compactMap(UUID.init(uuidString:)).first,
                      let source = taskStore.task(id: id), source.kind != .event else { return false }
                let start = time(location)
                guard let event = taskStore.schedule(id, at: start, allDay: allDay, calendar: store.calendar) else { return false }
                store.select(event.id)
                let when = allDay
                    ? "\(store.calendar.component(.month, from: start))月\(store.calendar.component(.day, from: start))日"
                    : "\(store.calendar.component(.month, from: start))月\(store.calendar.component(.day, from: start))日 \(TimeText.hhmm(start, calendar: store.calendar))"
                taskStore.toast = Toast(message: source.kind == .goal ? "已为「\(source.displayTitle)」安排 \(when)" : "已安排到 \(when)",
                                        showsUndo: true)
                return true
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
            }
    }
}
