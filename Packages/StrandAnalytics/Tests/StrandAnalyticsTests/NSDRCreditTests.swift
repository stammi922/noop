import XCTest
import WhoopStore
@testable import StrandAnalytics

/// NSDR rest credit: per-session thresholds, the per-day limits, and the guarantee that NSDR never
/// reaches into sleep (duration, the sleep composite itself, or a day without NSDR).
final class NSDRCreditTests: XCTestCase {
    private typealias Rest = AnalyticsEngine.Rest

    private let tenMin = 600.0
    private func session(_ listened: Double, of nominal: Double = 600) -> NSDRCredit.Session {
        NSDRCredit.Session(listenedSeconds: listened, nominalSeconds: nominal)
    }

    // One fixed scored night: 7 h asleep, 90 % efficiency, 1 h deep, 1.5 h REM.
    private let night = DailyMetric(day: "2026-11-01", totalSleepMin: 420, efficiency: 0.90, deepMin: 60,
                                    remMin: 90, lightMin: 270, disturbances: 3, restingHr: 52,
                                    avgHrv: 70, recovery: 66, strain: 8, exerciseCount: 0)

    // MARK: - Per session

    func testFullCreditAtAndAboveEightyPercent() {
        XCTAssertEqual(NSDRCredit.sessionPoints(session(480)), NSDRCredit.perSessionPoints)   // exactly 80 %
        XCTAssertEqual(NSDRCredit.sessionPoints(session(540)), NSDRCredit.perSessionPoints)
        XCTAssertEqual(NSDRCredit.sessionPoints(session(600)), NSDRCredit.perSessionPoints)
        // Listening past the end (a replay) never earns more than one full session.
        XCTAssertEqual(NSDRCredit.sessionPoints(session(900)), NSDRCredit.perSessionPoints)
    }

    func testZeroCreditBelowFiftyPercent() {
        XCTAssertEqual(NSDRCredit.sessionPoints(session(0)), 0)
        XCTAssertEqual(NSDRCredit.sessionPoints(session(120)), 0)
        XCTAssertEqual(NSDRCredit.sessionPoints(session(299)), 0)     // 49.8 %
        XCTAssertEqual(NSDRCredit.sessionPoints(session(300)), 0)     // exactly 50 %: ramp starts at 0
    }

    func testLinearRampBetweenFiftyAndEightyPercent() {
        // 65 % is halfway up the ramp → half credit.
        XCTAssertEqual(NSDRCredit.sessionPoints(session(390)), NSDRCredit.perSessionPoints / 2, accuracy: 1e-9)
        // 60 % → one third, 70 % → two thirds (rounded to 2 dp).
        XCTAssertEqual(NSDRCredit.sessionPoints(session(360)), 0.67, accuracy: 1e-9)
        XCTAssertEqual(NSDRCredit.sessionPoints(session(420)), 1.33, accuracy: 1e-9)
        // Monotone: one more minute never earns less.
        var last = -1.0
        for s in stride(from: 0.0, through: 600.0, by: 15.0) {
            let p = NSDRCredit.sessionPoints(session(s))
            XCTAssertGreaterThanOrEqual(p, last, "credit dropped at \(s)s")
            last = p
        }
    }

    func testDegenerateSessionsEarnNothing() {
        XCTAssertEqual(NSDRCredit.sessionPoints(session(300, of: 0)), 0)
        XCTAssertEqual(NSDRCredit.sessionPoints(session(-10)), 0)
    }

    // MARK: - Per day

    func testThreeSessionsEqualTwo() {
        let two = NSDRCredit.dailyPoints([session(600), session(600)])
        let three = NSDRCredit.dailyPoints([session(600), session(600), session(600)])
        XCTAssertEqual(two, 2 * NSDRCredit.perSessionPoints)
        XCTAssertEqual(three, two)
    }

    func testOnlyTheBestTwoSessionsCount() {
        // A weak first session does not use up a slot that a later full session could fill.
        XCTAssertEqual(NSDRCredit.dailyPoints([session(390), session(600), session(600)]),
                       2 * NSDRCredit.perSessionPoints)
        XCTAssertEqual(NSDRCredit.dailyPoints([session(600), session(390)]),
                       NSDRCredit.perSessionPoints * 1.5, accuracy: 1e-9)
    }

