import Foundation

// CircadianEngine.swift — on-device body-clock phase estimate + a jet-lag / shift-work LIGHT & SLEEP-TIMING
// plan. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of published methods:
//   • Single-component COSINOR (Halberg's cosine fit) over the rest-activity rhythm — the standard
//     actigraphy method for estimating circadian phase (the acrophase = peak-activity clock time) and
//     amplitude. We fit M + A·cos(2π(t − φ)/24) by ordinary least squares on cos/sin regressors and
//     recover amplitude + phase. The accelerometer rest-activity rhythm is the primary phase signal; the
//     nightly skin-temperature minimum corroborates it (wrist skin temperature runs broadly ANTI-phase to
//     core temperature, and the core-body-temperature minimum, CBTmin, is the canonical phase marker
//     sitting ~2–3 h before habitual wake).
//   • Phase-response-curve (PRC) DIRECTION rule for the advisory: to ADVANCE the clock (eastward travel /
//     an earlier shift) → bright light in the morning, dim evenings, earlier sleep, stepped ~1 h/day; to
//     DELAY (westward / a later shift) → bright light in the evening, the reverse.
//
// WELLNESS / BEHAVIOURAL AWARENESS ONLY — APPROXIMATE. Light + sleep TIMING only. The engine NEVER
// prescribes melatonin or any supplement/drug, and never guarantees an outcome ("consider"/"aim for",
// never "you must"). Irregular schedules get an honest "your rhythm is hard to read right now."
public enum CircadianEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Minimum days with a usable activity profile before a stable cosinor fit is reported.
    public static let minDaysForFit: Int = 7
    /// Days at/above which the fit reads as full-confidence.
    public static let goodDaysForFit: Int = 14
    /// A cosinor fit with amplitude below this fraction of the mesor is "arrhythmic" — too flat to phase.
    ///
    /// #982 — RELATIVE, applied to a signal (mean HR, see `ActivityBin`) whose mesor is ~45-75 bpm rather
    /// than the near-zero mesor a motion volume would have. So the effective bar is an absolute amplitude
    /// of `0.10 x mesor`: about 6.5 bpm at a 65 bpm mesor, about 4.5 bpm at 45. It scales WITH the mesor,
    /// so a low-resting wearer faces a LOWER absolute bar, not a higher one — the opposite of the concern
    /// raised in #982, which assumed the gate penalises the fittest.
    ///
    /// The VALUE is still not re-tuned — every candidate remains unvalidated. What changed is the SHAPE:
    /// `minAbsoluteAmplitudeBpm` now passes a swing large enough in bpm regardless of mesor. This note
    /// asked for "a wearer whose amplitude is disproportionately small for their mesor — an n=1
    /// observation" before that could happen, and one arrived: 5.5 bpm on a 74.7 bpm mesor with a coherent
    /// acrophase. "Nobody is currently silenced by it" was true when written and is no longer.
    /// `CircadianEngineTests` pins what the gate costs at each mesor so the trade stays visible.
    public static let minRelativeAmplitude: Double = 0.10
    /// Absolute amplitude (bpm) that reads as rhythmic whatever the mesor — the relative bar's escape hatch.
    ///
    /// The relative test scales the requirement WITH resting HR, so the identical swing is accepted on one
    /// body and refused on another: 5.5 bpm passes at a 55 bpm mesor and fails at 74.7. That is not a
    /// judgement about the rhythm, it is a judgement about the baseline, and a measured wearer sat exactly
    /// there — 5.5 bpm on a 74.7 bpm mesor, acrophase 16.1 h, a coherent afternoon peak, which is a
    /// textbook phase rather than noise. `minRelativeAmplitude`'s own note called for precisely that
    /// observation ("a wearer whose amplitude is disproportionately small for their mesor") before the
    /// shape could be revisited.
    ///
    /// 4.5 bpm is NOT a new tuning constant: it is the absolute amplitude the relative gate ALREADY
    /// accepts at the bottom of the ~45-75 bpm mesor range it was described against. The rule this
    /// encodes is internal consistency — an amplitude good enough for some wearer is good enough for all
    /// — so the change is strictly more permissive and no one who reads rhythmic today stops.
    public static let minAbsoluteAmplitudeBpm: Double = 4.5
    /// Max clock-shift the planner steps per day (hours) — the well-established ~1 h/day re-entrainment rate.
    public static let maxShiftPerDayHours: Double = 1.0
    /// CBTmin sits roughly this many hours before habitual wake; used to translate the activity acrophase
    /// into an estimated temperature-minimum clock time when the thermal series is thin.
    public static let cbtMinBeforeWakeHours: Double = 2.5
    /// Activity acrophase (peak activity) sits roughly this many hours after CBTmin in a typical day — the
    /// offset used to convert the cosinor acrophase into an estimated temperature-minimum time.
    ///
    /// 10 h, not the 12 h ("half a day") this started as. The signal is pooled mean HEART RATE (see
    /// `ActivityBin`), and its cosinor peak is not the mirror image of CBTmin: it is the centre of mass
    /// of the WAKING day, pulled earlier by the morning rise, about seven hours after wake. A
    /// 23:00-07:00 sleeper peaks near 14:15, so 12 h put CBTmin at 02:15, wake at 04:45 and a suggested
    /// bedtime of 20:45, where the real CBTmin sits ~05:00. The pipeline adds half an hour of its own:
    /// `hrBuckets` labels each hourly mean by the hour it STARTS, so every bin reads 30 min early. 10 h
    /// absorbs both and lands that sleeper at 04:15 / 06:45 / 22:45; a 01:00-09:00 sleeper moves with it.
    /// `CircadianEngineTests` pins both on a realistic pooled HR profile. Still a population constant:
    /// it moves every wearer's estimate by the same amount and personalises nothing.
    public static let acrophaseAfterCbtMinHours: Double = 10.0
    /// Population-typical wake hour, used ONLY to place the chronotype reference point.
    ///
    /// `offsetVsScheduleMinutes` compares the clock to the USER'S OWN schedule, so it cannot name a
    /// chronotype: someone reliably asleep 03:00-11:00 has an offset near zero and would read
    /// "intermediate" while being strongly evening-type. A named lean needs an ABSOLUTE phase, so it is
    /// bucketed from `tempMinHour` against a population reference instead.
    public static let chronotypeReferenceWakeHour: Double = 7.0
    /// Half-width of the "intermediate" band around the reference CBTmin, in hours.
    ///
    /// Deliberately wide. `tempMinHour` is derived from an activity cosinor (`acrophase - 10 h`) unless a
    /// measured `observedTempMinHour` is supplied, and NO production caller supplies one today — so this
    /// is a lean inferred from movement, not a thermal measurement. A one-hour band either side keeps the
    /// three buckets coarse enough to be honest about that.
    public static let chronotypeBandHours: Double = 1.0
    /// Tonight-plan offsets, in hours from tonight's ideal WAKE (W) or FALL-ASLEEP (F) time.
    ///
    /// Behavioural timing only — light, caffeine and lamp habits, never a supplement or drug. Morning
    /// light half an hour to an hour after waking is the advancing side of the light PRC; a first coffee
    /// ~90 min after waking is the common "let the morning cortisol rise run first" habit; caffeine's
    /// ~5 h half-life is why the last cup is a RANGE 8-10 h before sleep rather than one cut-off; dim
    /// lamps for the last two hours protect the body clock's own evening wind-down. Population rules of
    /// thumb, so the card words them as "aim for", never as a prescription.
    public static let morningLightStartAfterWakeHours: Double = 0.5
    public static let morningLightEndAfterWakeHours: Double = 1.0
    public static let firstCaffeineAfterWakeHours: Double = 1.5
    public static let lastCaffeineEarliestBeforeSleepHours: Double = 10.0
    public static let lastCaffeineLatestBeforeSleepHours: Double = 8.0
    public static let dimLightsBeforeSleepHours: Double = 2.0
    /// Fewest main-sleep wakes a spread is reported from. Three points have a mean, but one odd morning
    /// then moves the spread by a third; four is the smallest week that reads as a habit.
    public static let minWakesForSpread: Int = 4

    // MARK: - Inputs

    /// One per-hour rest-activity sample: the local clock hour (0..<24, may be fractional) and the
    /// rhythm signal in that bin. Higher = more active.
    ///
    /// #982 — this said "motion volume (e.g. StepsEstimateEngine.dayMotionIntensity per hour)". It has
    /// never been fed that. The only production caller pools per-hour MEAN HEART RATE in bpm
    /// (`AppModel.swift`, `sums[hour] += b.bpm`), and that is the right choice on this hardware: WHOOP 4.0
    /// motion is too sparse to stage sleep at all (#345), while HR carries a strong circadian rhythm.
    ///
    /// The domain matters because `minRelativeAmplitude` gates on `amplitude / |mesor|`, and HR arrives
    /// with a large DC offset that motion does not have — see that constant for what the gate actually
    /// costs in bpm.
    public struct ActivityBin: Equatable, Sendable {
        public let hour: Double
        public let activity: Double
        public init(hour: Double, activity: Double) {
            self.hour = hour; self.activity = activity
        }
    }

    // MARK: - Cosinor

    /// A single-component cosinor fit: y ≈ mesor + amplitude·cos(2π(hour − acrophaseHours)/24).
    public struct CosinorFit: Equatable, Sendable {
        public let mesor: Double         // rhythm-adjusted mean
        public let amplitude: Double     // half the peak-to-trough swing (≥ 0)
        public let acrophaseHours: Double // clock hour of the activity PEAK, in [0, 24)
        public init(mesor: Double, amplitude: Double, acrophaseHours: Double) {
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseHours = acrophaseHours
        }
    }

    /// Fit a single 24 h cosine to the (hour, activity) bins by ordinary least squares.
    ///
    /// Model: y = M + β·cos(ωt) + γ·sin(ωt), ω = 2π/24.
    ///   amplitude  = √(β² + γ²)
    ///   acrophase  = atan2(γ, β) converted to a clock hour in [0, 24); this is the time of the PEAK.
    /// Returns nil with fewer than 3 distinct points or a degenerate design (zero variance).
    public static func cosinor(_ bins: [ActivityBin]) -> CosinorFit? {
        guard bins.count >= 3 else { return nil }
        let w = 2.0 * Double.pi / 24.0
        let n = Double(bins.count)

        var sumY = 0.0, sumC = 0.0, sumS = 0.0
        var sumCC = 0.0, sumSS = 0.0, sumCS = 0.0
        var sumYC = 0.0, sumYS = 0.0
        for b in bins {
            let c = cos(w * b.hour)
            let s = sin(w * b.hour)
            let y = b.activity
            sumY += y; sumC += c; sumS += s
            sumCC += c * c; sumSS += s * s; sumCS += c * s
            sumYC += y * c; sumYS += y * s
        }

        // Solve the 3×3 normal equations for (M, β, γ) via Cramer's rule.
        // [ n     sumC   sumS ] [M] = [sumY ]
        // [ sumC  sumCC  sumCS] [β] = [sumYC]
        // [ sumS  sumCS  sumSS] [γ] = [sumYS]
        let a11 = n,    a12 = sumC,  a13 = sumS
        let a21 = sumC, a22 = sumCC, a23 = sumCS
        let a31 = sumS, a32 = sumCS, a33 = sumSS
        let det = a11 * (a22 * a33 - a23 * a32)
                - a12 * (a21 * a33 - a23 * a31)
                + a13 * (a21 * a32 - a22 * a31)
        guard abs(det) > 1e-12 else { return nil }

        let detM = sumY * (a22 * a33 - a23 * a32)
                 - a12  * (sumYC * a33 - a23 * sumYS)
                 + a13  * (sumYC * a32 - a22 * sumYS)
        let detB = a11 * (sumYC * a33 - a23 * sumYS)
                 - sumY * (a21 * a33 - a23 * a31)
                 + a13  * (a21 * sumYS - sumYC * a31)
        let detG = a11 * (a22 * sumYS - sumYC * a32)
                 - a12 * (a21 * sumYS - sumYC * a31)
                 + sumY * (a21 * a32 - a22 * a31)

        let m = detM / det
        let beta = detB / det
        let gamma = detG / det

        let amplitude = (beta * beta + gamma * gamma).squareRoot()
        // Peak time: cos(ω(t − φ)) is maximal when ω(t − φ) = 0, i.e. φ where β·cos+γ·sin peaks.
        var phase = atan2(gamma, beta) / w           // hours
        phase = phase.truncatingRemainder(dividingBy: 24.0)
        if phase < 0 { phase += 24.0 }
        return CosinorFit(mesor: m, amplitude: amplitude, acrophaseHours: phase)
    }

    // MARK: - Phase estimate

    public enum PhaseConfidence: String, Equatable, Sendable, Codable {
        case unreadable     // too few days / arrhythmic — "hard to read right now"
        case wide           // a fit, but thin data → wide band
        case solid          // a stable fit over enough days
    }

    public struct PhaseEstimate: Equatable, Sendable {
        /// Estimated clock hour of the body-clock temperature minimum, in [0, 24).
        public let tempMinHour: Double
        /// Estimated activity acrophase (peak activity clock hour).
        public let acrophaseHours: Double
        /// Signed minutes the body clock leads (−) or lags (+) the user's own sleep schedule. Positive =
        /// the clock is LATER than the schedule implies (a "night-owl lean").
        public let offsetVsScheduleMinutes: Double
        public let confidence: PhaseConfidence
        public let note: String
        public init(tempMinHour: Double, acrophaseHours: Double, offsetVsScheduleMinutes: Double,
                    confidence: PhaseConfidence, note: String) {
            self.tempMinHour = tempMinHour; self.acrophaseHours = acrophaseHours
            self.offsetVsScheduleMinutes = offsetVsScheduleMinutes
            self.confidence = confidence; self.note = note
        }
    }

    /// Estimate the body-clock phase from a pooled activity profile and the user's habitual wake time.
    ///
    /// - Parameters:
    ///   - bins: pooled per-hour activity over the trailing window.
    ///   - daysObserved: distinct days backing the profile (drives confidence).
    ///   - habitualWakeHour: the user's typical wake clock hour (for the schedule-offset comparison).
    ///   - observedTempMinHour: optional measured nightly temp-minimum clock hour; when present it
    ///     corroborates / overrides the activity-derived estimate (the pillar's own signal).
    public static func estimatePhase(bins: [ActivityBin],
                                     daysObserved: Int,
                                     habitualWakeHour: Double,
                                     observedTempMinHour: Double? = nil) -> PhaseEstimate? {
        guard let fit = cosinor(bins) else { return nil }

        let relativeAmplitude = fit.mesor != 0 ? fit.amplitude / abs(fit.mesor) : 0
        // Rhythmic on EITHER measure: a proportional swing, or an absolute one large enough to read on
        // any baseline. See `minAbsoluteAmplitudeBpm` for why the relative test alone was self-inconsistent.
        let rhythmic = relativeAmplitude >= minRelativeAmplitude || fit.amplitude >= minAbsoluteAmplitudeBpm
        if daysObserved < minDaysForFit || !rhythmic {
            // A reading is returned, but flagged unreadable so the surface says "hard to read right now."
            let tmin = observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tempMinHour: tmin, acrophaseHours: fit.acrophaseHours,
                                 offsetVsScheduleMinutes: 0, confidence: .unreadable,
                                 note: "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
        }

        // Activity-derived temp-minimum ≈ acrophase − `acrophaseAfterCbtMinHours` (see that constant for why
        // the HR peak sits about ten hours, not half a day, after CBTmin).
        let derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        let tempMinHour = observedTempMinHour ?? derivedTempMin

        // A perfectly entrained clock has CBTmin ~cbtMinBeforeWakeHours before wake. The offset is how far
        // the ESTIMATED temp-minimum sits from that ideal, in minutes (signed; + = clock later than schedule).
        let idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        let offsetHours = signedHourDelta(from: idealTempMin, to: tempMinHour)
        let offsetMinutes = offsetHours * 60.0

        // SOLID means strong on BOTH axes, not just enough days. A rhythm admitted by
        // `minAbsoluteAmplitudeBpm` alone is real but modest, and a smaller swing pins its acrophase less
        // tightly — so it stays `.wide`. That matters because `.wide` is what withholds `chronotype`,
        // which names a category off exactly that acrophase: widening the readable gate should give more
        // people a body clock, not give a thinner fit a firmer label.
        let confidence: PhaseConfidence =
            (daysObserved >= goodDaysForFit && relativeAmplitude >= minRelativeAmplitude) ? .solid : .wide
        let lean: String
        if offsetMinutes > 20 { lean = "later (a night-owl lean)" }
        else if offsetMinutes < -20 { lean = "earlier (a morning-lark lean)" }
        else { lean = "well-aligned with your schedule" }
        let note = "Your body clock looks \(lean)."

        return PhaseEstimate(tempMinHour: tempMinHour, acrophaseHours: fit.acrophaseHours,
                             offsetVsScheduleMinutes: offsetMinutes, confidence: confidence, note: note)
    }

    // MARK: - Jet-lag / shift planner

    public enum ShiftDirection: String, Equatable, Sendable, Codable {
        case advance   // move the clock EARLIER (eastward travel / earlier shift)
        case delay     // move the clock LATER (westward travel / later shift)
        case none      // no meaningful shift required
    }

    /// One day of the re-entrainment plan: when to seek bright light, when to keep it dim, and the target
    /// sleep window — light + timing only, never a supplement.
    public struct DayPlan: Equatable, Sendable {
        public let dayIndex: Int               // 1-based
        public let brightLightStartHour: Double
        public let brightLightEndHour: Double
        public let dimFromHour: Double
        public let targetSleepHour: Double
        public let targetWakeHour: Double
        public let guidance: String
        public init(dayIndex: Int, brightLightStartHour: Double, brightLightEndHour: Double,
                    dimFromHour: Double, targetSleepHour: Double, targetWakeHour: Double, guidance: String) {
            self.dayIndex = dayIndex
            self.brightLightStartHour = brightLightStartHour; self.brightLightEndHour = brightLightEndHour
            self.dimFromHour = dimFromHour
            self.targetSleepHour = targetSleepHour; self.targetWakeHour = targetWakeHour
            self.guidance = guidance
        }
    }

    public struct JetLagPlan: Equatable, Sendable {
        public let direction: ShiftDirection
        public let totalShiftHours: Double     // absolute size of the shift to absorb
        public let estimatedDays: Int          // days to close it at the stepped rate
        public let days: [DayPlan]
        public let note: String
        public init(direction: ShiftDirection, totalShiftHours: Double, estimatedDays: Int,
                    days: [DayPlan], note: String) {
            self.direction = direction; self.totalShiftHours = totalShiftHours
            self.estimatedDays = estimatedDays; self.days = days; self.note = note
        }
    }

    /// Build a stepped light + sleep-timing plan to absorb a required clock shift.
    ///
    /// - Parameters:
    ///   - shiftHours: the phase shift required (hours). POSITIVE = need to ADVANCE (go earlier; eastward).
    ///     NEGATIVE = need to DELAY (go later; westward). For a destination time-zone, this is the
    ///     eastward(+)/westward(−) offset; for a shift-work change, the difference in target wake time.
    ///   - currentSleepHour / currentWakeHour: the user's current sleep window (clock hours).
    public static func planShift(shiftHours: Double,
                                 currentSleepHour: Double,
                                 currentWakeHour: Double) -> JetLagPlan {
        let magnitude = abs(shiftHours)
        guard magnitude >= 0.5 else {
            return JetLagPlan(direction: .none, totalShiftHours: 0, estimatedDays: 0, days: [],
                              note: "No meaningful body-clock shift needed - you're about aligned.")
        }

        let advancing = shiftHours > 0
        let direction: ShiftDirection = advancing ? .advance : .delay
        let days = Int(ceil(magnitude / maxShiftPerDayHours))

        var plan: [DayPlan] = []
        var cumulative = 0.0
        for i in 1...days {
            let stepRemaining = magnitude - cumulative
            let step = min(maxShiftPerDayHours, stepRemaining)
            cumulative += step
            // Advancing → shift the window EARLIER each day (subtract); delaying → LATER (add).
            let signed = advancing ? -cumulative : cumulative
            let sleep = wrap24(currentSleepHour + signed)
            let wake = wrap24(currentWakeHour + signed)

            let brightStart: Double
            let brightEnd: Double
            let dimFrom: Double
            let guidance: String
            if advancing {
                // ADVANCE: bright light in the MORNING just after the new wake; dim the evening.
                brightStart = wake
                brightEnd = wrap24(wake + 2.0)
                dimFrom = wrap24(sleep - 2.0)
                guidance = "Get bright light early after waking and keep the evening dim - this nudges your "
                    + "clock earlier. Aim for lights-out around \(clock(sleep))."
            } else {
                // DELAY: bright light in the EVENING; avoid bright morning light; go to bed later.
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light - this nudges "
                    + "your clock later. Aim for lights-out around \(clock(sleep))."
            }
            plan.append(DayPlan(dayIndex: i, brightLightStartHour: brightStart, brightLightEndHour: brightEnd,
                                dimFromHour: dimFrom, targetSleepHour: sleep, targetWakeHour: wake,
                                guidance: guidance))
        }

        let dirWord = advancing ? "earlier" : "later"
        let note = "Shifting your clock \(String(format: "%.1f", magnitude)) h \(dirWord), about "
            + "\(maxShiftPerDayHours == 1.0 ? "an hour" : "\(maxShiftPerDayHours) h") a day. Light and sleep "
            + "timing only."
        return JetLagPlan(direction: direction, totalShiftHours: magnitude, estimatedDays: days,
                          days: plan, note: note)
    }

    // MARK: - Helpers

    /// Wrap an hour value into [0, 24).
    static func wrap24(_ h: Double) -> Double {
        var x = h.truncatingRemainder(dividingBy: 24.0)
        if x < 0 { x += 24.0 }
        return x
    }

    /// A coarse, ABSOLUTE body-clock category: where the temperature minimum sits on the clock.
    ///
    /// NOT the "chronotype lean" wording used elsewhere. `estimatePhase` builds a `lean` string from
    /// `offsetVsScheduleMinutes` ("a night-owl lean"), and the v5 skin-temp design spec defines chronotype
    /// lean as "earlier/later than your sleep schedule implies" — both RELATIVE to the wearer's own
    /// schedule. This is relative to the CLOCK, and the two genuinely disagree: a consistent 03:00-11:00
    /// sleeper is well-aligned by the relative read and `.evening` by this one. Keep the vocabularies
    /// disjoint in anything user-facing, or the two readings look like a contradiction (#1409).
    ///
    /// Three buckets, not a score: the underlying phase estimate is an activity fit, and a finer grain
    /// would imply precision it does not have.
    public enum Chronotype: String, Equatable, Sendable, Codable {
        case morning        // CBTmin earlier than the population reference
        case intermediate
        case evening        // CBTmin later than the population reference
    }

    /// The reference CBTmin clock hour a lean is measured against: the population wake hour minus the
    /// same `cbtMinBeforeWakeHours` the phase estimator already uses, so the anchor moves with the
    /// engine's own model rather than being a second, independently-drifting constant.
    public static var chronotypeAnchorHour: Double {
        wrap24(chronotypeReferenceWakeHour - cbtMinBeforeWakeHours)
    }

    /// The chronotype-ideal sleep window for a night of `durationHours`, as clock hours.
    ///
    /// Anchored on the temperature minimum: a well-entrained sleeper wakes about `cbtMinBeforeWakeHours`
    /// after CBTmin, so the ideal wake is `tempMinHour + cbtMinBeforeWakeHours` and the ideal bedtime is
    /// that minus the night's own length.
    ///
    /// USING THE ACTUAL DURATION IS THE POINT. Giving the ideal arc the same length as the real one makes
    /// the comparison purely about PHASE — did you sleep at the right TIME — so a short night reads as
    /// aligned-but-short rather than as misaligned. Feeding a "needed" duration instead would fold two
    /// different failures into one arc and make a debt look like a body-clock problem.
    ///
    /// nil for a non-positive or impossible duration; a window longer than a day cannot be placed on a
    /// 24 h ring, and silently wrapping it would draw a full circle that means nothing.
    public static func idealSleepWindow(tempMinHour: Double,
                                        durationHours: Double) -> (bedHour: Double, wakeHour: Double)? {
        guard durationHours > 0, durationHours < 24 else { return nil }
        let wake = wrap24(tempMinHour + cbtMinBeforeWakeHours)
        return (bedHour: wrap24(wake - durationHours), wakeHour: wake)
    }

    /// Tonight's suggested wake and fall-asleep clock hours for someone who needs `needHours` of sleep.
    ///
    /// Same wake anchor as `idealSleepWindow` — `tempMinHour + cbtMinBeforeWakeHours` — but the bedtime is
    /// that wake minus the sleep NEED, not minus last night's length. The two answer different questions
    /// and must stay separate functions: the dial's ideal arc copies the actual night's duration so it
    /// compares PHASE alone, whereas "when should I sleep tonight" has to budget a full night, so it uses
    /// the same need the sleep-debt ledger measures against.
    ///
    /// nil for a non-positive or impossible need, on the same reasoning as `idealSleepWindow`.
    public static func idealTonight(tempMinHour: Double,
                                    needHours: Double) -> (fallAsleepHour: Double, wakeHour: Double)? {
        guard needHours > 0, needHours < 24 else { return nil }
        let wake = wrap24(tempMinHour + cbtMinBeforeWakeHours)
        return (fallAsleepHour: wrap24(wake - needHours), wakeHour: wake)
    }

    /// Tonight's times for a phase estimate, or nil when the fit cannot place them.
    ///
    /// `.unreadable` never gets times: its `tempMinHour` is a placeholder off a fit that failed the
    /// rhythm or day-count gate, and printing a clock time from it would state a precision the card's
    /// own "hard to read right now" message denies. `.wide` does get them — unlike a NAMED chronotype, a
    /// suggested time is the same continuous phase reading the dial already draws.
    public static func idealTonight(_ estimate: PhaseEstimate,
                                    needHours: Double) -> (fallAsleepHour: Double, wakeHour: Double)? {
        guard estimate.confidence != .unreadable else { return nil }
        return idealTonight(tempMinHour: estimate.tempMinHour, needHours: needHours)
    }

    /// The Tonight plan: when to seek light, when to have caffeine, when to dim the lamps — every time a
    /// clock hour in [0, 24), derived from tonight's ideal wake (W) and fall-asleep (F).
    public struct TonightPlan: Equatable, Sendable {
        /// The estimated body-temperature low the whole plan hangs off (the estimate's `tempMinHour`).
        public let tempMinHour: Double
        /// Morning light window: W + `morningLightStartAfterWakeHours` to W + `morningLightEndAfterWakeHours`.
        public let morningLightStartHour: Double
        public let morningLightEndHour: Double
        /// First coffee no earlier than W + `firstCaffeineAfterWakeHours`.
        public let firstCaffeineHour: Double
        /// Last coffee by somewhere in F − `lastCaffeineEarliestBeforeSleepHours` … F −
        /// `lastCaffeineLatestBeforeSleepHours`. A range, because caffeine sensitivity varies too much
        /// between people for one cut-off to be honest.
        public let lastCaffeineEarliestHour: Double
        public let lastCaffeineLatestHour: Double
        /// Dim the lights from F − `dimLightsBeforeSleepHours`.
        public let dimLightsHour: Double
        public init(tempMinHour: Double, morningLightStartHour: Double, morningLightEndHour: Double,
                    firstCaffeineHour: Double, lastCaffeineEarliestHour: Double, lastCaffeineLatestHour: Double,
                    dimLightsHour: Double) {
            self.tempMinHour = tempMinHour
            self.morningLightStartHour = morningLightStartHour; self.morningLightEndHour = morningLightEndHour
            self.firstCaffeineHour = firstCaffeineHour
            self.lastCaffeineEarliestHour = lastCaffeineEarliestHour
            self.lastCaffeineLatestHour = lastCaffeineLatestHour
            self.dimLightsHour = dimLightsHour
        }
    }

    /// Tonight's plan for a temperature minimum and a sleep need, anchored on `idealTonight`'s W and F.
    ///
    /// Built FROM `idealTonight`, never from its own copy of the arithmetic, so the plan and the "Tonight,
    /// aim for" line above it cannot disagree about W or F. Every time is wrapped into [0, 24): a 23:00
    /// temperature minimum puts W at 01:30 and F at 17:30, and the last-coffee range then sits at
    /// 07:30-09:30 the same morning rather than at a negative hour. nil exactly when `idealTonight` is.
    public static func tonightPlan(tempMinHour: Double, needHours: Double) -> TonightPlan? {
        guard let tonight = idealTonight(tempMinHour: tempMinHour, needHours: needHours) else { return nil }
        let w = tonight.wakeHour, f = tonight.fallAsleepHour
        return TonightPlan(tempMinHour: wrap24(tempMinHour),
                           morningLightStartHour: wrap24(w + morningLightStartAfterWakeHours),
                           morningLightEndHour: wrap24(w + morningLightEndAfterWakeHours),
                           firstCaffeineHour: wrap24(w + firstCaffeineAfterWakeHours),
                           lastCaffeineEarliestHour: wrap24(f - lastCaffeineEarliestBeforeSleepHours),
                           lastCaffeineLatestHour: wrap24(f - lastCaffeineLatestBeforeSleepHours),
                           dimLightsHour: wrap24(f - dimLightsBeforeSleepHours))
    }

    /// The plan for a phase estimate, or nil exactly when `idealTonight(_:needHours:)` is — so an
    /// `.unreadable` fit gets neither the Tonight line nor the plan, never one without the other.
    public static func tonightPlan(_ estimate: PhaseEstimate, needHours: Double) -> TonightPlan? {
        guard idealTonight(estimate, needHours: needHours) != nil else { return nil }
        return tonightPlan(tempMinHour: estimate.tempMinHour, needHours: needHours)
    }

    /// How far main-sleep wake times stray from their usual time: the mean absolute deviation, in
    /// minutes rounded to five, of `wakeHours` from their CIRCULAR mean.
    ///
    /// Circular because wake times live on a clock. Wakes at 23:50 and 00:10 are twenty minutes apart,
    /// and an arithmetic mean of 23.83 and 0.17 lands at noon and reports a twelve-hour spread. The mean
    /// is the direction of the summed unit vectors; each deviation is the shortest signed distance to it.
    ///
    /// Pass main-sleep wakes only — a nap's wake is not a habit to be consistent about. nil with fewer
    /// than `minWakesForSpread` wakes, or when the wakes cancel out round the clock and no mean exists.
    public static func wakeSpreadMinutes(wakeHours: [Double]) -> Int? {
        guard wakeHours.count >= minWakesForSpread else { return nil }
        let w = 2.0 * Double.pi / 24.0
        let n = Double(wakeHours.count)
        var sumX = 0.0, sumY = 0.0
        for h in wakeHours { sumX += cos(w * h); sumY += sin(w * h) }
        guard (sumX * sumX + sumY * sumY).squareRoot() / n > 1e-9 else { return nil }
        let mean = wrap24(atan2(sumY, sumX) / w)
        let deviation = wakeHours.reduce(0.0) { $0 + abs(signedHourDelta(from: mean, to: wrap24($1))) } / n
        return Int((deviation * 60.0 / 5.0).rounded()) * 5
    }

    /// Format a clock hour as "HH:MM" (24 h) rounded to the nearest five minutes.
    ///
    /// Five minutes for the same reason the dial caption rounds: the phase is an activity fit, and a
    /// to-the-minute time would imply a precision it does not carry. Rounds on the whole-day minute count
    /// and wraps it, so 23:58 reads 00:00 and never 24:00. Locale-free for cross-platform string parity.
    public static func clockToFiveMinutes(_ hour: Double) -> String {
        let fives = Int((wrap24(hour) * 60.0 / 5.0).rounded())
        let minutes = (fives * 5) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Signed hours the ACTUAL sleep window sits later (+) or earlier (−) than the chronotype-ideal one.
    ///
    /// Deliberately NOT `offsetVsScheduleMinutes`. That field compares the body clock to the wearer's own
    /// SCHEDULE; this compares the night actually slept to where the CLOCK wanted it. A dial that draws an
    /// actual arc against an ideal arc must caption itself with the distance between those two arcs, or
    /// the number contradicts the picture — the two disagree exactly when someone keeps a consistent
    /// schedule that does not suit their clock, which is the case the dial exists to show.
    ///
    /// Anchored on wake rather than bedtime because `idealSleepWindow` builds the ideal window from the
    /// wake end; comparing bedtimes would fold the night's DURATION into a phase reading.
    public static func sleepWindowOffsetHours(tempMinHour: Double, actualWakeHour: Double) -> Double {
        signedHourDelta(from: wrap24(tempMinHour + cbtMinBeforeWakeHours), to: wrap24(actualWakeHour))
    }

    /// Bucket an ABSOLUTE temperature-minimum clock hour into a lean.
    ///
    /// Compared CIRCULARLY. A `tempMinHour` of 23:30 is five hours BEFORE the 04:30 anchor — a strong
    /// morning lean — and a naive `23.5 > 5.5` would call it evening instead. Pure, so the boundaries are
    /// assertable without building a fit.
    public static func chronotype(tempMinHour: Double) -> Chronotype {
        let delta = signedHourDelta(from: chronotypeAnchorHour, to: wrap24(tempMinHour))
        if delta < -chronotypeBandHours { return .morning }
        if delta > chronotypeBandHours { return .evening }
        return .intermediate
    }

    /// The lean for a phase estimate, or nil when the fit is not strong enough to name one.
    ///
    /// Gated to `.solid` on purpose. `.wide` is a real fit on thin data and is fine for the continuous
    /// offset the card already shows, but a NAMED category reads as a fact about the person rather than a
    /// reading of the week, so it waits for the stronger tier. `.unreadable` never names one.
    public static func chronotype(_ estimate: PhaseEstimate) -> Chronotype? {
        guard estimate.confidence == .solid else { return nil }
        return chronotype(tempMinHour: estimate.tempMinHour)
    }

    /// Signed shortest delta in hours from `a` to `b` on the 24 h clock, in (−12, 12].
    static func signedHourDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 24.0)
        if d > 12.0 { d -= 24.0 }
        if d <= -12.0 { d += 24.0 }
        return d
    }

    /// Format a clock hour as "HH:MM" (24 h). Pure, locale-free for cross-platform string parity.
    static func clock(_ hour: Double) -> String {
        let h = wrap24(hour)
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60.0).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}
