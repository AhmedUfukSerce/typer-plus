import Foundation

/// Random draws for the realism engine. Wraps the system RNG (fresh entropy every
/// run = anti-replay: the same text never produces an identical timing stream).
///
/// The distribution shapes here are the ones RESEARCH.md §3.7/§4 demand:
/// human keystroke timing is right-skewed (ex-Gaussian / log-normal), NEVER
/// Gaussian or uniform — a uniform/normal inter-key interval is the #1 biometric
/// tell. Dwell is the one exception (near-normal), drawn with `truncatedNormal`.
final class RNG {

    private var gen = SystemRandomNumberGenerator()

    /// Uniform in [lo, hi].
    func uniform(_ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return lo }
        return Double.random(in: lo...hi, using: &gen)
    }

    /// Uniform in (0, 1) — open interval, safe for logs.
    func unit() -> Double {
        var u = Double.random(in: 0..<1, using: &gen)
        if u <= 0 { u = 1e-12 }
        return u
    }

    func bernoulli(_ p: Double) -> Bool {
        if p <= 0 { return false }
        if p >= 1 { return true }
        return Double.random(in: 0..<1, using: &gen) < p
    }

    func int(_ lo: Int, _ hi: Int) -> Int {
        guard hi > lo else { return lo }
        return Int.random(in: lo...hi, using: &gen)
    }

    func element<T>(_ array: [T]) -> T? {
        array.randomElement(using: &gen)
    }

    /// Standard normal via Box–Muller.
    func standardNormal() -> Double {
        let u1 = unit()
        let u2 = unit()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }

    func normal(_ mean: Double, _ sd: Double) -> Double {
        mean + sd * standardNormal()
    }

    /// Truncated normal in [lo, hi] (redraw, then clamp as a backstop). Used for
    /// DWELL — the one near-symmetric, low-variance keystroke feature.
    func truncatedNormal(mean: Double, sd: Double, lo: Double, hi: Double) -> Double {
        let a = Swift.min(lo, hi), b = Swift.max(lo, hi)
        for _ in 0..<8 {
            let v = normal(mean, sd)
            if v >= a && v <= b { return v }
        }
        return Swift.min(Swift.max(normal(mean, sd), a), b)
    }

    /// Exponential with the given mean (mean = 1/λ). Source of the right tail.
    func exponential(mean: Double) -> Double {
        guard mean > 0 else { return 0 }
        return -mean * log(unit())
    }

    /// Ex-Gaussian: Gaussian core (μ, σ) + exponential tail (τ). The practical
    /// model for inter-key intervals (RESEARCH.md §2.1). Values under `floor` are
    /// redrawn up to 3× then reflected, so there is no histogram spike at the floor
    /// (a flat pile-up at the minimum is itself a synthetic artifact).
    func exGaussian(mu: Double, sigma: Double, tau: Double, floor: Double) -> Double {
        for _ in 0..<3 {
            let v = normal(mu, sigma) + exponential(mean: tau)
            if v >= floor { return v }
        }
        let v = normal(mu, sigma) + exponential(mean: tau)
        return v >= floor ? v : floor + (floor - v)   // reflect back above the floor
    }

    /// Log-normal with a given median and shape σ (of the underlying normal).
    /// Used for pause magnitudes (word/sentence/thinking), which are heavy-tailed.
    func logNormal(median: Double, sigma: Double) -> Double {
        median * exp(sigma * standardNormal())
    }
}
