import SwiftData
import SwiftUI

@main
struct ImmerseApp: App {
    @State private var environment: AppEnvironment

    init() {
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer()
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
        let repository = SwiftDataTaskRepository(container: container)
        if !PersistenceController.isRunningTests {
            SampleData.seedIfNeeded(repository)
        }
        _environment = State(initialValue: AppEnvironment(repository: repository))
    }

    var body: some Scene {
        WindowGroup("Immerse", id: "main") {
            RootView()
                .environment(environment.taskStore)
                .environment(environment.calendarStore)
                .frame(minWidth: 960, minHeight: 600)
                #if DEBUG
                .onAppear { DebugSnapshot.scheduleIfRequested(environment: environment) }
                #endif
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ImmerseCommands(taskStore: environment.taskStore, calendarStore: environment.calendarStore)
        }
    }
}
