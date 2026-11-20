import AppKit
import ImmerseCore

extension NotificationService {
    /// Open System Settings → Notifications, for when the user denied permission earlier
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Hooks the shared service into AppKit: bring the app forward on tap, play "Glass" when time is up
    func installMacHooks() {
        onNotificationOpened = { NSApp.activate(ignoringOtherApps: true) }
        playTimeUpSound = { NSSound(named: "Glass")?.play() }
    }
}
