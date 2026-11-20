import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Versions up to 0.1.3 wrote a batch of demo tasks (copied from the developer's own Notion schedule) into the store on first launch,
/// so everyone who installed the DMG saw them. This removes that batch once.
///
/// Only tasks that match a legacy demo title AND were created in the same batch (createdAt within a few seconds, at least
/// `minimumBatchSize` of them) are deleted, so a user's own task that happens to be called 「周会」 is left alone.
public enum LegacySampleCleanup {
    public static let doneKey = "cleanup.legacySampleData.done"
    /// Set by old versions after seeding
    public static let seededKey = "didSeedSampleData"
    public static let minimumBatchSize = 8
    public static let batchWindow: TimeInterval = 5

    /// SHA-256 of the legacy demo titles. Stored as hashes so the developer's own task titles aren't shipped in the binary
    public static let legacyTitleHashes: Set<String> = [
        "4ab8b478f7fc978e393d9e788aaa4d9362695136fb3d59e93bd15850e4993361",
        "4f1ce594b8f390e739d085c0ab7b47d57cd5aa7ffb0a8ce6cd1f33d0c1d7958c",
        "54cad1c0fe86007255ee289d625078a284069f8aae2561781cc9fd4a7f67c568",
        "58d5d51148fac82ba1e2c876813455010cfcba087cda7594c0a18d823cc45a59",
        "5a337ca16d705a72153e265628d237595fbf6d00f7fa910a06d2eac2ab794c41",
        "5d925cc69d52ad83b3bfe95ae3e2f42a059f624e2b3089d00f1c1dd1d29f2a33",
        "64059a6cb5812106bd68fad010561eb3e9eb5a72b334b8d236ec803cd9ffeb79",
        "8e8f9dab45b49c93b2c63689a22758ce51aebf0c42193a78983a647d8dabea0d",
        "948c7280cf0de13b49542eda04edf94760163ed8b86e01a4627350281a46ca01",
        "9d1810013b364e6d32f47f9a00ff84aeae79ebf2809bbb5e2a0d1ad053ebc83f",
        "a7beb1bf64f713b9bd5e9b61fdb473a3d212fceb0537748e6a536645c4dd10d4",
        "d20672056a403ae36d15adc069ce4a680c6832ac768a4aba6d408d3d77dd8cd5",
        "eb7e640a6003859c3231ead703ad24962fdff701bf89992430b38959642ce3b6",
        "ee3cc915f0d857ab979e9d473dd1df2732015d42d3041a0152bef672c4f46719",
        "fd06df23c786bf0899095e6d01a6ca338f16c26674a9d5c50683f163ecafbd7c",
    ]

    public static func isLegacyTitle(_ title: String) -> Bool {
        legacyTitleHashes.contains(SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    public struct Record: Equatable {
        public let id: UUID
        public let title: String
        public let createdAt: Date
    }

    /// Pure selection logic: ids of the seeded batch, or empty if there isn't one
    public static func seededIDs(in records: [Record]) -> [UUID] {
        let candidates = records.filter { isLegacyTitle($0.title) }.sorted { $0.createdAt < $1.createdAt }
        guard let first = candidates.first else { return [] }
        // Old versions inserted the whole batch in one call, so the seeded tasks share (almost) the same createdAt
        let batch = candidates.filter { $0.createdAt.timeIntervalSince(first.createdAt) <= batchWindow }
        return batch.count >= minimumBatchSize ? batch.map(\.id) : []
    }

    /// Run once at launch. Returns how many tasks were removed
    @MainActor
    @discardableResult
    public static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        defer { defaults.set(true, forKey: doneKey) }
        // Never seeded (fresh install of a new version): nothing to clean
        guard defaults.bool(forKey: seededKey) else { return 0 }

        let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Cleanup")
        let context = container.mainContext
        do {
            // Titles are only known as hashes, so filter in memory (the store is small)
            let items = try context.fetch(FetchDescriptor<TaskItem>()).filter { isLegacyTitle($0.title) }
            let ids = Set(seededIDs(in: items.map { Record(id: $0.id, title: $0.title, createdAt: $0.createdAt) }))
            guard !ids.isEmpty else { return 0 }
            for item in items where ids.contains(item.id) {
                context.delete(item)
            }
            try context.save()
            logger.info("Removed \(ids.count) legacy demo tasks")
            return ids.count
        } catch {
            logger.error("Legacy demo cleanup failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
