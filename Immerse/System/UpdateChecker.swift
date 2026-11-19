import AppKit
import Foundation
import Observation
import OSLog

/// A published release on GitHub
struct AppRelease: Equatable, Sendable {
    let version: String
    let notes: String
    /// Direct link to the DMG, falling back to the release page when there is no DMG asset
    let downloadURL: URL
    let pageURL: URL
}

/// Version logic (pure, easy to test)
enum AppVersion {
    /// "v0.1.10" → [0, 1, 10]. Non-numeric suffixes ("-beta") are ignored
    static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        return trimmed.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    /// true when `candidate` is strictly newer than `current` (compares numerically, so 0.1.10 > 0.1.9)
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Decode GitHub's "latest release" response
    static func release(fromGitHubJSON data: Data) throws -> AppRelease {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return AppRelease(
            version: String(payload.tag_name.drop { $0 == "v" || $0 == "V" }),
            notes: payload.body ?? "",
            downloadURL: dmg?.browser_download_url ?? payload.html_url,
            pageURL: payload.html_url
        )
    }
}

/// Checks GitHub Releases for a newer version. Automatic check at launch (at most once a day), manual check from the menu.
/// It only tells the user and opens the download; installing is still drag-to-Applications.
@MainActor
@Observable
final class UpdateChecker {
    enum ManualResult: Equatable {
        case upToDate(String)
        case failed(String)
    }

    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/debugzhao/Immerse/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 3600

    private enum Key {
        static let autoCheck = "update.autoCheck"
        static let lastCheck = "update.lastCheck"
        static let skippedVersion = "update.skippedVersion"
    }

    /// A newer release to show in the update sheet
    var availableUpdate: AppRelease?
    /// Result of a manual check that found nothing / failed, shown as an alert
    var manualResult: ManualResult?
    private(set) var isChecking = false
    var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Key.autoCheck) }
    }

    let currentVersion: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async throws -> Data
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Update")

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         defaults: UserDefaults = .standard,
         fetch: (@Sendable () async throws -> Data)? = nil) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch ?? {
            var request = URLRequest(url: UpdateChecker.latestReleaseURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
        defaults.register(defaults: [Key.autoCheck: true])
        autoCheckEnabled = defaults.bool(forKey: Key.autoCheck)
    }

    /// Launch-time check: silent, at most once per `checkInterval`, respects "skip this version"
    func checkAutomaticallyIfDue(now: Date = .now) async {
        guard autoCheckEnabled else { return }
        if let last = defaults.object(forKey: Key.lastCheck) as? Date, now.timeIntervalSince(last) < Self.checkInterval {
            return
        }
        guard let release = await latestRelease() else { return }
        defaults.set(now, forKey: Key.lastCheck)
        if AppVersion.isNewer(release.version, than: currentVersion),
           release.version != defaults.string(forKey: Key.skippedVersion) {
            availableUpdate = release
        }
    }

    /// Menu → 检查更新…: always reports a result, ignores "skip this version"
    func checkManually() async {
        guard let release = await latestRelease() else {
            manualResult = .failed("无法连接 GitHub，请检查网络后重试")
            return
        }
        defaults.set(Date(), forKey: Key.lastCheck)
        if AppVersion.isNewer(release.version, than: currentVersion) {
            availableUpdate = release
        } else {
            manualResult = .upToDate(currentVersion)
        }
    }

    func download(_ release: AppRelease) {
        NSWorkspace.shared.open(release.downloadURL)
        availableUpdate = nil
    }

    func skip(_ release: AppRelease) {
        defaults.set(release.version, forKey: Key.skippedVersion)
        availableUpdate = nil
    }

    private func latestRelease() async -> AppRelease? {
        isChecking = true
        defer { isChecking = false }
        do {
            return try AppVersion.release(fromGitHubJSON: try await fetch())
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
