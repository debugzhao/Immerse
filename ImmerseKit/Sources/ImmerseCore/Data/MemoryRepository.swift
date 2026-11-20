import Foundation
import SwiftData

/// Data access for the secretary's memories and accepted profile settings
@MainActor
public protocol MemoryRepository: AnyObject {
    /// All memories, newest first
    func memories() throws -> [MemorySnapshot]
    func upsert(_ memory: MemorySnapshot) throws
    func deleteMemory(id: UUID) throws
    func settingData(for key: String) throws -> Data?
    /// nil removes the setting
    func setSettingData(_ data: Data?, for key: String) throws
}

public extension MemoryRepository {
    func activeConstraints() throws -> [MemoryConstraint] {
        try memories().filter(\.isActive).compactMap(\.constraint)
    }

    func setting<Value: Decodable>(_ key: String, as type: Value.Type) throws -> Value? {
        try settingData(for: key).flatMap { try JSONDecoder().decode(Value.self, from: $0) }
    }

    func setSetting<Value: Encodable>(_ value: Value?, for key: String) throws {
        try setSettingData(value.map { try JSONEncoder().encode($0) }, for: key)
    }
}

@MainActor
public final class InMemoryMemoryRepository: MemoryRepository {
    public private(set) var items: [MemorySnapshot]
    public private(set) var settings: [String: Data] = [:]

    public init(items: [MemorySnapshot] = []) {
        self.items = items
    }

    public func memories() throws -> [MemorySnapshot] { items.sorted { $0.createdAt > $1.createdAt } }

    public func upsert(_ memory: MemorySnapshot) throws {
        if let index = items.firstIndex(where: { $0.id == memory.id }) {
            items[index] = memory
        } else {
            items.append(memory)
        }
    }

    public func deleteMemory(id: UUID) throws { items.removeAll { $0.id == id } }

    public func settingData(for key: String) throws -> Data? { settings[key] }

    public func setSettingData(_ data: Data?, for key: String) throws { settings[key] = data }
}

@MainActor
public final class SwiftDataMemoryRepository: MemoryRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func memories() throws -> [MemorySnapshot] {
        try context.fetch(FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            .map(\.snapshot)
    }

    public func upsert(_ memory: MemorySnapshot) throws {
        let id = memory.id
        var descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.apply(memory)
        } else {
            context.insert(MemoryItem(snapshot: memory))
        }
        try context.save()
    }

    public func deleteMemory(id: UUID) throws {
        try context.delete(model: MemoryItem.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    public func settingData(for key: String) throws -> Data? {
        try setting(key)?.valueData
    }

    public func setSettingData(_ data: Data?, for key: String) throws {
        if let existing = try setting(key) {
            if let data {
                existing.valueData = data
                existing.updatedAt = .now
            } else {
                context.delete(existing)
            }
        } else if let data {
            context.insert(ProfileSetting(key: key, valueData: data))
        }
        try context.save()
    }

    private func setting(_ key: String) throws -> ProfileSetting? {
        // Several rows can exist briefly after a CloudKit merge; the newest wins until DedupeService runs
        let descriptor = FetchDescriptor<ProfileSetting>(predicate: #Predicate { $0.key == key },
                                                         sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try context.fetch(descriptor).first
    }
}
