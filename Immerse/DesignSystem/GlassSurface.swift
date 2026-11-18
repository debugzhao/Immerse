import SwiftUI

/// 玻璃表面的用途，不同用途对应不同的模糊强度
enum GlassStyle: Sendable {
    /// 吸顶的日期栏、全天行
    case bar
    /// 详情面板、设置面板
    case panel
    /// 命令面板、快速创建等浮层
    case overlay
    /// 专注时的全屏沉浸视图
    case immersive
}

extension View {
    /// 所有玻璃效果统一走这里。
    /// 目前用毛玻璃（Material）实现；以后升级到 macOS 26，只需在 `GlassSurfaceModifier` 里接入 Liquid Glass。
    func glassSurface(_ style: GlassStyle, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
    }
}

struct GlassSurfaceModifier: ViewModifier {
    let style: GlassStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        // 升级到 macOS 26 + Xcode 26 后，在这里加：
        // #if compiler(>=6.2)
        // if #available(macOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius)) }
        // #endif
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(material, in: shape)
            .overlay {
                // 玻璃边缘的一圈细高光，让毛玻璃更有「玻璃」的质感
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
