import AppKit

/// The app's own icon.
///
/// `NSApp.applicationIconImage` comes back as the generic placeholder for this build (the asset catalog icon isn't
/// resolved for it), so load the compiled AppIcon.icns from the bundle, falling back to what the system shows in Finder.
@MainActor
enum AppIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icns = NSImage(contentsOf: url) {
            return icns
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    /// Make system-drawn UI (alerts, About panel) use the real icon too
    static func install() {
        NSApp.applicationIconImage = image
    }
}
