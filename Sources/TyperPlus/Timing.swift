import Foundation

/// Generates the temporal texture of typing: inter-key intervals, dwell, pauses,
/// and slow session drift. Stateful (AR(1) residuals, keystroke count, warm-up),
/// created fresh per run, parameterised by a stable per-"person" `Persona`.
///
/// Design (RESEARCH.md §2–§4 + Round-1 review):
///  • IKI = ex-Gaussian × per-digraph factor × hand bias × AR(1) × drift — right-
///    skewed, serially correlated, non-stationary. The per-digraph factor models
///    finger/hand structure (incl. a same-finger penalty) plus a stable per-pair
///    offset, so the conditional IKI|bigram is a smooth mixture of per-pair
///    distributions rather than a 4-level step (defeats QUACK Cond-Bin).
///  • Dwell is an INDEPENDENT per-key draw (frequent keys held briefer), weakly
///    coupled to the local flight and carried by its own AR(1) — giving the joint
///    HT–FT structure detectors look for, without deriving dwell from the IKI.
///  • Persona scales speed/spread/dwell/hand-bias/error-rate per "person."
final class Timing {

    private let p: TypingProfile
    private let rng: RNG
    private let persona: Persona

    // Persona-effective IKI parameters.
    private let muEff: Double
    private let sigmaEff: Double
    private let tauEff: Double
    private let baselineIKI: Double   // nominal mean, for the dwell joint coupling

    // Persona-effective dwell normalisation (per-key table → target mean).
    private let dwellScaleToMean: Double

    private var arIKI = 0.0
    private var arDwell = 0.0
    private var keystrokeIndex = 0
    private var elapsedMinutes = 0.0
    private var lastIKI = 0.0
    private var fatigueWalk = 0.0     // bounded random-walk session drift (non-stationary)
    private var lastIKIz = 0.0        // log residual of the last IKI, for HT-FT coupling

    init(profile: TypingProfile, rng: RNG, persona: Persona) {
        self.p = profile
        self.rng = rng
        self.persona = persona
        self.muEff = profile.ikiMu * persona.ikiScale
        self.sigmaEff = profile.ikiSigma * persona.cvScale
        self.tauEff = profile.ikiTau * persona.ikiScale * persona.cvScale
        self.baselineIKI = muEff + tauEff
        self.dwellScaleToMean = (profile.dwellMean / KeyMap.dwellReferenceMean) * persona.dwellScale
    }

