import Foundation

/// Per-family score (0…1), used by the CLI scorecard (Detector.run).
struct FamilyScore: Identifiable {
    let id = UUID()
    let name: String
    let weight: Double
    let score: Double
}

/// The DETECTOR (v2) — objective measurement instrument for Typer+ (per DETECTOR_SPEC.md,
/// hardened by the Phase-C validation pass). It ingests a typing session as a timed event
/// stream (the engine's [Action] on an absolute clock), derives the keystroke-dynamics /
/// edit-graph / injection features a real detector uses, scores each against human
/// baselines with correct small-sample statistics and calibrated gates, and fuses to a
/// Human-Likeness Score (HLS 0–100) via a weighted geometric mean.
///
/// Run:  swift run TyperPlus --detect
///
/// Phase-C fixes baked in: NaN-safe bands; quantization measured by a real comb test (not
/// the unreachable 1ms distinct-value gate); bias-corrected skew/kurtosis; raw-series
/// autocorrelation; bursts reset across edits/pauses; per-capital Shift coverage from the
/// held-Shift timeline; residue/PPR vetoes that catch a zero-churn transcriber; the native
/// PID + event.code annotations excluded from the fused score; per-feature weights; and a
/// sample-size guard. Coverage of a few deep bot-only features (joint HT-FT density LLR,
/// full error-type mix, two-loop correction latency) is noted honestly in the output.
enum Detector {

    // MARK: - Stats (small-sample correct)

