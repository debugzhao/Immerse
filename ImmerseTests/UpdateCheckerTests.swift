import Foundation
import Testing
@testable import Immerse

struct AppVersionTests {
    @Test func 按数字比较版本() {
        #expect(AppVersion.isNewer("0.1.4", than: "0.1.3"))
        #expect(AppVersion.isNewer("v0.1.10", than: "0.1.9"))
        #expect(AppVersion.isNewer("1.0", than: "0.9.9"))
        #expect(!AppVersion.isNewer("0.1.3", than: "0.1.3"))
        #expect(!AppVersion.isNewer("0.1.3", than: "0.1.3.0"))
        #expect(!AppVersion.isNewer("0.1.2", than: "0.1.3"))
    }

    @Test func 解析GitHub返回() throws {
        let json = """
        {"tag_name":"v0.1.4","html_url":"https://github.com/debugzhao/Immerse/releases/tag/v0.1.4","body":"## What's Changed",
         "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c.txt"},
                   {"name":"Immerse-0.1.4.dmg","browser_download_url":"https://example.com/Immerse-0.1.4.dmg"}]}
        """
        let release = try AppVersion.release(fromGitHubJSON: Data(json.utf8))
        #expect(release.version == "0.1.4")
        #expect(release.downloadURL.absoluteString == "https://example.com/Immerse-0.1.4.dmg")
        #expect(release.notes == "## What's Changed")
    }

    @Test func 没有DMG时退回到发布页() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","body":null,"assets":[]}"#
        let release = try AppVersion.release(fromGitHubJSON: Data(json.utf8))
        #expect(release.downloadURL == release.pageURL)
        #expect(release.notes.isEmpty)
    }
}

@MainActor
struct UpdateCheckerTests {
    private func makeDefaults() -> UserDefaults {
        let name = "update-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func checker(latest: String, current: String = "0.1.3", defaults: UserDefaults) -> UpdateChecker {
        let json = #"{"tag_name":"v\#(latest)","html_url":"https://github.com/x/y","body":"notes","assets":[]}"#
        return UpdateChecker(currentVersion: current, defaults: defaults, fetch: { Data(json.utf8) })
    }

    @Test func 有新版本时自动检查会提示() async {
        let updater = checker(latest: "0.1.4", defaults: makeDefaults())
        await updater.checkAutomaticallyIfDue()
        #expect(updater.availableUpdate?.version == "0.1.4")
    }

    @Test func 一天内只自动检查一次() async {
        let defaults = makeDefaults()
        let now = Date()
        await checker(latest: "0.1.3", defaults: defaults).checkAutomaticallyIfDue(now: now)
        let second = checker(latest: "0.1.4", defaults: defaults)
        await second.checkAutomaticallyIfDue(now: now.addingTimeInterval(3600))
        #expect(second.availableUpdate == nil)
        await second.checkAutomaticallyIfDue(now: now.addingTimeInterval(25 * 3600))
        #expect(second.availableUpdate?.version == "0.1.4")
    }

    @Test func 跳过的版本自动检查不再提示但手动检查会() async {
        let defaults = makeDefaults()
        let first = checker(latest: "0.1.4", defaults: defaults)
        await first.checkManually()
        first.skip(first.availableUpdate!)
        defaults.removeObject(forKey: "update.lastCheck")

        let auto = checker(latest: "0.1.4", defaults: defaults)
        await auto.checkAutomaticallyIfDue()
        #expect(auto.availableUpdate == nil)
        await auto.checkManually()
        #expect(auto.availableUpdate?.version == "0.1.4")
    }

    @Test func 手动检查已是最新() async {
        let updater = checker(latest: "0.1.3", defaults: makeDefaults())
        await updater.checkManually()
        #expect(updater.manualResult == .upToDate("0.1.3"))
    }

    @Test func 关闭自动检查后不请求() async {
        let defaults = makeDefaults()
        let updater = checker(latest: "0.1.4", defaults: defaults)
        updater.autoCheckEnabled = false
        await updater.checkAutomaticallyIfDue()
        #expect(updater.availableUpdate == nil)
    }
}
