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
        let focusRepository = SwiftDataFocusSessionRepository(tasks: repository)
        #if DEBUG
        if PersistenceController.isSnapshotMode {
            try? repository.insert(SampleData.make(around: .now))
            SampleData.seedFocusHistory(focusRepository, tasks: repository)
        }
        #endif
        // New installs start with an empty calendar; installs of 0.1.x get the old demo tasks removed once
        if !PersistenceController.isEphemeral {
            LegacySampleCleanup.runIfNeeded(container: container)
        }
        _environment = State(initialValue: AppEnvironment(
            repository: repository,
            focusRepository: focusRepository,
            isEphemeral: PersistenceController.isEphemeral
        ))
    }

    var body: some Scene {
        WindowGroup("沉浸日程", id: "main") {
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

        Window("专注统计", id: "stats") {
            StatsView()
                .injecting(environment)
        }
        .defaultSize(width: 680, height: 640)

        Settings {
            SettingsView()
                .injecting(environment)
        }
    }
}

extension View {
    /// Injects all stores into the view environment
    func injecting(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.taskStore)
            .environment(environment.calendarStore)
            .environment(environment.focusEngine)
            .environment(environment.settings)
            .environment(environment.shortcutsDND)
            .environment(environment.clockTimer)
            .environment(environment.notifications)
    }
}