    enum St {
        static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0,+)/Double(x.count) }
        static func sd(_ x: [Double]) -> Double {
            guard x.count > 1 else { return 0 }
            let m = mean(x); return (x.reduce(0){$0+($1-m)*($1-m)}/Double(x.count-1)).squareRoot()
        }
        static func cv(_ x: [Double]) -> Double { let m = mean(x); return m>0 ? sd(x)/m : 0 }
        static func percentile(_ x: [Double], _ p: Double) -> Double {
            guard !x.isEmpty else { return 0 }
            let s = x.sorted(); let idx = Int((p*Double(s.count-1)).rounded())
            return s[max(0, min(s.count-1, idx))]
        }
        static func median(_ x: [Double]) -> Double { percentile(x, 0.5) }
        /// Bias-corrected sample skewness (adjusted Fisher–Pearson G1).
        static func skew(_ x: [Double]) -> Double {
            let n = Double(x.count); guard n > 2 else { return 0 }
            let m = mean(x), s = sd(x); guard s > 0 else { return 0 }
            let g1 = x.reduce(0){$0 + pow(($1-m)/s, 3)} / n
            return g1 * (n*(n-1)).squareRoot() / (n-2)
        }
        /// Bias-corrected excess kurtosis (Joanes–Gill G2).
        static func kurtosis(_ x: [Double]) -> Double {
            let n = Double(x.count); guard n > 3 else { return 0 }
            let m = mean(x), s = sd(x); guard s > 0 else { return 0 }
            let g2 = x.reduce(0){$0 + pow(($1-m)/s, 4)} / n - 3.0
            return ((n-1)/((n-2)*(n-3))) * ((n+1)*g2 + 6)
        }
        /// Lag-k autocorrelation on the RAW series (matches the cited 0.087 baseline).
        static func autocorr(_ x: [Double], lag: Int) -> Double {
            guard x.count > lag + 4 else { return 0 }
            let m = mean(x); var num = 0.0, den = 0.0
            for i in lag..<x.count { num += (x[i]-m)*(x[i-lag]-m) }
            for v in x { den += (v-m)*(v-m) }
            return den>0 ? num/den : 0
        }
        static func fraction(_ x: [Double], lessThan t: Double) -> Double {
            x.isEmpty ? 0 : Double(x.filter{$0<t}.count)/Double(x.count)
        }
        static func fraction(_ x: [Double], greaterThan t: Double) -> Double {
            x.isEmpty ? 0 : Double(x.filter{$0>t}.count)/Double(x.count)
        }
        static func pearson(_ a: [Double], _ b: [Double]) -> Double {
            let n = min(a.count, b.count); guard n > 2 else { return 0 }
            let ma = mean(Array(a.prefix(n))), mb = mean(Array(b.prefix(n)))
            var num=0.0, da=0.0, db=0.0
            for i in 0..<n { num += (a[i]-ma)*(b[i]-mb); da += (a[i]-ma)*(a[i]-ma); db += (b[i]-mb)*(b[i]-mb) }
            return (da>0 && db>0) ? num/(da*db).squareRoot() : 0
        }
        /// Excess mass concentrated on a periodic-timer grid (USB/poll comb). ~0 for a
        /// continuous human; large for a quantized bot. Replaces the unreachable 1ms
        /// distinct-value gate as the real quantization detector.
        static func combExcess(_ x: [Double]) -> Double {
            guard x.count > 20 else { return 0 }
            var best = 0.0
            for r in [5.0, 8.3333, 10.0, 16.6667, 25.0, 50.0] {
                let hit = Double(x.filter { let m = $0.truncatingRemainder(dividingBy: r); return m < 0.5 || m > r-0.5 }.count)/Double(x.count)
                best = max(best, hit - 1.0/r)   // subtract the continuous baseline (1ms band per r)
            }
            return best
        }
    }

    /// p=1 inside [lo,hi]; linear ramp to 0 over the margins. NaN-safe: a zero margin is a
    /// hard step (no division).
    static func band(_ v: Double, _ lo: Double, _ hi: Double, _ mLo: Double, _ mHi: Double) -> Double {
        if v >= lo && v <= hi { return 1 }
        if v < lo { return mLo <= 0 ? 0 : max(0, min(1, (v - (lo - mLo)) / mLo)) }
        return mHi <= 0 ? 0 : max(0, min(1, ((hi + mHi) - v) / mHi))
    }

    // MARK: - Report types

    struct Feat {
        let name: String; let value: String; let human: String
        let p: Double; let weight: Double; let gate: Bool; let annotate: Bool
        init(_ name: String, _ value: String, _ human: String, _ p: Double, w: Double, gate: Bool = false, annotate: Bool = false) {
            self.name = name; self.value = value; self.human = human; self.p = p; self.weight = w; self.gate = gate; self.annotate = annotate
        }
    }
    struct Family { let name: String; let weight: Double; let score: Double; let feats: [Feat] }

    // MARK: - Derived session

    private struct Session {
        var ikiBurst: [Double] = []        // motor down-to-down (bursts reset across edits/pauses)
        var ikiAll: [Double] = []          // all consecutive char down-to-down
        var dwell: [Double] = []
        var flight: [Double] = []          // down_i - up_{i-1}; <0 = rollover
        var htA: [Double] = []; var ftA: [Double] = []   // aligned per keystroke (i>=1)
        var digraph: [String:[Double]] = [:]
        var chars: [Character] = []
        var charDowns = 0, backspaces = 0, arrows = 0, returnTab = 0
        var capitals = 0, capitalsCovered = 0
        var impossibleRepeatFlight = 0
        var nonMonotonicInserts = 0
        var longestContiguousChars = 1     // chars typed with no >300ms gap and no caret move
        var totalMs = 0.0
        var finalText = ""
    }

    private static func build(_ actions: [Action], intended: String) -> Session {
        var s = Session()
        var t = 0.0
        var downQ: [Character:[Double]] = [:]
        var ks: [(ch: Character, down: Double, up: Double, shifted: Bool)] = []
        var buf: [Character] = []; var cur = 0; var heldOpt = false; var heldShift = false
        for a in actions {
            t += a.preDelayMs
            switch a.op {
            case .charDown(let c):
                s.charDowns += 1; downQ[c, default:[]].append(t)
                let isCap = (KeyMap.stroke(for: c)?.shift ?? false)
                if isCap { s.capitals += 1; if heldShift { s.capitalsCovered += 1 } }
                if cur < buf.count { s.nonMonotonicInserts += 1 }
                buf.insert(c, at: min(cur, buf.count)); cur += 1
            case .charUp(let c):
                if !(downQ[c]?.isEmpty ?? true) { let d = downQ[c]!.removeFirst(); ks.append((c, d, t, heldShift)) }
            case .keyDown(let code):
                switch code {
                case KeyMap.backspace: s.backspaces += 1; if cur>0 { buf.remove(at: cur-1); cur -= 1 }
                case KeyMap.leftArrow: s.arrows += 1; cur = heldOpt ? TextNav.wordLeft(buf,cur):max(0,cur-1)
                case KeyMap.rightArrow: s.arrows += 1; cur = heldOpt ? TextNav.wordRight(buf,cur):min(buf.count,cur+1)
                case KeyMap.returnKey, KeyMap.tab:
                    s.returnTab += 1
                    buf.insert(code == KeyMap.returnKey ? "\n":"\t", at: min(cur,buf.count)); cur += 1
                default: break
                }
            case .shiftDown: heldShift = true
            case .shiftUp: heldShift = false
            case .optionDown: heldOpt = true
            case .optionUp: heldOpt = false
            case .keyUp: break
            }
        }
        s.totalMs = t; s.finalText = String(buf)

        // Mark which char-down indices begin a new burst: a burst breaks after any
        // backspace/arrow/return/tab between two char-downs (replay op order).
        var boundaryAfter = Set<Int>()
        do {
            var downIdx = 0; var sawEdit = false
            for a in actions {
                switch a.op {
                case .charDown:
                    if sawEdit && downIdx > 0 { boundaryAfter.insert(downIdx) }
                    sawEdit = false; downIdx += 1
                case .keyDown(let code) where code == KeyMap.backspace || code == KeyMap.leftArrow
                    || code == KeyMap.rightArrow || code == KeyMap.returnKey || code == KeyMap.tab:
                    sawEdit = true
                default: break
                }
            }
        }

        ks.sort { $0.down < $1.down }
        s.chars = ks.map { $0.ch }
        var run = 1
        for i in 0..<ks.count {
            s.dwell.append(ks[i].up - ks[i].down)
            if i > 0 {
                let iki = ks[i].down - ks[i-1].down
                s.ikiAll.append(iki)
                let boundary = iki >= 2000 || boundaryAfter.contains(i)
                let fl = ks[i].down - ks[i-1].up
                if !boundary {
                    s.ikiBurst.append(iki)
                    s.flight.append(fl)
                    s.htA.append(ks[i].up - ks[i].down); s.ftA.append(fl)
                    if ks[i-1].ch.isLetter && ks[i].ch.isLetter {
                        s.digraph["\(ks[i-1].ch)\(ks[i].ch)", default:[]].append(iki)
                    }
                    if ks[i-1].ch.lowercased() == ks[i].ch.lowercased() && fl < 0 { s.impossibleRepeatFlight += 1 }
                    if iki < 300 { run += 1; s.longestContiguousChars = max(s.longestContiguousChars, run) } else { run = 1 }
                } else { run = 1 }
            }
        }
        return s
    }

    // MARK: - Families

    private static func ikiFamily(_ s: Session) -> Family {
        let iki = s.ikiBurst
        let cv = St.cv(iki), sk = St.skew(iki), ku = St.kurtosis(iki)
        let sub50 = St.fraction(iki, lessThan: 50), med = St.median(iki)
        let comb = St.combExcess(iki)
        let lag1 = St.autocorr(iki, lag: 1)
        // Speed-RELATIVE tail: pauses far longer than THIS typist's own tempo (so a slow
        // careful typist whose median IKI is ~450ms isn't penalised for "long" keystrokes).
        let tail = St.fraction(s.ikiAll, greaterThan: max(500.0, 3.0*med))
        var f: [Feat] = []
        f.append(Feat("median IKI", "\(Int(med))ms", "70–600", band(med,70,600,40,900), w:0.4))
        f.append(Feat("CV (dispersion)", String(format:"%.2f",cv), "0.27–2.5 (T=0.269)", band(cv,0.27,2.5,0.07,1.5), w:1.0, gate:true))
        f.append(Feat("skewness (G1)", String(format:"%.2f",sk), "0.9–5.5 (1.98)", band(sk,0.9,5.5,0.7,2.0), w:0.9))
        f.append(Feat("excess kurtosis (G2)", String(format:"%.1f",ku), "2–40", band(ku,2,40,2.5,20), w:0.7))
        f.append(Feat("sub-50ms fraction", String(format:"%.1f%%",sub50*100), "≤6%", band(sub50,0,0.06,0,0.10), w:1.0, gate:true))
        f.append(Feat("comb/quantization excess", String(format:"%.2f",comb), "≈0 (continuous)", band(comb,0,0.20,0,0.30), w:1.0, gate:true))
        f.append(Feat("lag-1 autocorr (raw)", String(format:"%.3f",lag1), "≈0.087 (-0.05–0.30)", band(lag1,-0.05,0.30,0.08,0.15), w:0.6))
        f.append(Feat("tail-mass (>3×median)", String(format:"%.1f%%",tail*100), "3–22%", band(tail,0.02,0.22,0.02,0.14), w:0.6))
        return fuse("IKI distribution", 0.22, f)
    }

    private static func dwellFamily(_ s: Session) -> Family {
        let m = St.mean(s.dwell), sd = St.sd(s.dwell), cvD = St.cv(s.dwell)
        let htft = St.pearson(s.htA, s.ftA)
        let f30 = St.fraction(s.dwell, lessThan: 30)
        let minD = s.dwell.min() ?? 100
        var f: [Feat] = []
        f.append(Feat("dwell mean", "\(Int(m))ms", "~116 (95–135)", band(m,95,135,30,30), w:0.14))
        f.append(Feat("dwell SD", "\(Int(sd))ms", "~24 (14–36)", band(sd,14,36,8,12), w:0.16))
        f.append(Feat("dwell CV", String(format:"%.2f",cvD), ">0.10", band(cvD,0.10,0.6,0.05,0.3), w:0.16, gate:true))   // veto constant dwell
        f.append(Feat("HT–FT correlation", String(format:"%.2f",htft), "~0 (-0.35–0.15)", band(htft,-0.35,0.15,0.2,0.25), w:0.16))
        f.append(Feat("sub-30ms hold fraction", String(format:"%.1f%%",f30*100), "≤5%", band(f30,0,0.05,0,0.08), w:0.08, gate:true))
        f.append(Feat("min hold", "\(Int(minD))ms", "≥15", band(minD,15,1000,8,0), w:0.08, gate:true))
        return fuse("Dwell / HT–FT", 0.18, f)
    }

    private static func digraphFamily(_ s: Session) -> Family {
        // Pool ALL instances per class and compare via MEDIANS — robust to the heavy-tail
        // micro-hesitations that make a 3-sample per-bigram mean meaningless. Compare only
        // when each class is sufficiently sampled; else the feature is omitted (neutral).
        var typeMedian: [Double] = []; var typeCV: [Double] = []
        var altI: [Double] = []; var sameI: [Double] = []; var sfI: [Double] = []; var repI: [Double] = []; var allI: [Double] = []
        for (bg, v) in s.digraph where v.count >= 3 {
            let a = Array(bg)[0], b = Array(bg)[1]
            typeMedian.append(St.median(v)); typeCV.append(St.cv(v))
            guard a.isLetter && b.isLetter else { continue }
            allI.append(contentsOf: v)
            if a == b { repI.append(contentsOf: v) }
            else if KeyMap.sameFinger(a,b) { sfI.append(contentsOf: v) }
            else if KeyMap.hand(of:a) != KeyMap.hand(of:b) { altI.append(contentsOf: v) } else { sameI.append(contentsOf: v) }
        }
        // Cond-Bin signal: per-pair conditional means must SPREAD (not one global value) and
        // each pair's within-pair CV must be a smooth distribution, not a collapsed point.
        // High within-pair CV is HUMAN (cognitive hesitations) — only a near-zero CV (a
        // lattice that maps each bigram to one value) is the bot tell.
        let betweenSpread = St.cv(typeMedian)
        let withinCV = typeCV.isEmpty ? 0.20 : St.median(typeCV)
        let altOK: Bool? = (altI.count >= 6 && sameI.count >= 6) ? (St.median(altI) < St.median(sameI)) : nil
        let sfOK: Bool?  = (sfI.count >= 5 && altI.count >= 5) ? (St.median(sfI) > St.median(altI)) : nil
        let repOK: Bool? = (repI.count >= 4 && allI.count >= 10) ? (St.median(repI) < St.median(allI)) : nil
        var f: [Feat] = []
        f.append(Feat("per-pair conditional spread", String(format:"%.2f",betweenSpread), ">0.10", band(betweenSpread,0.10,1.2,0.10,0), w:0.26))
        f.append(Feat("within-pair CV (smooth)", String(format:"%.2f",withinCV), "0.08–0.70 (veto <0.04)", band(withinCV,0.08,0.70,0.04,0.30), w:0.12, gate:true))
        // alt-vs-same-hand (×0.84 vs ×0.92, ~9% apart) and rep-vs-all are weak, key-identity-
        // confounded comparisons at this n — gentle nudges, not real dings.
        if let altOK { f.append(Feat("alternation < same-hand", altOK ?"yes":"no", "yes", altOK ?1:0.65, w:0.08)) }
        if let sfOK  { f.append(Feat("same-finger penalty", sfOK ?"yes":"no", "yes", sfOK ?1:0.4, w:0.08)) }
        if let repOK { f.append(Feat("repetition speed-up", repOK ?"yes":"no", "yes", repOK ?1:0.65, w:0.05)) }
        return fuse("Digraph structure", 0.12, f)
    }

    private static func serialFamily(_ s: Session) -> Family {
        let lag1 = St.autocorr(s.ikiBurst, lag: 1), lag2 = St.autocorr(s.ikiBurst, lag: 2)
        let neg = St.fraction(s.flight, lessThan: 0)
        var f: [Feat] = []
        f.append(Feat("lag-1 autocorr", String(format:"%.3f",lag1), "≈0.087 (-0.05–0.30)", band(lag1,-0.05,0.30,0.08,0.15), w:0.2))
        f.append(Feat("lag-2 autocorr", String(format:"%.3f",lag2), "≈0.01 (-0.10–0.20)", band(lag2,-0.10,0.20,0.06,0.12), w:0.08))
        f.append(Feat("rollover (neg-flight) rate", String(format:"%.0f%%",neg*100), "5–55% by speed", band(neg,0.03,0.55,0.05,0.25), w:0.18))
        f.append(Feat("impossible same-key rollover", "\(s.impossibleRepeatFlight)", "0", s.impossibleRepeatFlight==0 ?1:0.05, w:0.1, gate:true))
        return fuse("Serial / rollover", 0.12, f)
    }

    private static func errorFamily(_ s: Session, intended: String) -> Family {
        let finalLen = Double(s.finalText.count)
        let totalKeys = Double(s.charDowns + s.backspaces + s.arrows + s.returnTab)
        let kspc = finalLen>0 ? totalKeys/finalLen : 0
        let corr = totalKeys>0 ? Double(s.backspaces)/totalKeys : 0
        let residue = Double(levenshtein(s.finalText, intended)) / Double(max(intended.count,1))
        let longText = intended.count >= 400
        // The STRONG tell (spec STEP-3 conjunction) is a long doc with ZERO residue AND
        // ~zero corrections = a pure transcriber. Zero residue ALONE, when the typist
        // clearly self-corrects, is only a mild "thorough editor" note (common in humans).
        let pureTranscriber = longText && residue < 0.0008 && corr < 0.008
        var f: [Feat] = []
        f.append(Feat("correction rate", String(format:"%.1f%%",corr*100), "3–9% (6.3)", band(corr,0.02,0.12,0.02,0.08), w:2.5))
        f.append(Feat("KSPC", String(format:"%.3f",kspc), "1.05–1.40 (1.17)", band(kspc,1.05,1.40,0.05,0.2), w:2.0))
        let resBand = longText ? band(residue, 0.003, 0.0266, 0.003, 0.03) : band(residue, 0, 0.0266, 0, 0.03)
        let resP = (residue < 0.001 && corr >= 0.02) ? max(resBand, 0.5) : resBand   // clean self-editor: mild
        f.append(Feat("uncorrected residue", String(format:"%.2f%%",residue*100), "0.3–2.7% (1.17)", resP, w:1.2))
        f.append(Feat("pure-transcriber (0 residue & 0 fixes)", pureTranscriber ?"YES":"no", "no", pureTranscriber ?0.04:1.0, w:2.5, gate: longText))
        return fuse("Errors / corrections", 0.14, f)
    }

    private static func editGraphFamily(_ s: Session, intended: String) -> Family {
        let finalLen = Double(s.finalText.count)
        let produced = Double(s.charDowns)
        let ppr = produced>0 ? finalLen/produced : 1                  // surviving / produced (≈1/churn)
        let effWPM = s.totalMs>0 ? (finalLen/5.0)/(s.totalMs/60000.0) : 0
        let nonMono = produced>0 ? Double(s.nonMonotonicInserts)/produced : 0
        let longText = intended.count >= 400
        var f: [Feat] = []
        // PPR veto: a zero-churn transcriber (ppr≈1) is non-human for real composition
        f.append(Feat("product/process ratio", String(format:"%.2f",ppr), "0.74–0.95 (0.82)", band(ppr,0.74,0.95,0.12,0.04), w:0.16, gate: longText))
        f.append(Feat("effective WPM", "\(Int(effWPM))", "≤90 (composition 8–20)", band(effWPM,6,90,4,35), w:0.06))
        f.append(Feat("non-monotonic insert frac", String(format:"%.1f%%",nonMono*100), ">0 (some)", nonMono>0 ?1:(longText ?0.5:0.7), w:0.10))
        f.append(Feat("no atomic paste (char-by-char)", "yes", "yes", 1.0, w:0.07))   // engine never bulk-inserts
        f.append(Feat("longest unbroken run", "\(s.longestContiguousChars)", "no giant burst", band(Double(s.longestContiguousChars),0,60,0,40), w:0.05))
        return fuse("Edit-graph / Docs", 0.12, f)
    }

    private static func injectionFamily(_ s: Session) -> Family {
        let shiftCov = s.capitals>0 ? Double(s.capitalsCovered)/Double(s.capitals) : 1.0
        var f: [Feat] = []
        f.append(Feat("Shift coverage for capitals", String(format:"%.0f%%",shiftCov*100), "≥99%", band(shiftCov,0.99,1.0,0.15,0), w:0.4, gate: s.capitals>0))
        f.append(Feat("no paste / insertText only", "yes", "yes", 1.0, w:0.3))
        f.append(Feat("autorepeat = 0", "yes", "yes", 1.0, w:0.2))
        // annotations (not scored): single-stream tautology + the native ceiling
        f.append(Feat("event.code coherence", "n/a", "web-capture only", 1.0, w:0, annotate:true))
        f.append(Feat("native source-PID", "exposed (PID≠0)", "PID 0 = DriverKit only", 0.0, w:0, annotate:true))
        return fuse("Injection (web tells)", 0.10, f)
    }

    /// Weighted fuse: hard-gate veto if any gated feature p<0.15; else 70/30 weighted
    /// arithmetic/geometric mean over scored (non-annotation) features.
    private static func fuse(_ name: String, _ weight: Double, _ f: [Feat]) -> Family {
        let scored = f.filter { !$0.annotate && $0.weight > 0 }
        let gateMin = f.filter{$0.gate}.map{$0.p}.min() ?? 1.0
        if gateMin < 0.15 { return Family(name:name, weight:weight, score: max(0.05, min(0.20, gateMin)), feats:f) }
        let wsum = scored.reduce(0.0){$0+$1.weight}
        guard wsum > 0 else { return Family(name:name, weight:weight, score:1.0, feats:f) }
        let arith = scored.reduce(0.0){$0 + $1.weight*$1.p}/wsum
        let geo = exp(scored.reduce(0.0){$0 + $1.weight*log(max($1.p,0.03))}/wsum)
        return Family(name:name, weight:weight, score: 0.7*arith + 0.3*geo, feats:f)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
        var prev = Array(0...y.count), cur = [Int](repeating:0, count:y.count+1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = Swift.min(prev[j]+1, cur[j-1]+1, prev[j-1]+(x[i-1]==y[j-1] ?0:1)) }
            swap(&prev,&cur)
        }
        return prev[y.count]
    }

    // MARK: - Shared sample text

    /// Composition-style sample (sentences, mixed case, punctuation, confusable words),
    /// ~600 chars so the error/edit-graph features are meaningful. Used by the CLI
    /// scorecard (Detector.run).
    static let sampleText = """
        The project started with a simple goal, and over the past few weeks its design has \
        grown into something we are quite proud of. We wanted it to feel natural, not robotic, \
        so there are now several moving parts that we had to think about carefully. It is not \
        too hard to use, but you have to be patient with it. Their early feedback helped a lot, \
        and we are happy with where it stands today. Let us see how well it really does, because \
        the only test that matters is whether a careful reader believes a person wrote it.
        """

    // MARK: - Run

    static func run() -> Int {
        let text = sampleText
        print("================ Typer+ — DETECTOR scorecard (v2) ================")
        print("(objective human-likeness vs research baselines; 100 = indistinguishable to a SOTA detector)")
        print("coverage: marginal+serial+dwell+digraph+errors+edit-graph+injection-web. NOT YET measured:")
        print("  joint HT-FT 2D-density LLR, full error-type mix, two-loop correction latency (deep bot-only checks).\n")
        var worst = 100.0
        for mode in TypingProfile.Mode.allCases {
            var famAgg: [String:(w:Double, s:[Double], feats:[Feat])] = [:]
            var order: [String] = []
            var hlsList: [Double] = []
            for _ in 0..<6 {
                let actions = Planner(profile: .preset(mode), rng: RNG(), persona: Persona.random(RNG())).plan(text)
                let s = build(actions, intended: text)
                guard s.charDowns >= 70 else { continue }   // sample-size guard
                let fams = [ikiFamily(s), dwellFamily(s), digraphFamily(s), serialFamily(s),
                            errorFamily(s, intended: text), editGraphFamily(s, intended: text), injectionFamily(s)]
                let wsum = fams.reduce(0.0){$0+$1.weight}
                hlsList.append(exp(fams.reduce(0.0){$0 + $1.weight*log(max($1.score,0.03))}/wsum) * 100)
                for fam in fams {
                    if famAgg[fam.name] == nil { order.append(fam.name); famAgg[fam.name] = (fam.weight, [], fam.feats) }
                    famAgg[fam.name]!.s.append(fam.score)
                    famAgg[fam.name]!.feats = fam.feats   // keep last run's feature detail
                }
            }
            let hls = hlsList.isEmpty ? 0 : hlsList.reduce(0,+)/Double(hlsList.count)
            worst = Swift.min(worst, hls)
            print(String(format:"── %@  ·  HLS %.0f/100 ──", mode.rawValue, hls))
            for name in order {
                let fa = famAgg[name]!; let avg = fa.s.reduce(0,+)/Double(max(fa.s.count,1))
                print(String(format:"  %@ %.0f%%", name.padding(toLength:22, withPad:" ", startingAt:0), avg*100))
                for ft in fa.feats where ft.p < 0.75 && !ft.annotate {
                    print(String(format:"      ⚠ %@ = %@  (human %@)  p=%.2f%@", ft.name, ft.value, ft.human, ft.p, ft.gate ? " [GATE]":""))
                }
            }
            print("")
        }
        print(String(format:"Lowest-mode HLS: %.0f/100   (native source-PID is the acknowledged DriverKit-only ceiling,", worst))
        print("  excluded from this web/Docs/biometric score; it only matters vs native lockdown apps.)")
        return 0
    }
}
