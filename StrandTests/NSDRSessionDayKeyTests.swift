import XCTest
import WhoopStore
@testable import Strand

/// The day an NSDR session's rest credit lands on must be the day Today shows (and reads the credit for)
/// when the session starts, including the #304 pre-04:00 carve-out, or a small-hours session is credited
/// to a day Today isn't showing.
@MainActor
final class NSDRSessionDayKeyTests: XCTestCase {

    private func day(_ key: String, sleepMin: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: 50,
                    strain: 40, exerciseCount: nil)
    }

    /// A local wall-clock instant, so the keys follow the device zone the way stored rows do.
    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Slept 22:00–02:45, so the night is banked under the new local day (2026-06-14) while the logical day
    /// is still 2026-06-13. A session at 03:15 goes on the wake day, the row Today shows.
    func testSmallHoursSessionAfterShortNightCreditsTheDayTodayShows() {
        let startedAt = local(2026, 6, 14, 3, 15)
        let rows = [day("2026-06-13", sleepMin: 420), day("2026-06-14", sleepMin: 285)]

        let key = Repository.nsdrSessionDayKey(startedAt: startedAt, days: rows)
        let todayShows = Repository.resolveToday(days: rows,
                                                 logicalKey: Repository.logicalDayKey(startedAt),
                                                 localKey: Repository.localDayKey(startedAt))?.day
        XCTAssertEqual(key, "2026-06-14")
        XCTAssertEqual(key, todayShows)
        XCTAssertNotEqual(key, Repository.logicalDayKey(startedAt), "the plain logical day is the old, wrong key")
    }

    /// No night banked for the new local day yet: Today still shows the logical day, so the session goes there.
    func testSmallHoursSessionWithoutBankedNightCreditsTheLogicalDay() {
        let startedAt = local(2026, 6, 14, 3, 15)
        let rows = [day("2026-06-13", sleepMin: 420), day("2026-06-14", sleepMin: nil)]
        XCTAssertEqual(Repository.nsdrSessionDayKey(startedAt: startedAt, days: rows), "2026-06-13")
    }

    /// No rows at all: the logical day, the key Today's `selectedDayKey` falls back to.
    func testNoRowsFallsBackToTheLogicalDay() {
        XCTAssertEqual(Repository.nsdrSessionDayKey(startedAt: local(2026, 6, 14, 3, 15), days: []), "2026-06-13")
        XCTAssertEqual(Repository.nsdrSessionDayKey(startedAt: local(2026, 6, 14, 15, 0), days: []), "2026-06-14")
    }

    /// Daytime: logical and local agree, and the session goes on that day.
    func testDaytimeSessionCreditsThatDay() {
        let rows = [day("2026-06-13", sleepMin: 420), day("2026-06-14", sleepMin: 450)]
        XCTAssertEqual(Repository.nsdrSessionDayKey(startedAt: local(2026, 6, 14, 15, 0), days: rows), "2026-06-14")
    }
}