    func testNoSessionsIsExactlyZero() {
        XCTAssertEqual(NSDRCredit.dailyPoints([]), 0)
    }

    func testDailyCapIsClearlySmallerThanSleepsContribution() {
        // The most NSDR can ever add in one day…
        let maxDay = NSDRCredit.dailyPoints(Array(repeating: session(600), count: 10))
        XCTAssertEqual(maxDay, NSDRCredit.dailyCapPoints)
        XCTAssertLessThanOrEqual(Double(NSDRCredit.maxSessionsPerDay) * NSDRCredit.perSessionPoints,
                                 NSDRCredit.dailyCapPoints)
        // …is worth less than ONE hour of sleep through the Rest duration term (6.25 pts at an 8 h need),
        let oneHourOfSleep = Rest.wDuration * 100 * (1.0 / Rest.defaultNeedHours)
        XCTAssertLessThan(maxDay, oneHourOfSleep)
        // …and is a small fraction of the sleep composite's full range.
        XCTAssertLessThan(maxDay, Rest.wDuration * 100 * 0.1)
        // Concretely: 7 h of sleep + 2 NSDR sessions scores below 8 h of sleep with none.
        let sevenHours = Rest.composite(tstSeconds: 7 * 3600, inBedSeconds: 7 * 3600 / 0.9, efficiency: 0.9,
                                        restorativeSeconds: 2.5 * 3600, needHours: 8, consistency: nil,
                                        deepSeconds: 3600)
        let eightHours = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600 / 0.9, efficiency: 0.9,
                                        restorativeSeconds: 2.5 * 3600 * 8 / 7, needHours: 8, consistency: nil,
                                        deepSeconds: 3600 * 8 / 7)
        XCTAssertLessThan(Rest.withRestorativeCredit(sevenHours, creditPoints: maxDay)!, eightHours)
    }

    // MARK: - Applied to the Rest score

    func testOneFullSessionRaisesRestAndThreeEqualTwo() {
        let base = Rest.composite(daily: night)!
        let one = Rest.withRestorativeCredit(base, creditPoints: NSDRCredit.dailyPoints([session(600)]))!
        let two = Rest.withRestorativeCredit(base, creditPoints: NSDRCredit.dailyPoints([session(600), session(600)]))!
        let three = Rest.withRestorativeCredit(
            base, creditPoints: NSDRCredit.dailyPoints([session(600), session(600), session(600)]))!
        XCTAssertGreaterThan(one, base)
        XCTAssertEqual(one, base + NSDRCredit.perSessionPoints, accuracy: 1e-9)
        XCTAssertEqual(three, two)
    }

    func testNoNSDRDayIsUnchanged() {
        let base = Rest.composite(daily: night)!
        XCTAssertEqual(Rest.withRestorativeCredit(base, creditPoints: NSDRCredit.dailyPoints([])), base)
        // Byte-identical even for a value that is not on the 2 dp grid (an imported figure).
        XCTAssertEqual(Rest.withRestorativeCredit(87.123456, creditPoints: 0), 87.123456)
        XCTAssertNil(Rest.withRestorativeCredit(nil, creditPoints: 0))
    }

    func testNSDRNeverFabricatesARestScore() {
        XCTAssertNil(Rest.withRestorativeCredit(nil, creditPoints: NSDRCredit.dailyCapPoints))
    }

    func testCreditIsClampedAndRestStaysWithin100() {
        XCTAssertEqual(Rest.withRestorativeCredit(98.5, creditPoints: NSDRCredit.dailyCapPoints), 100)
        XCTAssertEqual(Rest.withRestorativeCredit(50, creditPoints: 99), 50 + NSDRCredit.dailyCapPoints)
        XCTAssertEqual(Rest.withRestorativeCredit(50, creditPoints: -5), 50)
    }

    func testSleepDurationAndSleepCompositeUnchangedByNSDR() {
        let before = night
        let baseBefore = Rest.composite(daily: night)
        _ = Rest.withRestorativeCredit(baseBefore, creditPoints: NSDRCredit.dailyPoints([session(600), session(600)]))
        // NSDR minutes are never added to the night: the stored sleep row and every sleep-derived figure
        // read back exactly as they were.
        XCTAssertEqual(night, before)
        XCTAssertEqual(night.totalSleepMin, 420)
        XCTAssertEqual(Rest.composite(daily: night), baseBefore)
        // The credited score equals sleep composite + credit; it is never what a longer night would give.
        let credited = Rest.withRestorativeCredit(baseBefore, creditPoints: NSDRCredit.perSessionPoints)!
        let longerNight = Rest.composite(tstSeconds: (420 + 10) * 60, inBedSeconds: (420 + 10) * 60 / 0.9,
                                         efficiency: 0.9, restorativeSeconds: 150 * 60, needHours: 8,
                                         consistency: nil, deepSeconds: 60 * 60)
        XCTAssertEqual(credited, baseBefore! + NSDRCredit.perSessionPoints, accuracy: 1e-9)
        XCTAssertNotEqual(credited, longerNight)
    }
}

