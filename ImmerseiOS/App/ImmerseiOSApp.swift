import ImmerseAgent
import ImmerseCore
import SwiftUI

@main
struct ImmerseiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model.taskStore)
                .environment(model.focusEngine)
                .environment(model.settings)
                .environment(model.notifications)
                .environment(model.schedule)
                .environment(model.secretary)
                .environment(model.ai)
                .environment(model.calendarSource)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.didBecomeActive() }
        }
    }
}
