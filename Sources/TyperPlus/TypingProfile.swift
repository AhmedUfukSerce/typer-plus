import Foundation

/// A typing "mode": a bundle of research-tuned parameters. Numbers trace to
/// RESEARCH.md §2 (anchored on Dhakal et al. 2018, 136M keystrokes).
///
/// The presets combine two axes:
///   • motor cadence (within-burst speed: IKI, dwell, rollover, errors), and
///   • wall-clock pacing (Max Stealth averages down to *composition* rate so the
///     Google Docs microsecond-timestamped changelog looks organically written).
struct TypingProfile {

    enum Mode: String, CaseIterable {
        case careful = "Careful"
        case ultraFast = "Ultra Fast"
        case maxSpeed = "Max Speed"
        case maxStealth = "Max Stealth"

        /// The single source of truth for a mode's speed read-out. Both the main-window card
        /// subtitle AND the floating bubble's compact tag derive from this, so changing the
        /// speed in ONE place updates everywhere (they used to be hardcoded separately and
        /// drifted — the bubble showed a stale "~1000 wpm").
        var speedLabel: String {
            switch self {
            case .careful:    return "~40 wpm"
            case .ultraFast:  return "~230 wpm"
            case .maxSpeed:   return "~800 wpm"
            case .maxStealth: return "composition pace"
            }
        }

        var subtitle: String {
            switch self {
            case .careful:    return "Slow and deliberate · \(speedLabel)"
            case .ultraFast:  return "Very fast, still human · \(speedLabel)"
            case .maxSpeed:   return "Fast, still flawed · \(speedLabel)"
            case .maxStealth: return "Docs-forensic safe · \(speedLabel)"
            }
        }
    }

    var mode: Mode

    // MARK: Inter-key interval (ex-Gaussian, ms). μ+τ ≈ mean IKI.
    var ikiMu: Double
    var ikiSigma: Double
    var ikiTau: Double
    var ikiFloor: Double          // physiological floor; <50ms is the #1 bot tell

    // MARK: Dwell / hold time (truncated-normal, ms) — independent of IKI.
    var dwellMean: Double
    var dwellSD: Double
    var dwellMin: Double
    var dwellMax: Double

    // Key overlap (rollover) is NOT a separate knob: it emerges naturally whenever a
    // drawn dwell exceeds the drawn down-to-down IKI, which reproduces the research
    // rollover rates per speed (≈25% natural, ≈45% fast) for free.

    // MARK: Serial structure / session drift.
    var arAlpha: Double           // lag-1 autocorrelation target (≤0.15)
    var arSigma: Double           // AR(1) innovation scale (log domain)
    var warmupFactor: Double      // first ~30s IKIs are this much slower
    var fatiguePerMinute: Double  // slow drift: fractional IKI rise per minute

    // MARK: Errors & corrections.
    var typoRate: Double          // probability a given char triggers a slip
    var uncorrectedResidue: Double // fraction of slips deliberately left in
    var immediateCorrectProb: Double // of corrected slips, fraction caught at once
    var postErrorSlowdown: Double // IKI multiplier on the key after a correction
    /// Whether this mode ever LEAVES a slip to fix later — i.e. delayed (look-ahead)
    /// typo correction AND the end-of-pass grammar review that jumps the caret all the
    /// way back. Max Speed is the ONLY mode that sets this false: it fixes mistakes
    /// immediately or not at all, never the go-back-at-the-end behavior.
    var delaysCorrections: Bool = true

    // MARK: Pauses (free-composition realism).
    var wordPauseMin: Double      // extra ms at a space (log-normal median band)
    var wordPauseMedian: Double
    var sentencePauseMin: Double  // extra ms after . ! ?
    var sentencePauseMax: Double
    var thinkingPauseProb: Double // chance a word boundary gets a long planning pause
    var thinkingPauseMin: Double
    var thinkingPauseMax: Double

    // MARK: Cognitive hesitation (heavy IKI tail — gated to WORD STARTS only).
    /// Per-key chance the FIRST key of a word carries a heavy (≤3.2×) onset hesitation —
    /// the cognitive cost of starting the next word. NEVER applied mid-word (that caused
    /// the h-e-l-l⋯o stall). A future Max Speed sets this to 0 (no between-word pauses);
    /// Ultra Fast keeps a small value (KEEPS between-word pauses).
    var hesitationProb: Double = 0.10
    /// Per-key chance a MID-word key carries a SMALL (≤1.6×) natural IKI wobble — keeps
    /// within-word variance without ever stalling. Mode-agnostic; set per preset.
    var midWordJitterProb: Double = 0.06

    // MARK: Wall-clock pacing (Docs forensic mode).
    /// When set, the planner injects extra inter-burst idle so the *session
    /// average* lands at composition rate, and caps contiguous runs to stay under
    /// the Docs paste-detector threshold.
    var compositionPacing: Bool
    var maxContiguousChars: Int   // insert a >=300ms pause before exceeding this
    var targetEffectiveWPM: Double // composition-rate target (session avg incl. idle); 0 = off
    var revisionRate: Double       // per-word chance of a false-start/revision R-burst; 0 = off
    var grammarEnabled: Bool = true // generate grammar/homophone slips (off for exact-recon tests)

    // MARK: - Presets

