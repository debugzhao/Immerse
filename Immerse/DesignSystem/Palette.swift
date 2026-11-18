import AppKit
import SwiftUI

extension Priority {
    /// 优先级主色，自动适配浅色 / 深色模式
    var color: Color {
        switch self {
        case .urgent: .dynamic(light: 0xE5484D, dark: 0xFF6369)
        case .important: .dynamic(light: 0xF5A524, dark: 0xFFC53D)
        case .normal: .dynamic(light: 0x8E4EC6, dark: 0xB07EE8)
        }
    }
}

enum Palette {
    /// 日程块填充的不透明度
    static let eventFillOpacity: Double = 0.18
    static let eventFillOpacityDone: Double = 0.07
    static let eventFillOpacitySelected: Double = 0.32

    static var gridLine: Color { Color(nsColor: .separatorColor).opacity(0.55) }
    static var weekendTint: Color { Color.primary.opacity(0.025) }
    static var nowIndicator: Color { Color(nsColor: .systemRed) }
}

extension Color {
    /// 按当前外观在两个十六进制颜色之间切换
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
