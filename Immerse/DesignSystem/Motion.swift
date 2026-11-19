import SwiftUI

/// Global animation parameters, keeping motion pacing consistent everywhere
enum Motion {
    static var snappy: Animation { .spring(response: 0.3, dampingFraction: 0.85) }
    static var gentle: Animation { .spring(response: 0.45, dampingFraction: 0.9) }
    static var breathing: Animation { .easeInOut(duration: 1.6) }
}
