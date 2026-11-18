import Foundation
import Testing
@testable import Immerse

@MainActor
struct SettingsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "immerse.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func 默认开启勿扰并使用默认快捷指令名称() {
        let settings = SettingsStore(defaults: freshDefaults())
        #expect(settings.dndEnabled)
        #expect(settings.dndOnShortcut == SettingsStore.defaultOnShortcut)
        #expect(settings.dndOffShortcut == SettingsStore.defaultOffShortcut)
        #expect(!settings.onboardingCompleted)
        #expect(!settings.dndActivatedByApp)
    }

    @Test func 修改后重新读取能保留() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.dndEnabled = false
        settings.dndOnShortcut = "开勿扰"
        settings.dndActivatedByApp = true

        let reloaded = SettingsStore(defaults: defaults)
        #expect(!reloaded.dndEnabled)
        #expect(reloaded.dndOnShortcut == "开勿扰")
        #expect(reloaded.dndActivatedByApp)
    }

    @Test func 快捷指令不存在时报错而不是卡住() async {
        await #expect(throws: (any Error).self) {
            try await ShortcutsRunner.run("Immerse 测试用-不存在的快捷指令-\(UUID().uuidString)", timeout: .seconds(5))
        }
    }
}
