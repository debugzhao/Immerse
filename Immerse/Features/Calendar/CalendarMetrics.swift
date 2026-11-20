import Foundation
import ImmerseCore
import SwiftUI

/// Size constants for calendar views
enum CalendarMetrics {
    /// Tall enough that a 15-minute event (16 pt) fits one line of text and is easy to click
    static let hourHeight: CGFloat = 64
    static let gutterWidth: CGFloat = 56
    static let dayHeaderHeight: CGFloat = 44
    static let allDayLaneHeight: CGFloat = 22
    static let allDayMinHeight: CGFloat = 28
    /// Hour to scroll to by default on open
    static let initialScrollHour = 8
    /// Minimum height of an event block (15 minutes), and the shortest duration it maps to for overlap checks.
    /// Kept at exactly one snap step so every 15-minute event is drawn the same height and back-to-back ones stack
    static var minimumEventHeight: CGFloat { hourHeight / 4 }
    static var minimumEventDuration: TimeInterval { TimeInterval(minimumEventHeight / hourHeight * 3600) }

    static var gridHeight: CGFloat { hourHeight * 24 }

    static func scrollAnchorID(_ hour: Int) -> String { "hour-anchor-\(hour)" }
    static let nowAnchorID = "now-anchor"

    /// y coordinate of a date on that day's time grid
    static func yOffset(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    /// Drag snap granularity (minutes)
    static let snapMinutes = EventEditing.snapMinutes

    /// Time for a y coordinate on the grid, snapped to 15 minutes and clamped to the day
    static func date(forY y: CGFloat, dayStart: Date) -> Date {
        let minutes = Double(y / hourHeight) * 60
        let snapped = (minutes / Double(snapMinutes)).rounded() * Double(snapMinutes)
        let clamped = min(max(snapped, 0), 24 * 60)
        return dayStart.addingTimeInterval(clamped * 60)
    }

    /// Minutes for a vertical drag offset, snapped to 15 minutes
    static func snappedMinutes(forDeltaY dy: CGFloat) -> Int {
        let minutes = Double(dy / hourHeight) * 60
        return Int((minutes / Double(snapMinutes)).rounded()) * snapMinutes
    }
}

