import Foundation

// NSDRCatalog.swift — the guided NSDR (Non-Sleep Deep Rest) recordings the NSDR screen can play.
// Created: 2026-11-01
// Last updated: 2026-11-01
//
// Every entry is a public YouTube upload that allows embedding, played through YouTube's own iframe
// player. NOOP ships NO audio: the recordings are © Scicomm Media LLC (Dr. Andrew Huberman), so the
// catalog holds video ids, titles and the measured length, nothing else. Lengths were read from each
// video's public watch page on 2026-11-01 and are the "nominal length" the rest credit is measured
// against (see `NSDRCredit`). Pure + unit-tested.

/// One guided NSDR recording, addressed by its YouTube video id.
public struct NSDRRecording: Equatable, Sendable, Identifiable {
    /// The 11-character YouTube video id.
    public let id: String
    public let title: String
    /// Who published the upload (shown under the title so the source is never ambiguous).
    public let channel: String
    /// Full length of the recording in seconds.
    public let nominalSeconds: Double

    public init(id: String, title: String, channel: String, nominalSeconds: Double) {
        self.id = id; self.title = title; self.channel = channel; self.nominalSeconds = nominalSeconds
    }

    /// The public watch page, the fallback when the embedded player refuses to play.
    public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

public enum NSDRCatalog {

    /// The default pool, in a stable order. A random pick draws from all of them.
    public static let all: [NSDRRecording] = [
        NSDRRecording(
            id: "KHIbgSN2qAU",
            title: "Huberman Lab NSDR · 10 min (2024)",
            channel: "Huberman Lab Clips",
            nominalSeconds: 642
        ),
        NSDRRecording(
            id: "kWnl1fiWhFY",
            title: "Huberman Lab NSDR · 10 min (2024, audio)",
            channel: "Dr. Andrew Huberman · Topic",
            nominalSeconds: 638
        ),
        NSDRRecording(
            id: "AKGrmY8OSHM",
            title: "Huberman NSDR · 10 min (2022 script)",
            channel: "Virtusan",
            nominalSeconds: 649
        ),
    ]

    public static func recordingById(_ id: String) -> NSDRRecording? {
        all.first { $0.id == id }
    }

    /// A random recording from the pool. `excluding` (the one playing now) is never returned while the
    /// pool holds anything else, so "Next" always switches recordings. `roll` maps to an index in the
    /// candidate list; it is injectable so tests can pin the draw.
    public static func randomPick(excluding current: String? = nil,
                                  roll: (Int) -> Int = { Int.random(in: 0..<$0) }) -> NSDRRecording {
        let candidates = all.filter { $0.id != current }
        let pool = candidates.isEmpty ? all : candidates
        let i = roll(pool.count)
        return pool[min(max(i, 0), pool.count - 1)]
    }
}

/// Counts how long the user actually LISTENED, from the player's own playback clock rather than wall
/// time: a paused, buffering or stopped player adds nothing, and a seek (a jump in the playback position)
/// adds nothing either, so scrubbing to the end can't claim a full session. Fed one observation per
/// player tick. Pure.
public struct NSDRListenTracker: Equatable, Sendable {
    /// The largest forward step between two ticks still counted as listening (seconds). Ticks arrive
    /// about once a second; anything larger is a seek, not playback.
    public static let maxStepSeconds: Double = 3.0

    public private(set) var listenedSeconds: Double = 0
    private var lastPosition: Double?

    public init() {}

    /// Record one tick: the player's current position (seconds into the recording) and whether it is
    /// playing. Only a small forward step between two PLAYING ticks counts.
    public mutating func observe(position: Double, isPlaying: Bool) {
        guard isPlaying, position.isFinite else { lastPosition = nil; return }
        if let last = lastPosition {
            let step = position - last
            if step > 0, step <= Self.maxStepSeconds { listenedSeconds += step }
        }
        lastPosition = position
    }
}
