import Foundation
import StrandAnalytics
import WhoopStore

// NSDRLog.swift — the Repository side of "Perform and Log NSDR": write a finished session, read the
// history, and resolve the day's NSDR rest credit (`NSDRCredit`) for the Rest score.

extension Repository {

    /// Sessions shorter than this are not logged at all: an accidental tap on play is not a session.
    static let nsdrMinLoggedSeconds: Double = 30

    /// Log one finished NSDR session, attributed to the day Today showed when it started
    /// (`nsdrSessionDayKey`). Returns the stored row, or nil when the session was too short to log or the
    /// store is unavailable.
    @discardableResult
    func logNSDRSession(startedAt: Date, endedAt: Date, recordingId: String,
                        listenedSeconds: Double, nominalSeconds: Double) async -> NSDRSessionRow? {
        guard listenedSeconds >= Self.nsdrMinLoggedSeconds, let store = await storeHandle() else { return nil }
        let row = NSDRSessionRow(
            startTs: Int(startedAt.timeIntervalSince1970), endTs: Int(endedAt.timeIntervalSince1970),
            day: Self.nsdrSessionDayKey(startedAt: startedAt, days: days), recordingId: recordingId,
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

    /// The day key a session started at `startedAt` is credited to: the row Today shows at that moment,
    /// through the same `resolveToday` Today reads its Rest with. Keying by the plain logical day would
    /// miss the #304 pre-04:00 carve-out: after a 22:00–02:45 sleep, Today at 03:15 shows the wake day's
    /// row while the logical day is still yesterday, so the credit would land on a day Today isn't
    /// showing. Falls back to the logical day when no row exists yet, as Today's `selectedDayKey` does.
    static func nsdrSessionDayKey(startedAt: Date, days: [DailyMetric]) -> String {
        let logicalKey = logicalDayKey(startedAt)
        return resolveToday(days: days, logicalKey: logicalKey, localKey: localDayKey(startedAt))?.day ?? logicalKey
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
