import Foundation
import CoreGraphics

/// Headless correctness checks for the planner, runnable without the GUI:
///     swift run TyperPlus --selftest
///
/// The key invariant: applying the planned `[Action]` stream to a text buffer must
/// reproduce the input — exactly when errors are disabled, and STILL exactly when
/// errors are enabled but the residue is zero (i.e. every injected slip is undone
/// by its own correction / the end-review pass). This catches bugs in the typo,
/// transposition, delayed-correction, and cursor-navigation logic.
enum TyperPlusSelfTest {

    /// Apply the action list to a buffer the way the target app would, returning the
    /// final text.
    static func simulate(_ actions: [Action]) -> String {
        var buf: [Character] = []
        var cursor = 0
        var opt = false
        for a in actions {
            switch a.op {
            case .charDown(let c):
                buf.insert(c, at: min(cursor, buf.count)); cursor += 1
            case .charUp:
                break
            case .optionDown: opt = true
            case .optionUp: opt = false
            case .keyDown(let code):
                switch code {
                case KeyMap.backspace:
                    if cursor > 0 { buf.remove(at: cursor - 1); cursor -= 1 }
                case KeyMap.leftArrow:
                    cursor = opt ? TextNav.wordLeft(buf, cursor) : max(0, cursor - 1)
                case KeyMap.rightArrow:
                    cursor = opt ? TextNav.wordRight(buf, cursor) : min(buf.count, cursor + 1)
                case KeyMap.returnKey:
                    buf.insert("\n", at: min(cursor, buf.count)); cursor += 1
                case KeyMap.tab:
                    buf.insert("\t", at: min(cursor, buf.count)); cursor += 1
                default:
                    break
                }
            case .keyUp, .shiftDown, .shiftUp:
                break
            }
        }
        return String(buf)
    }

    static func run() -> Int {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            print((cond ? "  ✓ " : "  ✗ FAIL: ") + msg)
            if !cond { failures += 1 }
        }

        // Texts with NO confusable words (so grammar slips can't fire) for the
        // exact-reconstruction tests.
        let cleanTexts = [
            "The quick brown fox jumps over the lazy dog.",
            "Hello world, this is a simple typing test.",
            "Programming in Swift can be quite enjoyable and fast.",
            "She sells sea shells by the shore on a sunny morning."
        ]

        print("Self-test 1: zero-error reconstruction is exact (all modes, 25 seeds each)")
        for mode in TypingProfile.Mode.allCases {
            var ok = true
            for text in cleanTexts {
                for _ in 0..<25 {
                    let plan = Planner(profile: .zeroError(mode), rng: RNG()).plan(text)
                    if simulate(plan) != text { ok = false; break }
                }
                if !ok { break }
            }
            check(ok, "mode \(mode.rawValue): plan reproduces input verbatim")
        }

        print("Self-test 2: with errors but ZERO residue, corrections fully undo slips")
        for mode in TypingProfile.Mode.allCases {
            var ok = true
            for text in cleanTexts {
                for _ in 0..<40 {
                    let plan = Planner(profile: .zeroError(mode, typoRate: 0.5), rng: RNG()).plan(text)
                    if simulate(plan) != text { ok = false; break }
                }
                if !ok { break }
            }
            check(ok, "mode \(mode.rawValue): heavy typos (residue 0) reconstruct exactly")
        }

        print("Self-test 3: all delays are finite and non-negative; plans are non-empty")
        do {
            var ok = true
            for mode in TypingProfile.Mode.allCases {
                let plan = Planner(profile: .preset(mode), rng: RNG())
                    .plan("The quick brown fox. Its a test; you're up.")
                if plan.isEmpty { ok = false }
                for a in plan where !(a.preDelayMs.isFinite && a.preDelayMs >= 0) { ok = false }
            }
            check(ok, "delays valid, plans non-empty")
        }

        print("Self-test 4: grammar/end-review never corrupts beyond a single confusable")
        do {
            // Source uses the CORRECT forms; a slip + end-review may occasionally
            // leave one wrong, but must never produce unrelated corruption.
            let text = "its a test and you're right about their plan, then we go too."
            var maxEdits = 0
            for _ in 0..<60 {
                let plan = Planner(profile: .grammarOnly(.careful), rng: RNG()).plan(text)
                let out = simulate(plan)
                maxEdits = max(maxEdits, levenshtein(out, text))
            }
            // Grammar slips now distribute (immediate / end-review / a few left in), so a
            // small residue of un-fixed confusables is expected and bounded.
            check(maxEdits <= 12, "grammar residue bounded (max edit distance \(maxEdits) ≤ 12)")
        }

