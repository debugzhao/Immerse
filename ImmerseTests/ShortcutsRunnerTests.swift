import Foundation
import Testing
@testable import Immerse

struct ShortcutsRunnerTests {
    @Test func 快捷指令不存在时报错而不是卡住() async {
        await #expect(throws: (any Error).self) {
            try await ShortcutsRunner.run("Immerse 测试用-不存在的快捷指令-\(UUID().uuidString)", timeout: .seconds(5))
        }
    }
}
