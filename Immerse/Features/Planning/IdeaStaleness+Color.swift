import ImmerseCore
import SwiftUI

extension IdeaStaleness {
    var color: Color {
        switch self {
        case .fresh: .secondary
        case .aging: .orange
        case .stale: .red
        }
    }
}