/// The recording pool and the listen clock behind the NSDR screen.
final class NSDRCatalogTests: XCTestCase {

    func testPoolHasTheThreeDefaultRecordingsWithUniqueIds() {
        let ids = NSDRCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids), ["KHIbgSN2qAU", "kWnl1fiWhFY", "AKGrmY8OSHM"])
        XCTAssertEqual(Set(ids).count, ids.count)
        for r in NSDRCatalog.all {
            XCTAssertEqual(r.id.count, 11, "\(r.id) is not a YouTube video id")
            XCTAssertGreaterThan(r.nominalSeconds, 9 * 60)
            XCTAssertFalse(r.title.isEmpty)
            XCTAssertEqual(r.watchURL.host, "www.youtube.com")
        }
    }

    func testRandomPickUsesTheWholePool() {
        var seen = Set<String>()
        for i in 0..<NSDRCatalog.all.count { seen.insert(NSDRCatalog.randomPick(roll: { _ in i }).id) }
        XCTAssertEqual(seen, Set(NSDRCatalog.all.map(\.id)))
    }

    func testNextNeverRepeatsTheCurrentRecording() {
        for current in NSDRCatalog.all {
            for i in 0..<NSDRCatalog.all.count {
                let next = NSDRCatalog.randomPick(excluding: current.id, roll: { _ in i })
                XCTAssertNotEqual(next.id, current.id)
            }
            // The real RNG too.
            for _ in 0..<50 { XCTAssertNotEqual(NSDRCatalog.randomPick(excluding: current.id).id, current.id) }
        }
    }

    func testOutOfRangeRollIsClamped() {
        XCTAssertNotNil(NSDRCatalog.recordingById(NSDRCatalog.randomPick(roll: { _ in 99 }).id))
        XCTAssertNotNil(NSDRCatalog.recordingById(NSDRCatalog.randomPick(roll: { _ in -1 }).id))
    }

    func testListenTrackerCountsOnlyPlayback() {
        var t = NSDRListenTracker()
        for s in 0...10 { t.observe(position: Double(s), isPlaying: true) }   // 10 s played
        XCTAssertEqual(t.listenedSeconds, 10, accuracy: 1e-9)
        // Paused for a long wall-clock stretch: position frozen, nothing added.
        for _ in 0..<60 { t.observe(position: 10, isPlaying: false) }
        XCTAssertEqual(t.listenedSeconds, 10, accuracy: 1e-9)
        // A seek to near the end adds nothing; playback after it counts again.
        t.observe(position: 10, isPlaying: true)
        t.observe(position: 590, isPlaying: true)
        t.observe(position: 591, isPlaying: true)
        XCTAssertEqual(t.listenedSeconds, 11, accuracy: 1e-9)
        // Seeking backwards (a replay) adds nothing by itself.
        t.observe(position: 100, isPlaying: true)
        XCTAssertEqual(t.listenedSeconds, 11, accuracy: 1e-9)
    }
}
