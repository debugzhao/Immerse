@preconcurrency import ActivityKit
import Foundation
import ImmerseCore
import OSLog

/// Mirrors the focus session onto a Live Activity (Lock Screen + Dynamic Island).
/// Driven by `sync`, called whenever the session or phase changes; the countdown ticks on its own from `endDate`.
@MainActor
final class LiveActivityController {
    private var activity: Activity<FocusActivityAttributes>?
    private var lastState: FocusActivityAttributes.ContentState?
    private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "LiveActivity")

    init() {
        // Pick up an activity left running by a previous launch
        activity = Activity<FocusActivityAttributes>.activities.first
    }

    func sync(session: FocusSessionState?, phase: FocusEngine.Phase, now: Date = .now) {
        guard let session else {
            end(now: now)
            return
        }
        let state = FocusActivityAttributes.ContentState(
            startedAt: session.startedAt,
            endDate: session.expectedEnd(at: now) ?? now.addingTimeInterval(session.remaining(at: now)),
            pausedRemaining: session.isPaused ? session.remaining(at: now) : nil,
            plannedSeconds: session.plannedSeconds,
            isTimeUp: phase == .timeUp)

        if let activity, activity.attributes.taskID != session.taskID {
            end(now: now)
        }
        if activity == nil {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(
                    attributes: FocusActivityAttributes(taskID: session.taskID, taskTitle: session.taskTitle),
                    content: ActivityContent(state: state, staleDate: state.endDate.addingTimeInterval(3600)))
                lastState = state
            } catch {
                logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard state != lastState, let activity else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: state.endDate.addingTimeInterval(3600))) }
    }

    private func end(now: Date) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let final = activity.content
        // Leave the finished card up briefly so the user sees it ended, then remove it
        Task { await activity.end(final, dismissalPolicy: .after(now.addingTimeInterval(5 * 60))) }
    }
}
