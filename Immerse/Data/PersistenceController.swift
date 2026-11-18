import Foundation
import SwiftData

/// 创建 SwiftData 容器。
enum PersistenceController {
    /// 正在跑单元测试吗？测试会以宿主 App 的身份启动整个 App，这时不能碰真实数据。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([TaskItem.self, FocusSession.self])
        let configuration: ModelConfiguration
        if isRunningTests {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // 没开沙盒时，默认路径是 ~/Library/Application Support/default.store，
            // 所有不开沙盒的 SwiftData App 都会写这个文件，必须换成 App 专属目录
            configuration = ModelConfiguration(schema: schema, url: try storeURL())
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// ~/Library/Application Support/com.debugzhao.immerse/Immerse.store
    static func storeURL() throws -> URL {
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
