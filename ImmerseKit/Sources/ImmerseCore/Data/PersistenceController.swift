import Foundation
import SwiftData

/// Creates the SwiftData container.
public enum PersistenceController {
    /// Are unit tests running? Tests launch the whole app as the host app, so real data must not be touched.
    public static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Debug self-screenshot mode: in-memory database + sample data, real data untouched
    public static var isSnapshotMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["IMMERSE_SNAPSHOT"] != nil
        #else
        false
        #endif
    }

    /// No persistence: tests and screenshots both use an in-memory database
    public static var isEphemeral: Bool { isRunningTests || isSnapshotMode }

    public static func makeContainer() throws -> ModelContainer {
        let schema = Schema([TaskItem.self, FocusSession.self])
        let configuration: ModelConfiguration
        if isEphemeral {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Without the sandbox, the default path is ~/Library/Application Support/default.store,
            // which every non-sandboxed SwiftData app writes to, so it must be moved to an app-specific directory
            configuration = ModelConfiguration(schema: schema, url: try storeURL())
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// ~/Library/Application Support/com.debugzhao.immerse/Immerse.store
    public static func storeURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.debugzhao.immerse", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Immerse.store")
    }
}