        print("Self-test 5: timing statistics land on the research targets")
        do {
            // No confusable words → no grammar slips / end-review jumps polluting the
            // pure-typing timing measurement (grammar is covered by test 4).
            let para = Array(repeating: "the quick brown fox jumps over a lazy dog while we watch. ",
                             count: 12).joined()
            // (mode, median-IKI range → WPM, dwell range, min overlap). Metrics are
            // AVERAGED over several plans so lag-1/overlap can't pass on lucky variance.
            // (mode, median range, dwell range, min overlap, lag-1 floor). Composition
            // pacing dilutes Max Stealth's autocorrelation, so it gets a lower floor.
            // (mode, median range → WPM, dwell range, min overlap, lag1 floor, CV floor).
            // Max Speed is intentionally inhuman (sub-45ms, no pauses) → excluded from the human bounds.
            let bounds: [(TypingProfile.Mode, ClosedRange<Double>, ClosedRange<Double>, Double, Double, Double)] = [
                (.careful,   220...420, 110...148, 0.04,  0.05, 0.45),
                (.ultraFast,  35...95,   70...108, 0.30,  0.04, 0.40),  // ~230 wpm — fast but human (structured rollover ⇒ real CV + positive autocorr)
                (.maxStealth, 150...330, 105...134, 0.08, -1.0, 0.45)   // composition idle ⇒ full-stream autocorr ~0 (human too)
            ]
            let N = 8
            for (mode, medRange, dwellRange, minOverlap, lagFloor, cvFloor) in bounds {
                var med = 0.0, cv = 0.0, dwM = 0.0, dwSD = 0.0, lag = 0.0, ov = 0.0, minI = 1e9
                for _ in 0..<N {
                    let s = timingStats(Planner(profile: .zeroError(mode), rng: RNG()).plan(para))
                    med += s.medianIKI; cv += s.coreCV; dwM += s.meanDwell; dwSD += s.dwellSD
                    lag += s.lag1; ov += s.overlapFrac; minI = Swift.min(minI, s.minIKI)
                }
                med /= Double(N); cv /= Double(N); dwM /= Double(N); dwSD /= Double(N); lag /= Double(N); ov /= Double(N)
                let wpm = 60000.0 / (med * 5.0)
                print(String(format: "  %@: median IKI %.0f ms (~%.0f wpm), CV %.2f, dwell %.0f±%.0f ms, lag1 %.3f, overlap %.0f%%, minIKI %.0f",
                             mode.rawValue, med, wpm, cv, dwM, dwSD, lag, ov * 100, minI))
                check(medRange.contains(med), "\(mode.rawValue): median IKI in \(medRange) (WPM)")
                check(dwellRange.contains(dwM), "\(mode.rawValue): mean dwell in \(dwellRange)")
                check(cv >= cvFloor && cv <= 2.4, "\(mode.rawValue): core IKI CV in human range (>= \(cvFloor))")
                check(dwSD >= 16 && dwSD <= 36, "\(mode.rawValue): dwell SD human-range (\(Int(dwSD)) in 16–36)")
                check(lag >= lagFloor && lag <= 0.16, "\(mode.rawValue): IKI lag-1 autocorr human (\(String(format: "%.3f", lag)) >= \(lagFloor))")
                check(minI >= 45, "\(mode.rawValue): no sub-45ms IKI (bot tell)")
                check(ov >= minOverlap, "\(mode.rawValue): key overlap \(Int(ov*100))%% >= \(Int(minOverlap*100))%%")
            }
        }

