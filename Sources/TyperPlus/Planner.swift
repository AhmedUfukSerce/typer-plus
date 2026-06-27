import CoreGraphics
import Foundation

/// One timed keystroke action. `preDelayMs` is the wait BEFORE executing `op`
/// (time since the previous action), so the list fully encodes the rhythm.
struct Action {
    enum Op {
        case charDown(Character)   // text via the engine's char path
        case charUp(Character)
        case keyDown(CGKeyCode)    // special keys: backspace, arrows, return, tab
        case keyUp(CGKeyCode)
        case shiftDown             // real left-Shift press (held across a shifted run)
        case shiftUp
        case optionDown            // left-Option held → ⌥-arrow word jumps
        case optionUp
    }
    let preDelayMs: Double
    let op: Op
}

/// Caret word-navigation model, shared by the planner (to compute jumps) and the
/// self-test simulator (to verify), matching macOS ⌥← / ⌥→ semantics.
enum TextNav {
    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Start of the previous word to the left of `c` (⌥←).
    static func wordLeft(_ buf: [Character], _ c: Int) -> Int {
        var i = min(c, buf.count)
        while i > 0 && !isWord(buf[i - 1]) { i -= 1 }   // skip gaps
        while i > 0 && isWord(buf[i - 1]) { i -= 1 }    // skip the word
        return i
    }

    /// End of the next word to the right of `c` (⌥→).
    static func wordRight(_ buf: [Character], _ c: Int) -> Int {
        var i = max(c, 0)
        while i < buf.count && !isWord(buf[i]) { i += 1 }
        while i < buf.count && isWord(buf[i]) { i += 1 }
        return i
    }
}

/// Turns text into a fully-planned `[Action]` stream: research-tuned timing, real
/// Shift key events around capitals/shifted chars, open-ended typos with two-loop
/// correction, boundary/planning pauses, grammar/homophone slips, the end-of-text
/// review pass, and (Max Stealth) composition-rate wall-clock pacing.
///
/// Timing model: each key's DOWN is spaced from the previous down by the down-to-down
/// IKI; an independent dwell sets its UP. Events are scheduled on an absolute clock
/// and sorted, so dwell>IKI naturally produces key overlap (rollover). Pure logic
/// (no I/O), deterministic given the RNG + persona, verified headless by SelfTest.
final class Planner {

    private let profile: TypingProfile
    private let rng: RNG
    private let timing: Timing
    private let persona: Persona

    /// Reliable delivery: serialize keystrokes so no two character/special keys are ever
    /// held down at the same time, and pace them with a small real gap. The default
    /// stealth model overlaps keys (rollover + dwell>IKI) — genuine human texture that a
    /// tolerant app reads fine, but a fragile web/Electron target (e.g. a contenteditable
    /// site) batches and DROPS, merging words and tripping the app's own autocorrect /
    /// macOS "double-space → period". Off ⇒ the original overlap model (max stealth).
    private let serialize: Bool

    private struct Event { let t: Double; let seq: Int; let op: Action.Op }
    private var events: [Event] = []
    private var clock = 0.0
    private var seq = 0

    private var bufferLen = 0
    private var contiguous = 0
    private var contiguousCap = 20
    private var postErrorRemaining = 0
    private var postErrorFactor = 1.0
    private var lastKeyId = ""
    private var lastUpTime = 0.0
    private var lastDownTime = 0.0   // DOWN time of the most recent char/special key (for Shift release)
    private var lastReleaseT = 0.0   // serialize mode: UP time of the most recent char/special key
    private var shiftHeld = false

    init(profile: TypingProfile, rng: RNG, persona: Persona = .neutral, serialize: Bool = false) {
        self.profile = profile
        self.rng = rng
        self.persona = persona
        self.serialize = serialize
        self.timing = Timing(profile: profile, rng: rng, persona: persona)
    }

    func plan(_ text: String) -> [Action] {
        events.removeAll(keepingCapacity: true)
        clock = 0; seq = 0; bufferLen = 0; contiguous = 0
        contiguousCap = rng.int(16, 24)
        postErrorRemaining = 0; postErrorFactor = 1.0
        lastKeyId = ""; lastUpTime = 0; lastDownTime = 0; lastReleaseT = 0
        shiftHeld = false

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            i += handleChar(chars, at: i)
        }
        releaseShift()

