import Foundation
import StrandAnalytics
import WhoopStore

// NSDRLog.swift — the Repository side of "Perform and Log NSDR": write a finished session, read the
// history, and resolve the day's NSDR rest credit (`NSDRCredit`) for the Rest score.

extension Repository {

    /// Sessions shorter than this are not logged at all: an accidental tap on play is not a session.
    static let nsdrMinLoggedSeconds: Double = 30

    /// Log one finished NSDR session, attributed to the logical day (04:00 boundary) it started on.
    /// Returns the stored row, or nil when the session was too short to log or the store is unavailable.
    @discardableResult
    func logNSDRSession(startedAt: Date, endedAt: Date, recordingId: String,
                        listenedSeconds: Double, nominalSeconds: Double) async -> NSDRSessionRow? {
        guard listenedSeconds >= Self.nsdrMinLoggedSeconds, let store = await storeHandle() else { return nil }
        let row = NSDRSessionRow(
            startTs: Int(startedAt.timeIntervalSince1970), endTs: Int(endedAt.timeIntervalSince1970),
            day: Self.logicalDayKey(startedAt), recordingId: recordingId,
            listenedS: listenedSeconds.rounded(), nominalS: nominalSeconds)
        do {
            try await store.upsertNSDRSession(row)
        } catch {
            NSLog("NSDR: failed to log session: \(error)")
            return nil
        }
        noteNSDRChanged()
        return row
    }

    /// The most recent logged sessions, newest first.
    func recentNSDRSessions(limit: Int = 20) async -> [NSDRSessionRow] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.recentNSDRSessions(limit: limit)) ?? []
    }

    /// The Rest points the day's NSDR sessions add (0 when there are none).
    func nsdrRestCredit(day: String) async -> Double {
        guard let store = await storeHandle(),
              let rows = try? await store.nsdrSessions(fromDay: day, toDay: day) else { return 0 }
        return Self.nsdrRestCredit(rows)
    }

    /// Pure: the credit for one day's rows, through the single `NSDRCredit` config.
    nonisolated static func nsdrRestCredit(_ rows: [NSDRSessionRow]) -> Double {
        NSDRCredit.dailyPoints(rows.map {
            NSDRCredit.Session(listenedSeconds: $0.listenedS, nominalSeconds: $0.nominalS)
        })
    }
}