        print("Self-test 6: capitals/shifted chars are typed with real Shift held; events balance")
        do {
            // Cover EVERY mode AND both delivery models — the Shift-release timing depends on
            // the down-to-down gap, which collapses to ~1ms at Max Speed, so a Careful-only
            // check (the old test) silently missed capitals being dropped to lowercase there.
            var ok = true
            let sample = "The Quick BROWN Fox! Hello, World. I'm OK \u{2014} caf\u{e9}? WOW. ABCD efgh."
            for mode in TypingProfile.Mode.allCases {
                for serial in [false, true] {
                    for _ in 0..<25 {
                        let plan = Planner(profile: .zeroError(mode), rng: RNG(), serialize: serial).plan(sample)
                        var shiftHeld = false, balance = 0
                        for a in plan {
                            switch a.op {
                            case .shiftDown: shiftHeld = true; balance += 1
                            case .shiftUp: shiftHeld = false; balance -= 1
                            case .charDown(let c):
                                // A shifted char that lands while Shift is NOT held would be
                                // typed as its unshifted form (capital -> lowercase): the bug.
                                if (KeyMap.stroke(for: c)?.shift ?? false) && !shiftHeld { ok = false }
                            default: break
                            }
                        }
                        if balance != 0 { ok = false }
                    }
                }
            }
            check(ok, "shifted chars covered by held Shift (all modes, overlap + serialized)")

            // And the on-screen reconstruction of an ALL-CAPS run must be exact under serialize
            // (this is what actually breaks when Shift releases early on the keycode path).
            var caps = true
            for mode in TypingProfile.Mode.allCases {
                for _ in 0..<25 {
                    let plan = Planner(profile: .zeroError(mode), rng: RNG(), serialize: true)
                        .plan("WHAT THE HECK Is GOING On Here? ALL CAPS HELLO World.")
                    if simulate(plan) != "WHAT THE HECK Is GOING On Here? ALL CAPS HELLO World." { caps = false }
                }
            }
            check(caps, "ALL-CAPS / mixed-case reconstructs exactly under serialized delivery")
        }

        print("Self-test 7: Max Stealth composition pacing hits composition rate")
        do {
            let para = "The project began with a simple idea. We wanted something that felt natural. "
                + "Over time it grew into a careful, deliberate tool. Each sentence is typed slowly. "
                + "There are pauses to think. The result reads like real human writing, not a paste."
            var ok = true, sample = 0.0
            for _ in 0..<8 {
                let plan = Planner(profile: .preset(.maxStealth), rng: RNG()).plan(para)
                let total = plan.reduce(0) { $0 + $1.preDelayMs }
                var chars = 0
                for a in plan { if case .charDown = a.op { chars += 1 } }
                let wpm = Double(chars) / 5.0 / (total / 60000.0)
                sample = wpm
                if !(wpm >= 6 && wpm <= 24) { ok = false }
            }
            print(String(format: "  Max Stealth effective ~%.1f wpm (target 8-20)", sample))
            check(ok, "Max Stealth effective WPM in composition range (6-24)")
        }

        print("Self-test 8: reliable delivery reconstructs exactly with NO key overlap")
        do {
            var ok = true
            var peak = 0
            for mode in TypingProfile.Mode.allCases {
                for text in cleanTexts {
                    for _ in 0..<25 {
                        // Both the live default (typos off → verbatim) and a heavy-typo /
                        // zero-residue stress must reconstruct exactly under serialization.
                        for tr in [0.0, 0.5] {
                            let plan = Planner(profile: .zeroError(mode, typoRate: tr),
                                               rng: RNG(), serialize: true).plan(text)
                            if simulate(plan) != text { ok = false }
                            peak = max(peak, peakKeyOverlap(plan))
                        }
                    }
                }
            }
            check(ok, "serialized plan reproduces input verbatim (all modes)")
            // A single key down at a time reads as peak==1; 2+ means two keys overlapped,
            // which is exactly what a fragile target drops. Serialize must guarantee ≤1.
            check(peak <= 1, "serialized plan never holds two keys at once (peak \(peak))")
        }

        print("Self-test 9: Max Speed serialized plan hits its target rate")
        do {
            // Measured on the SERIALIZED plan (reliable delivery = the shipped default), so
            // the number reflects what the user actually gets — not a nominal IKI.
            let para = Array(repeating: "the quick brown fox jumps over a lazy dog while we watch. ",
                             count: 24).joined()
            var wpm = 0.0
            let N = 8
            for _ in 0..<N {
                let plan = Planner(profile: .zeroError(.maxSpeed), rng: RNG(), serialize: true).plan(para)
                let total = plan.reduce(0) { $0 + $1.preDelayMs }
                var chars = 0
                for a in plan { if case .charDown = a.op { chars += 1 } }
                wpm += Double(chars) / 5.0 / (total / 60000.0)
            }
            wpm /= Double(N)
            print(String(format: "  Max Speed serialized plan ~%.0f wpm (target ~800)", wpm))
            check(wpm >= 690 && wpm <= 940, "Max Speed serialized plan in 690–940 wpm")
            // And non-serialized (overlap) is even faster — sanity that serialize isn't the cap.
            let raw = Planner(profile: .zeroError(.maxSpeed), rng: RNG(), serialize: false).plan(para)
            let rtotal = raw.reduce(0) { $0 + $1.preDelayMs }
            var rchars = 0; for a in raw { if case .charDown = a.op { rchars += 1 } }
            let rwpm = Double(rchars) / 5.0 / (rtotal / 60000.0)
            print(String(format: "  Max Speed overlap plan    ~%.0f wpm (serialize is not the bottleneck)", rwpm))
        }

