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
        if PersistenceController.isSnapshotMode {
            try? repository.insert(SampleData.make(around: .now))
        } else if !PersistenceController.isRunningTests {
            SampleData.seedIfNeeded(repository)
        }
        _environment = State(initialValue: AppEnvironment(
            repository: repository,
            focusRepository: SwiftDataFocusSessionRepository(tasks: repository),
            isEphemeral: PersistenceController.isEphemeral
        ))
    }

    var body: some Scene {
        WindowGroup("Immerse", id: "main") {
            RootView()
                .injecting(environment)
                .frame(minWidth: 960, minHeight: 600)
                #if DEBUG
                .onAppear { DebugSnapshot.scheduleIfRequested(environment: environment) }
                #endif
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ImmerseCommands(environment: environment)
        }

        MenuBarExtra {
            MenuBarFocusView()
                .injecting(environment)
        } label: {
            MenuBarLabel()
                .injecting(environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .injecting(environment)
        }
    }
}

extension View {
    /// 把所有 Store 注入视图环境
    func injecting(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.taskStore)
            .environment(environment.calendarStore)
            .environment(environment.focusEngine)
            .environment(environment.settings)
            .environment(environment.shortcutsDND)
    }
}
