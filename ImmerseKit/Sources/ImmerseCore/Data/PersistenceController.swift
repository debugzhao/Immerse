import Foundation
import SwiftData

/// Creates the SwiftData container.
///
/// Migration: stores written by any earlier version are upgraded by SwiftData's automatic lightweight migration
/// (verified by `SchemaMigrationTests`, starting from the pre-V2 layout). Every V2 change is additive or relaxes a rule
/// (new optional attributes, new entities, dropped unique constraints), which lightweight migration infers by itself.
///
/// CloudKit: off unless a container ID is passed in. `ModelConfiguration` defaults to `.automatic`, which would switch
/// sync on as soon as an iCloud entitlement shows up, so the choice is always made explicitly here.
public enum PersistenceController {
    /// All persisted model types (schema V2)
    public static let modelTypes: [any PersistentModel.Type] = [
        TaskItem.self, FocusSession.self, MemoryItem.self, ProfileSetting.self,
    ]

    /// Named explicitly: SwiftData otherwise derives the name from the main bundle, which test runners don't have
    static let configurationName = "Immerse"

    /// Info.plist key holding the CloudKit container ID (e.g. "iCloud.com.debugzhao.immerse"). Missing or empty = no sync
    public static let cloudKitContainerInfoKey = "ImmerseCloudKitContainer"

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

    /// CloudKit container ID from the main bundle's Info.plist, if sync is configured
    public static var configuredCloudKitContainer: String? {
        (Bundle.main.object(forInfoDictionaryKey: cloudKitContainerInfoKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The app's container: in memory for tests / screenshots, otherwise at `storeURL` (default: `defaultStoreURL()`)
    public static func makeContainer(storeURL: URL? = nil,
                                     cloudKitContainer: String? = configuredCloudKitContainer) throws -> ModelContainer {
        if isEphemeral {
            return try makeContainer(inMemory: true, url: nil, cloudKitContainer: nil)
        }
        return try makeContainer(inMemory: false, url: storeURL ?? defaultStoreURL(), cloudKitContainer: cloudKitContainer)
    }

    /// Lower-level factory, also used by tests that need an on-disk store
    public static func makeContainer(inMemory: Bool, url: URL?, cloudKitContainer: String?) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let database: ModelConfiguration.CloudKitDatabase = cloudKitContainer.map { .private($0) } ?? .none
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(configurationName, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let url {
            configuration = ModelConfiguration(configurationName, schema: schema, url: url, cloudKitDatabase: database)
        } else {
            configuration = ModelConfiguration(configurationName, schema: schema, cloudKitDatabase: database)
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// macOS: ~/Library/Application Support/com.debugzhao.immerse/Immerse.store (unchanged since 0.1).
    /// iOS: the shared App Group container when `appGroup` is given and the entitlement is present,
    /// so the widget and App Intents read the same store; Application Support otherwise.
    public static func defaultStoreURL(appGroup: String? = nil) throws -> URL {
        if let appGroup,
           let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let directory = shared.appendingPathComponent("Library/Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("Immerse.store")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        // Without the sandbox, the default path is ~/Library/Application Support/default.store,
        // which every non-sandboxed SwiftData app writes to, so it must be moved to an app-specific directory
        let directory = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.debugzhao.immerse", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Immerse.store")
    }

    /// Kept for the macOS app's existing call sites
    public static func storeURL() throws -> URL { try defaultStoreURL() }
}