    static func preset(_ mode: Mode) -> TypingProfile {
        switch mode {
        case .careful:
            return TypingProfile(
                mode: mode,
                ikiMu: 190, ikiSigma: 60, ikiTau: 110, ikiFloor: 55,
                dwellMean: 117, dwellSD: 28, dwellMin: 50, dwellMax: 450,
                arAlpha: 0.15, arSigma: 0.11, warmupFactor: 1.10, fatiguePerMinute: 0.0020,
                typoRate: 0.052, uncorrectedResidue: 0.0, immediateCorrectProb: 0.66,
                postErrorSlowdown: 1.45,
                wordPauseMin: 90, wordPauseMedian: 200,
                sentencePauseMin: 650, sentencePauseMax: 1600,
                thinkingPauseProb: 0.04, thinkingPauseMin: 1200, thinkingPauseMax: 3200,
                hesitationProb: 0.10, midWordJitterProb: 0.06,
                compositionPacing: false, maxContiguousChars: Int.max, targetEffectiveWPM: 0, revisionRate: 0
            )
        case .ultraFast:
            // ~230 wpm — very fast but still human: KEEPS between-word pauses + light corrections.
            return TypingProfile(
                mode: mode,
                ikiMu: 40, ikiSigma: 14, ikiTau: 34, ikiFloor: 50,
                dwellMean: 88, dwellSD: 15, dwellMin: 32, dwellMax: 240,
                arAlpha: 0.10, arSigma: 0.05, warmupFactor: 1.03, fatiguePerMinute: 0.0010,
                typoRate: 0.030, uncorrectedResidue: 0.0, immediateCorrectProb: 0.84,
                postErrorSlowdown: 1.18,
                wordPauseMin: 16, wordPauseMedian: 42,
                sentencePauseMin: 150, sentencePauseMax: 360,
                thinkingPauseProb: 0.013, thinkingPauseMin: 300, thinkingPauseMax: 650,
                hesitationProb: 0.09, midWordJitterProb: 0.05,
                compositionPacing: false, maxContiguousChars: Int.max, targetEffectiveWPM: 0, revisionRate: 0
            )
        case .maxSpeed:
            // ~800 wpm — fast, but STILL keeps the little flaws and their corrections (not
            // robotic). Deliberately superhuman; raw speed for when nothing audits keystroke
            // timing. Tuned DOWN 3000 → 1500 → 1000 → 900 → 800: at higher rates a fragile
            // web/Electron target (Feather) couldn't ingest fast enough and dropped keys (merged
            // words) + double-registered spaces (→ "double-space → period" stray periods). ~800
            // (~67 keys/s) gives the editor more time per keystroke to stay correct. Measured on
            // the SERIALIZED plan — see SelfTest test 9.
            return TypingProfile(
                mode: mode,
                ikiMu: 6.6, ikiSigma: 1.9, ikiTau: 3.9, ikiFloor: 3.1,
                dwellMean: 12, dwellSD: 3.6, dwellMin: 2, dwellMax: 36,
                arAlpha: 0.06, arSigma: 0.03, warmupFactor: 1.0, fatiguePerMinute: 0.0002,
                typoRate: 0.025, uncorrectedResidue: 0.0, immediateCorrectProb: 0.85,
                postErrorSlowdown: 1.08, delaysCorrections: false,   // never the go-back-at-the-end fix
                wordPauseMin: 3, wordPauseMedian: 9,
                sentencePauseMin: 15, sentencePauseMax: 40,
                thinkingPauseProb: 0.005, thinkingPauseMin: 66, thinkingPauseMax: 165,
                hesitationProb: 0.02, midWordJitterProb: 0.02,
                compositionPacing: false, maxContiguousChars: Int.max, targetEffectiveWPM: 0, revisionRate: 0
            )
        case .maxStealth:
            return maxStealthPreset()
        }
    }

    /// A copy of a preset with errors disabled — used by the self-test to verify the
    /// planner reproduces text faithfully (and that corrections undo their own slips).
    static func zeroError(_ mode: Mode, typoRate: Double = 0) -> TypingProfile {
        var p = preset(mode)
        p.typoRate = typoRate
        p.uncorrectedResidue = 0
        p.grammarEnabled = false   // grammar slips intentionally leave residue; off here
        return p
    }

    /// Char typos off, grammar slips ON — for testing grammar residue in isolation.
    static func grammarOnly(_ mode: Mode) -> TypingProfile {
        var p = preset(mode)
        p.typoRate = 0
        p.uncorrectedResidue = 0
        return p
    }

    private static func maxStealthPreset() -> TypingProfile {
            // Natural motor cadence, but composition wall-clock pacing so the Docs
            // changelog (microsecond timestamps) reads as organically written.
            return TypingProfile(
                mode: .maxStealth,
                ikiMu: 170, ikiSigma: 45, ikiTau: 95, ikiFloor: 60,
                dwellMean: 118, dwellSD: 24, dwellMin: 50, dwellMax: 420,
                arAlpha: 0.15, arSigma: 0.11, warmupFactor: 1.10, fatiguePerMinute: 0.0025,
                typoRate: 0.050, uncorrectedResidue: 0.0, immediateCorrectProb: 0.55,
                postErrorSlowdown: 1.45,
                wordPauseMin: 120, wordPauseMedian: 280,
                sentencePauseMin: 900, sentencePauseMax: 2500,
                thinkingPauseProb: 0.14, thinkingPauseMin: 2000, thinkingPauseMax: 5000,
                hesitationProb: 0.09, midWordJitterProb: 0.06,
                compositionPacing: true, maxContiguousChars: 22, targetEffectiveWPM: 14, revisionRate: 0.05
            )
    }
}