        let sorted = events.sorted { $0.t != $1.t ? $0.t < $1.t : $0.seq < $1.seq }
        var out: [Action] = []
        out.reserveCapacity(sorted.count)
        var prev = 0.0
        for e in sorted {
            out.append(Action(preDelayMs: max(0, e.t - prev), op: e.op))
            prev = e.t
        }
        return applyCompositionPacing(out)
    }

    // MARK: - Scheduling primitives (absolute clock)

    private func schedule(_ t: Double, _ op: Action.Op) {
        events.append(Event(t: t, seq: seq, op: op)); seq += 1
    }

    /// Advance to this key's down time; same key can't re-press before release.
    ///
    /// In serialize (reliable-delivery) mode this also guarantees this key's DOWN is
    /// strictly after the PREVIOUS character/special key's UP (+ a small jittered gap),
    /// and clamps the hold so the key is fully released a touch before the next nominal
    /// press — i.e. no two keys are ever down together. That's what makes a fragile
    /// web/Electron target reproduce the text exactly instead of dropping the overlapped
    /// (usually space) key and merging words. The down-to-down rhythm is still the
    /// research-tuned IKI, so per-key timing texture survives.
    private func nextDownUp(iki: Double, dwell: Double, keyId: String) -> (down: Double, up: Double) {
        var down = clock + iki
        if keyId == lastKeyId { down = max(down, lastUpTime + 9) }
        var hold = dwell
        if serialize {
            // The separation gap SCALES with speed: ~12–14ms for the human modes (a
            // comfortable margin so a fragile web/Electron target registers every key),
            // but only ~1ms for Max Speed — so serialization stays non-overlapping
            // WITHOUT throttling the raw-speed mode down to a few hundred WPM. Any
            // positive gap guarantees no overlap (this key's DOWN is after the previous
            // key's UP); the magnitude is purely the reliability margin.
            let gap = min(max(iki * 0.35, 1.0), 14.0) * rng.uniform(0.9, 1.1)
            down = max(down, lastReleaseT + gap)
            hold = min(hold, max(1.0, iki - gap))   // released a touch before the next press
        }
        clock = down
        let up = down + hold
        lastKeyId = keyId
        lastDownTime = down
        lastUpTime = up
        if serialize { lastReleaseT = up }
        return (down, up)
    }

    /// Schedule the held-Shift RELEASE so it lands strictly after the last shifted char's
    /// own key-DOWN (so the capital is registered) and strictly before the next key's DOWN
    /// (so that key isn't typed shifted). The old formula `min(prevUp+.., nextDown-..)`
    /// silently assumed a >=~20ms gap between those downs; at Max Speed's ~1–2ms IKI that
    /// subtraction landed the release BEFORE the capital, dropping it to lowercase. Anchoring
    /// to the real (capitalDown, nextDown) window is correct at any speed: it prefers a
    /// natural ~28–85ms human lag when there's room and collapses to the window's midpoint
    /// when the keys are only microseconds apart.
    private func scheduleShiftUp(capitalDown lo0: Double, nextDown hi0: Double, naturalAfter prevUp: Double) {
        let span = max(0, hi0 - lo0)
        let early = min(rng.uniform(2, 6),  span * 0.25)   // stay after the capital's down
        let late  = min(rng.uniform(8, 20), span * 0.5)    // stay before the next key's down
        let lo = lo0 + early
        let hi = hi0 - late
        let natural = prevUp + rng.uniform(28, 85)
        let upT = hi > lo ? min(max(natural, lo), hi) : (lo0 + span * 0.5)
        schedule(upT, .shiftUp)
    }

    /// Press a text character, managing the held-Shift run for capitals/shifted chars.
    private func pressChar(_ ch: Character, iki: Double) {
        let shifted = needsShift(ch)
        let dwell = timing.dwellMs(for: ch, iki: iki)

        if shifted {
            if shiftHeld {
                // Continue the held-Shift run (shifted keys never roll over).
                let (down, up) = nextDownUp(iki: iki, dwell: dwell, keyId: String(ch.lowercased()))
                schedule(down, .charDown(ch)); schedule(up, .charUp(ch)); bufferLen += 1
            } else {
                let lead = rng.uniform(28, 75)          // Shift leads the letter slightly
                clock += max(iki - lead, 12)
                schedule(clock, .shiftDown)
                shiftHeld = true
                let (down, up) = nextDownUp(iki: lead, dwell: dwell, keyId: String(ch.lowercased()))
                schedule(down, .charDown(ch)); schedule(up, .charUp(ch)); bufferLen += 1
            }
            return
        }

        // ch is NOT shifted.
        if shiftHeld {
            // Release Shift STRICTLY before this key's down (otherwise this key would be
            // typed shifted), and after the last shifted char's down (so it stays covered).
            // No rollover across a shift boundary, so the event ordering is exact under sort.
            let prevUp = lastUpTime
            let capitalDown = lastDownTime
            let (down, up) = nextDownUp(iki: iki, dwell: dwell, keyId: String(ch.lowercased()))
            scheduleShiftUp(capitalDown: capitalDown, nextDown: down, naturalAfter: prevUp)
            shiftHeld = false
            schedule(down, .charDown(ch)); schedule(up, .charUp(ch)); bufferLen += 1
            return
        }

        // Calibrated key rollover: for a lowercase letter pair, force the next key DOWN
        // before the previous key UP (a real negative up-down latency) — but never a
        // sub-45ms down-down. Suppressed entirely in serialize mode (overlap is exactly
        // what a fragile target drops).
        if !serialize, canRollover(ch), timing.shouldRollover() {
            // Rollover = next key DOWN before the previous key UP (a real negative up-down
            // latency). The down-down gap is a compressed, STRUCTURED fraction of the iki
            // (keeps the ex-Gaussian skew / AR(1) / bigram cadence, faster than the normal
            // gap) — never a flat uniform block (a uniform IKI is the #1 biometric tell).
            let down = clock + timing.rolloverGapMs(from: iki)
            clock = down
            let up = down + dwell
            lastKeyId = String(ch.lowercased()); lastDownTime = down; lastUpTime = up
            schedule(down, .charDown(ch)); schedule(up, .charUp(ch)); bufferLen += 1
            return
        }

        let (down, up) = nextDownUp(iki: iki, dwell: dwell, keyId: String(ch.lowercased()))
        schedule(down, .charDown(ch)); schedule(up, .charUp(ch)); bufferLen += 1
    }

    /// A lowercase ASCII letter following a different lowercase ASCII letter — the only
    /// pairs eligible for rollover (avoids modifier/special-key complexity).
    private func canRollover(_ ch: Character) -> Bool {
        guard ch.isLetter, ch.isLowercase, ch.isASCII else { return false }
        return lastKeyId.count == 1 && (lastKeyId.first?.isLetter ?? false) && lastKeyId != String(ch.lowercased())
    }

    private func releaseShift() {
        guard shiftHeld else { return }
        schedule(lastUpTime + rng.uniform(28, 85), .shiftUp)
        shiftHeld = false
    }

    private func needsShift(_ ch: Character) -> Bool { KeyMap.stroke(for: ch)?.shift ?? false }

    private func pressKey(_ code: CGKeyCode, iki: Double, dwell: Double) {
        // Special keys are never typed with Shift held; release it strictly before this
        // key's down (same ordering guarantee as the shifted→non-shifted char boundary).
        let prevUp = lastUpTime
        let capitalDown = lastDownTime
        let (down, up) = nextDownUp(iki: iki, dwell: dwell, keyId: "k\(code)")
        if shiftHeld {
            scheduleShiftUp(capitalDown: capitalDown, nextDown: down, naturalAfter: prevUp)
            shiftHeld = false
        }
        schedule(down, .keyDown(code))
        schedule(up, .keyUp(code))
    }

    // MARK: - Per-character handling (returns source chars consumed)

    private func handleChar(_ chars: [Character], at i: Int) -> Int {
        let cur = chars[i]
        let prev: Character? = i > 0 ? chars[i - 1] : nil
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        let atWordStart = cur.isLetter && (i == 0 || !isWordChar(chars[i - 1]))

        if cur == "\n" { let g = nextGap(prev, cur); pressKey(KeyMap.returnKey, iki: g, dwell: timing.dwellMs(for: cur, iki: g)); bufferLen += 1; return 1 }
        if cur == "\t" { let g = nextGap(prev, cur); pressKey(KeyMap.tab, iki: g, dwell: timing.dwellMs(for: cur, iki: g)); bufferLen += 1; return 1 }

        // Revision events (Max Stealth): a "false start" — type a few words, delete them,
        // retype. The delete is plain backspace with the caret at the end, so it's robust in
        // any app. The old omit-then-jump-back insert was removed: it relied on ← caret
        // navigation that real apps don't honor identically, which corrupted the output.
        if atWordStart, profile.revisionRate > 0, rng.bernoulli(profile.revisionRate) {
            emitFalseStart(chars, at: i)
        }

        if atWordStart, let consumed = maybeGrammarSlip(chars, at: i) { return consumed }

        let gap = nextGap(prev, cur)

        if let slip = Typos.charSlip(intended: cur, next: next, atWordStart: atWordStart,
                                     profile: profile, persona: persona, rng: rng) {
            return emitSlip(slip, chars: chars, at: i, firstIki: gap, prev: prev)
        }

        pressChar(cur, iki: gap)
        return 1
    }

    // MARK: - IKI (down-to-down) computation

    private func nextGap(_ prev: Character?, _ cur: Character) -> Double {
        var iki = timing.interKeyMs(prev: prev, cur: cur)
        if let prev = prev { iki += timing.boundaryExtraMs(after: prev, next: cur) }
        if postErrorRemaining > 0 { iki *= postErrorFactor; postErrorRemaining -= 1 }

        // Docs composition pacing: break long contiguous runs with a >=300ms gap at a
        // jittered length + log-normal magnitude (no periodic lattice).
        if iki >= 300 {
            contiguous = 0
        } else if profile.maxContiguousChars != Int.max {
            contiguous += 1
            if contiguous >= contiguousCap {
                iki += rng.logNormal(median: 500, sigma: 0.4)
                contiguous = 0
                contiguousCap = rng.int(16, 24)
            }
        }
        return iki
    }

    private func armPostError() {
        postErrorRemaining = rng.int(2, 4)
        postErrorFactor = timing.postErrorMultiplier()
    }

    private func typeRun(_ run: [Character], prev: Character?) {
        var p = prev
        for ch in run {
            pressChar(ch, iki: nextGap(p, ch))
            p = ch
        }
    }

    private func emitBackspaces(_ n: Int, firstIki: Double) {
        guard n > 0 else { return }
        for k in 0..<n {
            pressKey(KeyMap.backspace,
                     iki: k == 0 ? firstIki : timing.backspaceGapMs(),
                     dwell: timing.backspaceDwellMs())
        }
        bufferLen -= n
    }

    // MARK: - Character-level slips

    private func emitSlip(_ slip: Typos.Plan, chars: [Character], at i: Int,
                          firstIki: Double, prev: Character?) -> Int {
        var p = prev
        for (idx, ch) in slip.typed.enumerated() {
            let iki: Double
            if idx == 0 {
                iki = slip.kind == .substitution ? min(firstIki, rng.uniform(70, 120)) : firstIki
            } else {
                iki = nextGap(p, ch)
            }
            pressChar(ch, iki: iki)
            p = ch
        }
        let consumed = slip.consumesNext ? 2 : 1

        switch slip.correction {
        case .leave:
            break
        case .immediate:
            emitBackspaces(slip.typed.count, firstIki: rng.uniform(140, 380))
            typeRun(slip.intended, prev: prev)
            armPostError()
        case .delayed:
            let lookahead = min(rng.int(1, 3), chars.count - (i + consumed))
            var good: [Character] = []
            var q = slip.typed.last ?? prev
            for k in 0..<max(0, lookahead) {
                let ch = chars[i + consumed + k]
                if !ch.isLetter { break }
                good.append(ch)
                pressChar(ch, iki: nextGap(q, ch))
                q = ch
            }
            emitBackspaces(good.count + slip.typed.count, firstIki: rng.uniform(220, 520))
            typeRun(slip.intended + good, prev: prev)
            armPostError()
            return consumed + good.count
        }
        return consumed
    }

    // MARK: - Grammar / homophone slips (corrected on the spot; Max Stealth may leave subtle ones)

    /// Type the next 2-4 words, pause, then delete them — a false start. The main loop
    /// then retypes them normally, so the final text is unchanged.
    private func emitFalseStart(_ chars: [Character], at i: Int) {
        var j = i, words = 0
        let target = rng.int(2, 4)
        while j < chars.count {
            let c = chars[j]
            if c == "\n" { break }
            if j > i && c == " " { words += 1; if words >= target { break } }
            j += 1
        }
        let phrase = Array(chars[i..<j])
        guard phrase.count >= 3 else { return }
        typeRun(phrase, prev: i > 0 ? chars[i - 1] : nil)
        clock += rng.logNormal(median: 600, sigma: 0.5)        // "…that's not it"
        emitBackspaces(phrase.count, firstIki: rng.uniform(200, 500))
    }

    private func maybeGrammarSlip(_ chars: [Character], at i: Int) -> Int? {
        guard profile.grammarEnabled else { return nil }
        var j = i
        while j < chars.count && isWordChar(chars[j]) { j += 1 }
        let word = String(chars[i..<j])
        guard word.count >= 1, let wrong = Typos.confusableVariant(for: word, rng: rng) else { return nil }

        // Article swaps (a/an/the) are too visible to leave; only subtle homophones are
        // ever left in, and only by Max Stealth (its job is an organically-imperfect Docs
        // history). Everyday modes still MAKE slips for churn but always tidy them up.
        let isArticle = ["a", "an", "the"].contains(word.lowercased())
        let canLeave = profile.mode == .maxStealth && !isArticle
        // The very fast modes still slip (the user wants flaws kept) but churn a little
        // less so the high-speed cadence isn't dominated by visible corrections.
        let isVeryFast = profile.mode == .ultraFast || profile.mode == .maxSpeed
        let considerProb = canLeave ? 0.45 : (isVeryFast ? 0.10 : 0.16)
        guard rng.bernoulli(considerProb) else { return nil }

        let beforeChar: Character? = i > 0 ? chars[i - 1] : nil
        typeRun(Array(wrong), prev: beforeChar)

        func fixNow() {
            emitBackspaces(wrong.count, firstIki: rng.uniform(160, 420))
            typeRun(Array(word), prev: beforeChar)
            armPostError()
        }
        // Always correct on the spot (caret is at the end — every app honors that). We NEVER
        // defer to an end-of-pass jump-back fix: backward ← caret navigation isn't honored
        // identically across real apps (autocomplete, the user's own cursor moves, field
        // quirks), which made the fix land in the wrong place and corrupt the output. Max
        // Stealth may instead LEAVE a subtle slip in place (navigation-free, intentional).
        if canLeave, rng.unit() < 0.45 {
            // leave it in — safe, intentional residue (Max Stealth only)
        } else {
            fixNow()
        }
        return word.count
    }

    // MARK: - Composition-rate pacing (Docs forensic mode)

    /// Spread idle gaps over sentence/paragraph boundaries until the session average
    /// lands at composition rate (so the microsecond-timestamped Docs changelog reads
    /// as organically written, not transcription-speed).
    private func applyCompositionPacing(_ actions: [Action]) -> [Action] {
        guard profile.compositionPacing, profile.targetEffectiveWPM > 0 else { return actions }
        let totalMs = actions.reduce(0) { $0 + $1.preDelayMs }
        var charCount = 0
        for a in actions { if case .charDown = a.op { charCount += 1 } }
        guard charCount > 0 else { return actions }

        let targetMs = Double(charCount) / 5.0 / profile.targetEffectiveWPM * 60000.0
        let deficit = targetMs - totalMs
        guard deficit > 1000 else { return actions }

        // Distribute idle across EVERY word boundary (+ paragraph breaks), weighting
        // sentence ends heavier, with a log-normal mixture — so instantaneous velocity is
        // smooth, not a square wave that dumps all the idle at sentence heads.
        var boundaries: [(idx: Int, weight: Double)] = []
        var prevC: Character? = nil
        var prevPrevC: Character? = nil
        for (i, a) in actions.enumerated() {
            switch a.op {
            case .charDown(let c):
                if prevC == " " {
                    let sentenceEnd = prevPrevC == "." || prevPrevC == "!" || prevPrevC == "?"
                    boundaries.append((i, sentenceEnd ? 3.0 : 1.0))
                }
                prevPrevC = prevC; prevC = c
            case .keyDown(let code) where code == KeyMap.returnKey:
                boundaries.append((i, 4.0))
            default: break
            }
        }
        guard !boundaries.isEmpty else { return actions }

        let totalWeight = boundaries.reduce(0) { $0 + $1.weight }
        var result = actions
        for b in boundaries {
            let share = deficit * (b.weight / totalWeight)
            let add = min(max(0, rng.logNormal(median: max(share, 60), sigma: 0.7)), 180000)
            result[b.idx] = Action(preDelayMs: result[b.idx].preDelayMs + add, op: result[b.idx].op)
        }
        return result
    }

    // MARK: - Helpers

    private func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch == "'" || ch == "\u{2019}"
    }
}
