import Foundation

/// A clock that tests can advance manually (ImmerseCoreTests has its own copy; test targets can't share code)
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}