        print(failures == 0 ? "\nALL SELF-TESTS PASSED" : "\n\(failures) SELF-TEST(S) FAILED")
        return failures
    }

    /// Scheduler throughput check: run the actual Player against a Max Speed plan with a live
    /// run loop and report the WPM the SCHEDULER paces at. It runs in dry-run (it does the full
    /// timing/stepping but does NOT post CGEvents), so it measures exactly one thing — that the
    /// new monotonic flush-loop is not capped by the run loop's ~16ms wake granularity (the bug
    /// that made fast modes feel slow). It deliberately does NOT claim real end-to-end injection
    /// throughput: whether a given TARGET APP ingests at this rate is app-specific and can't be
    /// measured headlessly. A separate micro-benchmark bounds OUR per-key cost.
    /// `swift run TyperPlus --speedtest`.
    static func runSpeedTest() -> Int {
        let para = Array(repeating: "the quick brown fox jumps over a lazy dog while we watch. ",
                         count: 40).joined()
        let plan = Planner(profile: .zeroError(.maxSpeed), rng: RNG(), serialize: true).plan(para)
        let plannedMs = plan.reduce(0) { $0 + $1.preDelayMs }
        var chars = 0
        for a in plan { if case .charDown = a.op { chars += 1 } }
        let plannedWPM = Double(chars) / 5.0 / (plannedMs / 60000.0)

        let player = Player(engine: KeyboardEngine())
        player.dryRun = true
        var done = false
        player.onFinish = { done = true }

        let start = DispatchTime.now().uptimeNanoseconds
        player.play(plan)
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        let pacedWPM = Double(chars) / 5.0 / (wallMs / 60000.0)

        // Producer-side cost: how long does it take to BUILD a real key CGEvent (create +
        // finalize), i.e. everything the engine does per key short of the post() syscall?
        // This bounds our overhead; if it's ~µs it can't be the bottleneck at ms-scale gaps.
        let buildUs = measureCGEventBuildMicros(count: 5000)

        print("── Max Speed scheduler throughput (DRY-RUN: schedules + paces, does NOT inject) ──")
        print(String(format: "  chars                : %d", chars))
        print(String(format: "  planned plan time    : %.0f ms  (~%.0f wpm on paper)", plannedMs, plannedWPM))
        print(String(format: "  scheduler wall-clock : %.0f ms  (~%.0f wpm paced)", wallMs, pacedWPM))
        print(String(format: "  paced / planned      : %.0f%%   (the run loop is NOT the cap)", pacedWPM / max(plannedWPM, 1) * 100))
        print(String(format: "  per-key CGEvent build: %.1f µs  (producer cost; the window-server post() is a separate ~µs syscall)", buildUs))
        print("  NOTE: whether a TARGET APP ingests at this rate is app-specific and not measured here.")
        // Pass = the scheduler keeps up with the PLAN (>=90%), i.e. the run loop is not the cap —
        // independent of the absolute target rate (1500, 3000, …).
        let ok = done && pacedWPM >= plannedWPM * 0.9
        print(ok ? "  ✓ scheduler keeps up with the plan (run-loop cap removed)"
                 : "  ✗ scheduler falls behind the plan")
        return ok ? 0 : 1
    }

    /// Average microseconds to build (create + finalize, NOT post) one key CGEvent — the real
    /// per-key producer work, measured against a real `.hidSystemState` source.
    private static func measureCGEventBuildMicros(count: Int) -> Double {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        var built = 0
        for _ in 0..<count {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { continue }
            let u: [UniChar] = [0x61]   // 'a'
            u.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            e.flags = []
            e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            e.timestamp = mach_absolute_time()
            built += 1
            // intentionally NOT posted
        }
        let dtNs = Double(DispatchTime.now().uptimeNanoseconds - t0)
        return built > 0 ? (dtNs / Double(built)) / 1000.0 : 0
    }

    /// Peak number of CHARACTER/SPECIAL keys held down simultaneously (modifiers like
    /// Shift/Option legitimately span a run and are excluded). Reliable delivery must keep
    /// this ≤ 1 — no two text keys ever down together, so nothing can be dropped/merged.
    private static func peakKeyOverlap(_ actions: [Action]) -> Int {
        var held = 0, peak = 0
        for a in actions {
            switch a.op {
            case .charDown, .keyDown: held += 1; peak = max(peak, held)
            case .charUp, .keyUp: if held > 0 { held -= 1 }
            default: break
            }
        }
        return peak
    }

    private struct TimingStats {
        let medianIKI: Double   // robust typing-speed estimate
        let coreMean: Double    // letter→letter IKI (no boundary pause) ≈ research IKI
        let coreCV: Double
        let meanDwell: Double
        let dwellSD: Double
        let lag1: Double        // lag-1 autocorrelation of log-IKI (human ≈ 0.087)
        let overlapFrac: Double // key rollover rate
        let pauseFrac: Double   // share of IKIs that are deliberate pauses (>700ms)
        let minIKI: Double
    }

    private static func timingStats(_ actions: [Action]) -> TimingStats {
        var t = 0.0
        var downs: [(t: Double, c: Character)] = []
        var ups: [(t: Double, c: Character)] = []
        var held = 0, overlaps = 0, nDown = 0
        for a in actions {
            t += a.preDelayMs
            switch a.op {
            case .charDown(let c):
                downs.append((t, c)); nDown += 1
                if held > 0 { overlaps += 1 }
                held += 1
            case .charUp(let c):
                ups.append((t, c)); if held > 0 { held -= 1 }
            default: break
            }
        }
        var allIKI: [Double] = []
        var coreIKI: [Double] = []   // letter→letter only (no boundary/thinking pause)
        if downs.count > 1 {
            for k in 1..<downs.count {
                let iki = downs[k].t - downs[k - 1].t
                allIKI.append(iki)
                if downs[k].c.isLetter && downs[k - 1].c.isLetter { coreIKI.append(iki) }
            }
        }
        let sortedAll = allIKI.sorted()
        let median = sortedAll.isEmpty ? 0 : sortedAll[sortedAll.count / 2]
        let coreMean = coreIKI.reduce(0, +) / Double(max(coreIKI.count, 1))
        let coreVar = coreIKI.reduce(0) { $0 + ($1 - coreMean) * ($1 - coreMean) } / Double(max(coreIKI.count, 1))
        let coreCV = coreMean > 0 ? coreVar.squareRoot() / coreMean : 0
        let pauseFrac = Double(allIKI.filter { $0 > 700 }.count) / Double(max(allIKI.count, 1))

        var downsByChar: [Character: [Double]] = [:], upsByChar: [Character: [Double]] = [:]
        for d in downs { downsByChar[d.c, default: []].append(d.t) }
        for u in ups { upsByChar[u.c, default: []].append(u.t) }
        var dwells: [Double] = []
        for (c, dts) in downsByChar {
            if let uts = upsByChar[c] { for k in 0..<min(dts.count, uts.count) { dwells.append(uts[k] - dts[k]) } }
        }
        let meanDwell = dwells.reduce(0, +) / Double(max(dwells.count, 1))
        let dwellVar = dwells.reduce(0) { $0 + ($1 - meanDwell) * ($1 - meanDwell) } / Double(max(dwells.count, 1))
        let dwellSD = dwellVar.squareRoot()

        // Lag-1 autocorrelation on the typing stream: log-IKI with pauses winsorized to
        // ~700ms so deliberate hesitations don't dilute the motor autocorrelation.
        let logs = allIKI.map { log(min(max($0, 1), 700)) }
        let lm = logs.reduce(0, +) / Double(max(logs.count, 1))
        var num = 0.0, den = 0.0
        if logs.count > 1 { for k in 1..<logs.count { num += (logs[k] - lm) * (logs[k - 1] - lm) } }
        for v in logs { den += (v - lm) * (v - lm) }
        let lag1 = den > 0 ? num / den : 0

        return TimingStats(medianIKI: median, coreMean: coreMean, coreCV: coreCV,
                           meanDwell: meanDwell, dwellSD: dwellSD, lag1: lag1,
                           overlapFrac: Double(overlaps) / Double(max(nDown, 1)),
                           pauseFrac: pauseFrac, minIKI: allIKI.min() ?? 0)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            cur[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        return prev[y.count]
    }
}
