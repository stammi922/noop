import XCTest
@testable import WhoopStore

/// Round-trips the `nsdrSession` table (migration v49): log → read by day range and newest-first, and a
/// re-log of the same session updates its row instead of adding a second one.
final class NSDRSessionStoreTests: XCTestCase {

    private func row(_ startTs: Int, day: String, listened: Double = 600) -> NSDRSessionRow {
        NSDRSessionRow(startTs: startTs, endTs: startTs + Int(listened) + 30, day: day,
                       recordingId: "KHIbgSN2qAU", listenedS: listened, nominalS: 642)
    }

    func test_log_and_read_back_by_day_range() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertNSDRSession(row(1_000, day: "2026-10-31"))
        _ = try await store.upsertNSDRSession(row(90_000, day: "2026-11-01"))
        _ = try await store.upsertNSDRSession(row(95_000, day: "2026-11-01", listened: 200))

        let nov1 = try await store.nsdrSessions(fromDay: "2026-11-01", toDay: "2026-11-01")
        XCTAssertEqual(nov1.map(\.startTs), [90_000, 95_000], "oldest first, other days excluded")
        XCTAssertEqual(nov1.last, row(95_000, day: "2026-11-01", listened: 200))

        let both = try await store.nsdrSessions(fromDay: "2026-10-31", toDay: "2026-11-01")
        XCTAssertEqual(both.count, 3)
    }

    func test_relogging_the_same_session_updates_one_row() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertNSDRSession(row(1_000, day: "2026-11-01", listened: 100))
        _ = try await store.upsertNSDRSession(row(1_000, day: "2026-11-01", listened: 520))
        let rows = try await store.nsdrSessions(fromDay: "0000-01-01", toDay: "9999-12-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.listenedS, 520)
    }

    func test_recent_is_newest_first_and_limited() async throws {
        let store = try await WhoopStore.inMemory()
        for (i, ts) in [1_000, 5_000, 9_000].enumerated() {
            _ = try await store.upsertNSDRSession(row(ts, day: "2026-11-0\(i + 1)"))
        }
        let recent = try await store.recentNSDRSessions(limit: 2)
        XCTAssertEqual(recent.map(\.startTs), [9_000, 5_000])
        let none = try await store.recentNSDRSessions(limit: 0)
        XCTAssertTrue(none.isEmpty)
    }
}
