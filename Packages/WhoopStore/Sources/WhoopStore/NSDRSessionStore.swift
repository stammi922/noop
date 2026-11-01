import Foundation
import GRDB

// MARK: - v49 store: NSDR sessions
//
// NSDRSessionStore.swift — GRDB CRUD over the `nsdrSession` table (migration v49), the log behind the
// "Perform and Log NSDR" quick action. Follows the `LiveSessionStore` idiom: a plain Codable row struct,
// raw `Row` fetch + manual decode, all GRDB work via the actor's `syncWrite` / `syncRead` helpers.

/// One finished NSDR session. Natural key `startTs`. `day` is the logical day (04:00 boundary) the
/// session's rest credit is attributed to, fixed at write time so a later timezone change can't move it.
public struct NSDRSessionRow: Equatable, Codable, Sendable {
    public let startTs: Int          // unix seconds — first playback
    public let endTs: Int            // unix seconds — when the session was ended
    public let day: String           // yyyy-MM-dd logical day
    public let recordingId: String   // YouTube video id (NSDRCatalog)
    public let listenedS: Double     // seconds actually played, from the player clock
    public let nominalS: Double      // full length of the recording

    public init(startTs: Int, endTs: Int, day: String, recordingId: String,
                listenedS: Double, nominalS: Double) {
        self.startTs = startTs; self.endTs = endTs; self.day = day; self.recordingId = recordingId
        self.listenedS = listenedS; self.nominalS = nominalS
    }

    static func decode(_ row: Row) -> NSDRSessionRow {
        NSDRSessionRow(startTs: row["startTs"], endTs: row["endTs"], day: row["day"],
                       recordingId: row["recordingId"], listenedS: row["listenedS"], nominalS: row["nominalS"])
    }
}

extension WhoopStore {

    /// Log one session. Idempotent by `startTs`: logging the same session twice keeps one row with the
    /// later values. Returns rows changed.
    @discardableResult
    public func upsertNSDRSession(_ r: NSDRSessionRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO nsdrSession (startTs, endTs, day, recordingId, listenedS, nominalS)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(startTs) DO UPDATE SET
                    endTs = excluded.endTs,
                    day = excluded.day,
                    recordingId = excluded.recordingId,
                    listenedS = excluded.listenedS,
                    nominalS = excluded.nominalS
                """, arguments: [r.startTs, r.endTs, r.day, r.recordingId, r.listenedS, r.nominalS])
            return db.changesCount
        }
    }

    /// Sessions whose logical day falls in [fromDay, toDay] (inclusive, yyyy-MM-dd), oldest first.
    public func nsdrSessions(fromDay: String, toDay: String) async throws -> [NSDRSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, day, recordingId, listenedS, nominalS FROM nsdrSession
                WHERE day >= ? AND day <= ? ORDER BY startTs ASC
                """, arguments: [fromDay, toDay])
                .map(NSDRSessionRow.decode)
        }
    }

    /// The most recent sessions, newest first, for the history list.
    public func recentNSDRSessions(limit: Int) async throws -> [NSDRSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, day, recordingId, listenedS, nominalS FROM nsdrSession
                ORDER BY startTs DESC LIMIT ?
                """, arguments: [max(limit, 0)])
                .map(NSDRSessionRow.decode)
        }
    }
}
