import SwiftUI

/// Purpose of a glass surface; each purpose maps to a different blur strength
enum GlassStyle: Sendable {
    /// Sticky date bar, all-day row
    case bar
    /// Detail panel, settings panel
    case panel
    /// Overlays such as the command palette and quick create
    case overlay
    /// Full-screen immersive view during focus
    case immersive
}

extension View {
    /// All glass effects go through here.
    /// Currently implemented with frosted glass (Material); when upgrading to macOS 26, just adopt Liquid Glass in `GlassSurfaceModifier`.
    func glassSurface(_ style: GlassStyle, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
    }
}

struct GlassSurfaceModifier: ViewModifier {
    let style: GlassStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        // After upgrading to macOS 26 + Xcode 26, add here:
        // #if compiler(>=6.2)
        // if #available(macOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius)) }
        // #endif
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(material, in: shape)
            .overlay {
                // A thin highlight along the glass edge, making the frosted glass feel more like glass
                shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(hasShadow ? 0.12 : 0), radius: 16, y: 6)
    }

    private var material: Material {
        switch style {
        case .bar: .bar
        case .panel: .regularMaterial
        case .overlay: .thickMaterial
        case .immersive: .ultraThinMaterial
        }
    }

    private var hasShadow: Bool {
        switch style {
        case .bar: false
        case .panel, .overlay, .immersive: true
        }
    }
}
