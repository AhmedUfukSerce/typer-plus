import Foundation

/// A stable per-"person" fingerprint layered on top of a mode's population means.
/// Real keystroke biometrics reject population-mean / i.i.d. forgeries (TUBA), and
/// target-informed detectors expect a *consistent individual* — so we seed one
/// persona, persist it (same "person" across runs), and let the per-keystroke RNG
/// supply run-to-run variation (never an identical stream — anti-replay).
struct Persona: Codable {
    var ikiScale: Double      // overall speed (scales IKI mean)
    var dwellScale: Double    // hold-time mean
    var cvScale: Double       // spread (scales IKI sigma/tau)
    var leftBias: Double      // per-hand IKI bias
    var rightBias: Double
    var typoScale: Double     // error-proneness

    static let neutral = Persona(ikiScale: 1, dwellScale: 1, cvScale: 1,
                                 leftBias: 1, rightBias: 1, typoScale: 1)

    static func random(_ rng: RNG) -> Persona {
        func cl(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(v, lo), hi) }
        return Persona(
            ikiScale: cl(rng.normal(1.0, 0.15), 0.72, 1.30),
            dwellScale: cl(rng.normal(1.0, 0.12), 0.78, 1.30),
            cvScale: cl(rng.normal(1.0, 0.10), 0.82, 1.25),
            leftBias: cl(rng.normal(1.0, 0.05), 0.90, 1.10),
            rightBias: cl(rng.normal(1.0, 0.05), 0.90, 1.10),
            typoScale: cl(rng.normal(1.0, 0.25), 0.50, 1.70)
        )
    }
}
