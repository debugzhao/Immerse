import ImmerseAgent
import ImmerseCore
import SwiftUI
import WidgetKit

@main
struct ImmerseiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: model.focusEngine.session, initial: true) { _, session in
                    model.liveActivities.sync(session: session, phase: model.focusEngine.phase)
                }
                .onChange(of: model.focusEngine.phase) { _, phase in
                    model.liveActivities.sync(session: model.focusEngine.session, phase: phase)
                }
                .onChange(of: model.taskStore.revision) {
                    // Keep the Today widget in step with every change
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .environment(model.taskStore)
                .environment(model.focusEngine)
                .environment(model.settings)
                .environment(model.notifications)
                .environment(model.schedule)
                .environment(model.secretary)
                .environment(model.ai)
                .environment(model.calendarSource)
                .environment(model.preferences)
        }
        .backgroundTask(.appRefresh(NudgeScheduler.refreshTaskID)) {
            await MainActor.run { model.backgroundRefresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.didBecomeActive() }
        }
    }
}
