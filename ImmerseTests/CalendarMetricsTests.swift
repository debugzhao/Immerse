import Testing
@testable import Immerse

struct CalendarMetricsTests {
    @Test func 吸附到15分钟() {
        #expect(CalendarMetrics.snappedMinutes(forDeltaY: CalendarMetrics.hourHeight * 0.3) == 15)
        #expect(CalendarMetrics.snappedMinutes(forDeltaY: -CalendarMetrics.hourHeight * 0.55) == -30)
    }
}