    private static let topBigrams: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd"
    ]

    /// Per-digraph multiplier on the base IKI. Finger/hand structure + a stable
    /// per-pair offset so identical bigrams share a conditional mean but different
    /// bigrams within a class don't collapse to one value.
    private func bigramMultiplier(_ prev: Character?, _ cur: Character) -> Double {
        guard let prev = prev else { return 1.10 }     // word/first key: slower onset
        let a = Character(prev.lowercased())
        let b = Character(cur.lowercased())
        guard a.isLetter && b.isLetter else { return 1.0 }

        // Stable per-pair mean offset + fresh per-instance jitter, so the conditional
        // IKI|bigram is a smooth distribution, not a point (defeats QUACK Cond-Bin).
        let pairFactor = 1 + perPairOffset(a, b) + rng.normal(0, 0.03)

        if a == b { return 0.74 * max(0.4, pairFactor) }   // letter repetition

        var m: Double
        if KeyMap.sameFinger(a, b) {
            m = 1.38                                   // same-finger: the awkward, slow class
        } else {
            let ha = KeyMap.hand(of: a), hb = KeyMap.hand(of: b)
            if ha != hb && ha != .neutral && hb != .neutral {
                m = 0.84                               // hand alternation
            } else {
                m = 0.92                               // same hand, different finger
            }
        }
        if Self.topBigrams.contains("\(a)\(b)") { m *= 0.90 }
        return m * max(0.4, pairFactor)
    }

    /// Deterministic small per-pair offset in ~[-0.06, 0.06] (stable per bigram).
    private func perPairOffset(_ a: Character, _ b: Character) -> Double {
        // Finer per-pair mean lattice (~97 buckets, ±8%) so the conditional IKI|bigram
        // is a rich per-pair mean, not a coarse 13-level step.
        let h = (Int(a.asciiValue ?? 97) &* 131 &+ Int(b.asciiValue ?? 97)) % 97
        return (Double(h) / 97.0 - 0.5) * 0.16
    }

    // MARK: Key rollover (negative flight) — calibrated to typing speed.

    /// P(rollover) rises with WPM (Dhakal: 7.6% slow → 25% mid → 50% fast, r=0.73).
    var rolloverProb: Double {
        let wpm = 60000.0 / (max(baselineIKI, 1) * 5.0)
        return max(0.05, min(0.55, (wpm - 8) / 160.0))
    }

    func shouldRollover() -> Bool { rng.bernoulli(rolloverProb) }

    /// Down-to-down gap for a rolled-over (overlapped) key pair. It is a compressed,
    /// jittered fraction of the STRUCTURED iki, so it keeps the ex-Gaussian skew, the
    /// AR(1) tempo and the per-bigram conditional mean instead of a flat uniform block
    /// (a uniform IKI is the #1 biometric tell). Always faster than the normal gap, and
    /// reflected off the floor so fast pairs don't pile up exactly at the floor.
    func rolloverGapMs(from iki: Double) -> Double {
        let g = iki * rng.uniform(0.60, 0.85)
        return g >= p.ikiFloor ? g : p.ikiFloor + (p.ikiFloor - g)
    }

    private func handBias(_ ch: Character) -> Double {
        switch KeyMap.hand(of: ch) {
        case .left: return persona.leftBias
        case .right: return persona.rightBias
        case .neutral: return 1.0
        }
    }

    /// Is `cur` the first key of a new word? True at text start and after any
    /// non-word boundary (space, newline, tab, punctuation) — i.e. the only place a
    /// *cognitive* (heavy) hesitation is plausible. Mid-word keys are never wordStart.
    private func isWordStart(prev: Character?, cur: Character) -> Bool {
        guard cur.isLetter || cur.isNumber else { return false }
        guard let prev = prev else { return true }      // very first key
        return !(prev.isLetter || prev.isNumber)        // prev was a boundary
    }

    /// Down-to-down inter-key interval (ms). Dwell overlaps this independently.
    func interKeyMs(prev: Character?, cur: Character) -> Double {
        keystrokeIndex += 1
        let wordStart = isWordStart(prev: prev, cur: cur)
        var ms = rng.exGaussian(mu: muEff, sigma: sigmaEff, tau: tauEff, floor: p.ikiFloor)
        ms *= bigramMultiplier(prev, cur)
        ms *= handBias(cur)

        // Shared latent "tempo" — a DOMINANT AR(1) so it owns a real share (~15%) of the
        // log-IKI variance; otherwise the independent factors dilute it and the emitted
        // lag-1 autocorrelation collapses to the naive-bot ~0. phi 0.62 → human r1 ~0.09.
        arIKI = 0.62 * arIKI + 0.21 * rng.standardNormal()
        ms *= exp(arIKI)

        if keystrokeIndex < 60 {
            let t = Double(keystrokeIndex) / 60.0
            ms *= 1.0 + (p.warmupFactor - 1.0) * (1.0 - t)
        }
        // Non-stationary session mean via a bounded slow random walk (drift + noise),
        // not a deterministic straight ramp.
        fatigueWalk += rng.normal(p.fatiguePerMinute * (ms / 60000.0), 0.0018)
        fatigueWalk = max(-0.06, min(0.25, fatigueWalk))
        ms *= 1.0 + fatigueWalk

        // Cognitive hesitation: a heavy right-tail draw folded into the IKI body (human
        // IKI skew ≈ 4, high kurtosis). It models a PLANNING pause before the next word, so
        // it may fire ONLY when `cur` begins a new word — never mid-word, where a 3.2× of a
        // slow base would stall h-e-l-l⋯o. Probability is profile-driven (mode-agnostic):
        // a future Max Speed sets hesitationProb=0; Ultra Fast keeps a small one.
        // CAPPED at 3.2× so a tight base can't spawn freak 6× outliers past the human
        // kurtosis ceiling (~40); the heavy tail stays, the freak tail goes. NOTE: this is
        // independent of boundaryExtraMs() (added by the planner only after a space/.,;:!?),
        // so there is no double-count — that adds the *gap* at the boundary, this adds the
        // *onset cost* of the first key of the next word.
        if wordStart, rng.bernoulli(p.hesitationProb) {
            ms *= min(rng.logNormal(median: 1.6, sigma: 0.45), 3.2)
        } else if !wordStart, rng.bernoulli(p.midWordJitterProb) {
            // Mid-word keys keep only a SMALL natural variation (tight cap, never a stall).
            ms *= min(rng.logNormal(median: 1.18, sigma: 0.22), 1.6)
        }

        // Soft floor: the sub-1.0 bigram/hand multipliers above can push a draw below the
        // floor, and a hard max() would clamp those to a spike exactly at the floor — itself
        // a synthetic tell. Reflect sub-floor mass back above the floor (as exGaussian does)
        // so the low tail stays smooth with no pile-up.
        if ms < p.ikiFloor { ms = p.ikiFloor + (p.ikiFloor - ms) }
        elapsedMinutes += ms / 60000.0
        lastIKI = ms
        lastIKIz = log(ms / baselineIKI)
        return ms
    }

    /// Key hold time (ms): per-key base (frequent keys briefer), weakly shorter when
    /// the surrounding typing is fast (joint HT–FT structure), carried by its own
    /// AR(1), independent of the IKI magnitude itself.
    func dwellMs(for ch: Character, iki: Double) -> Double {
        var d = KeyMap.dwellBase(for: ch) * dwellScaleToMean
        arDwell = 0.15 * arDwell + 0.10 * rng.standardNormal()
        d *= exp(arDwell * 0.5)

        // Joint HT–FT structure: dwell noise is negatively correlated with the flight
        // residual (a Cholesky-style 2-var mix), the exact bivariate a QUACK Emp-Pair
        // model expects — not a fixed deterministic coupling.
        let rho = -0.22
        let z = rng.standardNormal()
        let coupled = rho * tanh(lastIKIz) + (1 - rho * rho).squareRoot() * z
        d += coupled * p.dwellSD * 0.9   // within-key HT SD ≈ human ~24ms (Dhakal 23.88)

        return max(p.dwellMin, min(p.dwellMax, d))
    }

    /// Shift / modifier keys are held longer than letters.
    func shiftDwellMs() -> Double {
        rng.truncatedNormal(mean: p.dwellMean * 1.35, sd: p.dwellSD * 1.1,
                            lo: p.dwellMin, hi: p.dwellMax * 1.4)
    }

    func backspaceGapMs() -> Double {
        // Backspace bursts run a touch faster than forward typing, but for the human-paced
        // modes they must never cross the 45ms physiological floor (the #1 bot tell — and a
        // detector measures ALL keystrokes, deletes included). Max Speed is intentionally
        // inhuman (tiny ikiFloor) and excluded from that guard, so it stays fast.
        let bsFloor = max(p.ikiFloor * 0.7, min(p.ikiFloor, 45))
        return rng.exGaussian(mu: muEff * 0.55, sigma: sigmaEff * 0.5, tau: tauEff * 0.4,
                              floor: bsFloor)
    }

    func backspaceDwellMs() -> Double {
        rng.truncatedNormal(mean: 42 * persona.dwellScale, sd: 7, lo: 26, hi: 80)
    }

    func arrowGapMs() -> Double { rng.logNormal(median: 55, sigma: 0.35) }

    // MARK: Boundary & planning pauses (added on top of the IKI), all right-skewed.

    func boundaryExtraMs(after ch: Character, next: Character?) -> Double {
        var extra = 0.0
        if ch == "." || ch == "!" || ch == "?" {
            let med = (p.sentencePauseMin + p.sentencePauseMax) / 2
            extra += clampPause(rng.logNormal(median: med, sigma: 0.45), p.sentencePauseMin * 0.5, p.sentencePauseMax * 1.8)
        } else if ch == " " {
            extra += max(p.wordPauseMin, rng.logNormal(median: p.wordPauseMedian, sigma: 0.5))
        } else if ch == "," || ch == ";" || ch == ":" {
            extra += rng.logNormal(median: p.wordPauseMedian * 1.1, sigma: 0.5)
        }
        if ch == " ", rng.bernoulli(p.thinkingPauseProb) {
            let med = (p.thinkingPauseMin + p.thinkingPauseMax) / 2
            extra += clampPause(rng.logNormal(median: med, sigma: 0.5), p.thinkingPauseMin * 0.6, p.thinkingPauseMax * 1.6)
        }
        return extra
    }

    private func clampPause(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }

    func postErrorMultiplier() -> Double { p.postErrorSlowdown }
}
