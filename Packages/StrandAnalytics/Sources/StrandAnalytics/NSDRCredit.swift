import Foundation

// NSDRCredit.swift — how a logged NSDR session nudges the day's Rest score.
// Created: 2026-11-01
// Last updated: 2026-11-01
//
// PURE + unit-tested (NSDRCreditTests). Every weight lives in `NSDRCredit`; nothing else in the app
// decides how much an NSDR session is worth.

/// The rest credit an NSDR (Non-Sleep Deep Rest / yoga nidra) session earns.
///
/// Rationale: Huberman Lab (https://www.hubermanlab.com/nsdr) describes NSDR as a way to restore mental
/// and physical energy and to help recover from a poor night, while stating that "nothing can completely
/// replace sleep". So the credit is a small, capped ADD-ON to the Rest
/// composite, never an input to it: it does not count as sleep time, and it never changes total sleep,
/// efficiency, stages, sleep need or sleep debt. A day without NSDR scores exactly as before.
///
/// The numbers, all on the Rest 0–100 scale:
/// - A session earns full credit (`perSessionPoints`, 2.0) once the user listened to at least
///   `fullCreditFraction` (80 %) of the recording's nominal length. NSDR scripts are short and the
///   benefit comes from completing the protocol, so 8 of 10 minutes is "done".
/// - Below `zeroCreditBelowFraction` (50 %) a session earns 0: half a script is not the protocol.
/// - Between 50 % and 80 % the credit ramps LINEARLY from 0 to full (65 % listened earns half). A ramp
///   rather than a step, so there is no cliff at either edge and an extra minute always counts a little.
/// - Only the `maxSessionsPerDay` (2) best sessions of a day count; a third session adds 0.
/// - The day's total is capped at `dailyCapPoints` (4.0). For scale: in `AnalyticsEngine.Rest` the
///   sleep-duration term alone is worth 50 points, so one hour of sleep against the default 8 h need is
///   worth 6.25 points. A full day of NSDR is worth less than one hour of sleep, by design.
public enum NSDRCredit {
    /// Share of the nominal length that earns full per-session credit.
    public static let fullCreditFraction: Double = 0.80
    /// Share of the nominal length below which a session earns nothing.
    public static let zeroCreditBelowFraction: Double = 0.50
    /// Rest points one complete session adds.
    public static let perSessionPoints: Double = 2.0
    /// How many sessions per day can earn credit (the best ones).
    public static let maxSessionsPerDay: Int = 2
    /// Hard ceiling on the day's NSDR credit, in Rest points.
    public static let dailyCapPoints: Double = 4.0

    /// One finished session, reduced to what the credit needs.
    public struct Session: Equatable, Sendable {
        /// Seconds actually played (from the player's clock, never wall time while paused).
        public let listenedSeconds: Double
        /// Full length of the recording that was playing.
        public let nominalSeconds: Double

        public init(listenedSeconds: Double, nominalSeconds: Double) {
            self.listenedSeconds = listenedSeconds; self.nominalSeconds = nominalSeconds
        }
    }

    /// Share of the per-session credit earned, in [0, 1].
    public static func sessionFraction(_ s: Session) -> Double {
        guard s.nominalSeconds > 0, s.listenedSeconds > 0 else { return 0 }
        let listened = min(s.listenedSeconds / s.nominalSeconds, 1.0)
        if listened >= fullCreditFraction { return 1.0 }
        if listened < zeroCreditBelowFraction { return 0.0 }
        return (listened - zeroCreditBelowFraction) / (fullCreditFraction - zeroCreditBelowFraction)
    }

    /// Rest points one session earns on its own (before the per-day limits), rounded to 2 dp.
    public static func sessionPoints(_ s: Session) -> Double {
        round2(perSessionPoints * sessionFraction(s))
    }

    /// Rest points a day's sessions add: the best `maxSessionsPerDay` sessions, capped at
    /// `dailyCapPoints`, rounded to 2 dp. No sessions → exactly 0.
    public static func dailyPoints(_ sessions: [Session]) -> Double {
        let best = sessions.map(sessionPoints).sorted(by: >).prefix(maxSessionsPerDay)
        return round2(min(best.reduce(0, +), dailyCapPoints))
    }

    private static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }
}

extension AnalyticsEngine.Rest {
    /// The day's Rest score with its restorative (NSDR) credit added on top of the sleep composite.
    /// `rest` is the sleep-derived Rest composite (or imported sleep performance) for the day and is
    /// returned untouched when the credit is 0, so a day without NSDR is byte-identical to before. A day
    /// with no Rest score stays nil: NSDR alone never fabricates one. The credit is clamped to
    /// `NSDRCredit.dailyCapPoints` and the result to 100.
    public static func withRestorativeCredit(_ rest: Double?, creditPoints: Double) -> Double? {
        guard let rest else { return nil }
        let credit = min(max(creditPoints, 0), NSDRCredit.dailyCapPoints)
        guard credit > 0 else { return rest }
        return (min(rest + credit, 100.0) * 100.0).rounded() / 100.0
    }
}
