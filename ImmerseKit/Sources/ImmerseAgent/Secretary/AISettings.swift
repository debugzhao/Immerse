import Foundation
import Observation
import Security

/// Where the API key lives
public protocol SecretStore: AnyObject, Sendable {
    func read() -> String?
    func write(_ value: String?)
}

/// Keychain item for this device only: never synced to iCloud, not in backups restored to another phone
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.debugzhao.immerse.anthropic", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?) {
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func read() -> String? { value }
    public func write(_ value: String?) { self.value = value }
}

/// The AI switch, the user's key and data consent, and this month's token use.
/// The model is only called when all three hold: switch on, key saved, consent given (design §3.5).
@MainActor
@Observable
public final class AISettings {
    enum Key {
        static let enabled = "ai.enabled"
        static let consented = "ai.consented"
        static let keyInvalid = "ai.keyInvalid"
        static func usage(_ month: String) -> String { "ai.usage.\(month)" }
    }

    private let defaults: UserDefaults
    private let secrets: SecretStore

    /// On by default (decided 2026-11-20); without a key the app simply runs on rules
    public var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    public private(set) var hasConsented: Bool
    public private(set) var hasKey: Bool
    /// The API answered 401: the key stops being used until the user replaces it
    public private(set) var isKeyInvalid: Bool
    public private(set) var monthUsage: LLMUsage

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore(), now: Date = .now) {
        self.defaults = defaults
        self.secrets = secrets
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        hasConsented = defaults.bool(forKey: Key.consented)
        hasKey = !(secrets.read() ?? "").isEmpty
        isKeyInvalid = defaults.bool(forKey: Key.keyInvalid)
        monthUsage = Self.loadUsage(defaults, month: Self.month(now))
    }

    public var isAvailable: Bool { isEnabled && hasConsented && hasKey && !isKeyInvalid }

    public var apiKey: String? { secrets.read() }

    /// Saving the key is also where the user agrees to the data notice
    public func saveKey(_ key: String, consent: Bool) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.write(trimmed)
        hasKey = !trimmed.isEmpty
        hasConsented = consent
        defaults.set(consent, forKey: Key.consented)
        isKeyInvalid = false
        defaults.set(false, forKey: Key.keyInvalid)
    }

    public func removeKey() {
        secrets.write(nil)
        hasKey = false
    }

    public func markKeyInvalid() {
        isKeyInvalid = true
        defaults.set(true, forKey: Key.keyInvalid)
    }

    /// Last four characters, for "sk-…a1b2"
    public var maskedKey: String? {
        guard let key = secrets.read(), key.count > 4 else { return nil }
        return "…" + key.suffix(4)
    }

    public func record(_ usage: LLMUsage, now: Date = .now) {
        let month = Self.month(now)
        var current = Self.loadUsage(defaults, month: month)
        current = current + usage
        if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: Key.usage(month)) }
        monthUsage = current
    }

    static func month(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func loadUsage(_ defaults: UserDefaults, month: String) -> LLMUsage {
        defaults.data(forKey: Key.usage(month)).flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } ?? LLMUsage()
    }
}
