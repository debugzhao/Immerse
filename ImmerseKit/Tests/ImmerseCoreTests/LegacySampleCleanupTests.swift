import Foundation
import Testing
@testable import ImmerseCore

struct LegacySampleCleanupTests {
    private let seededAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ title: String, after seconds: TimeInterval = 0) -> LegacySampleCleanup.Record {
        LegacySampleCleanup.Record(id: UUID(), title: title, createdAt: seededAt.addingTimeInterval(seconds))
    }

    /// The titles old versions seeded (plain text lives only in the tests, the app ships hashes)
    private static let legacyTitles = [
        "了解 Creative 链，完成第一天的任务", "阅读《第一性原理》", "了解 Uniswap 协议", "学会使用区块浏览器",
        "了解链上数据", "阅读《谈判技巧》", "整理 DeFi 学习笔记", "了解交易所概念", "周会", "Code Review",
        "Creative 链黑客松", "了解 Creative 链生态", "复盘本周", "健身", "规划下周主线任务",
    ]

    @Test func 哈希能识别全部旧标题() {
        #expect(Self.legacyTitles.allSatisfy(LegacySampleCleanup.isLegacyTitle))
        #expect(!LegacySampleCleanup.isLegacyTitle("写周报"))
    }

    private var seededBatch: [LegacySampleCleanup.Record] {
        Self.legacyTitles.enumerated().map { record($0.element, after: Double($0.offset) * 0.01) }
    }

    @Test func 删除同一批写入的示例任务() {
        let batch = seededBatch
        let own = record("写周报", after: 3600)
        let ids = Set(LegacySampleCleanup.seededIDs(in: batch + [own]))
        #expect(ids == Set(batch.map(\.id)))
    }

    @Test func 用户自己建的同名任务不删() {
        let batch = seededBatch
        let ownMeeting = record("周会", after: 86400)
        #expect(!LegacySampleCleanup.seededIDs(in: batch + [ownMeeting]).contains(ownMeeting.id))
    }

    @Test func 零散的同名任务不算示例数据() {
        let scattered = ["周会", "健身", "复盘本周", "Code Review"].enumerated().map { record($0.element, after: Double($0.offset) * 3600) }
        #expect(LegacySampleCleanup.seededIDs(in: scattered).isEmpty)
    }
}
