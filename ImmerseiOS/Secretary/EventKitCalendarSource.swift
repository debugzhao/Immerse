@preconcurrency import EventKit
import Foundation
import ImmerseAgent
import Observation

/// Read-only access to the system calendar, so the secretary schedules around meetings.
/// iOS 17 needs *full* access even to read events (write-only access can't see them).
@MainActor
@Observable
final class EventKitCalendarSource: ExternalCalendarSource {
    @ObservationIgnored private let store = EKEventStore()
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Bumped when the system calendar changes, so views showing external events refresh
    private(set) var revision = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    var isAuthorized: Bool { status == .fullAccess }
    var isUndetermined: Bool { status == .notDetermined }

    /// Shows the system prompt the first time; returns whether access was granted
    @discardableResult
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        status = EKEventStore.authorizationStatus(for: .event)
        revision += 1
        return granted
    }

    func events(in interval: DateInterval) -> [ExternalEvent] {
        _ = revision
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.availability != .free }
            .map { event in
                ExternalEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "（无标题）",
                              start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                              calendarTitle: event.calendar?.title ?? "")
            }
    }
}
