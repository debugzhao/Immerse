import ImmerseCore
import SwiftUI
import UIKit

// Same colors and motion as the macOS app (Immerse/DesignSystem), rebuilt on UIColor.

extension Priority {
    /// Primary priority color, adapts to light / dark mode
    var color: Color {
        switch self {
        case .urgent: .dynamic(light: 0xE5484D, dark: 0xFF6369)
        case .important: .dynamic(light: 0xF5A524, dark: 0xFFC53D)
        case .normal: .dynamic(light: 0x8E4EC6, dark: 0xB07EE8)
        }
    }
}

extension TaskStatus {
    var color: Color {
        switch self {
        case .todo: .gray
        case .inProgress: .blue
        case .done: .green
        }
    }
}

extension IdeaStaleness {
    var color: Color {
        switch self {
        case .fresh: .secondary
        case .aging: .orange
        case .stale: .red
        }
    }
}

enum Palette {
    static let eventFillOpacity: Double = 0.18
    static let eventFillOpacityDone: Double = 0.07
    static let eventFillOpacityDragging: Double = 0.32

    static var gridLine: Color { Color(uiColor: .separator).opacity(0.6) }
    static var weekendTint: Color { Color.primary.opacity(0.025) }
    static var nowIndicator: Color { Color(uiColor: .systemRed) }
    /// Brand indigo from the app icon, used for the "+" button and focus ring
    static var brand: Color { .dynamic(light: 0x5B54E0, dark: 0x8A84FF) }
}

enum Motion {
    static var snappy: Animation { .spring(response: 0.3, dampingFraction: 0.85) }
    static var gentle: Animation { .spring(response: 0.45, dampingFraction: 0.9) }
    static var breathing: Animation { .easeInOut(duration: 1.6) }
}

extension Color {
    /// Switches between two hex colors based on the current appearance
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Frosted surface used for floating bars and cards, matching the macOS app's Material look
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

/// Haptic feedback for the calendar's long-press drag and other confirmations
@MainActor
enum Haptics {
    static func pickUp() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func step() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
