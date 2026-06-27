import Foundation

/// Open-ended error generation. Crucially this is NOT a fixed misspelling table
/// (that is a catalog-able fingerprint — RESEARCH.md §4 tell #8). Slips are
/// generated from a spatial + sequence model:
///   • ~55% of substitutions are physically adjacent keys ("fat-finger"),
///   • the type mix (substitution > omission > insertion, + rarer transposition /
///     doubling) matches Dhakal §3.3,
///   • word-initial characters are (almost) never corrupted,
///   • corrections follow a two-loop model: most caught immediately, some after a
///     few more keys. (Char-level residue is OFF in every shipped preset —
///     `uncorrectedResidue == 0` — so the everyday output is clean; the `.leave`
///     path remains for a future mode that wants a small left-in residue.)
/// The grammar/homophone layer is keyed on linguistic confusables (rule-based),
/// left mid-stream and fixed in the end-of-text review pass.
enum Typos {

    enum Kind { case substitution, omission, insertion, doubling, transposition }

    enum Correction {
        case immediate          // notice within 0–1 chars, backspace now
        case delayed            // type a few more chars, then backspace back and fix
        case leave              // residue — left in the final text
    }

    struct Plan {
        let kind: Kind
        let typed: [Character]      // what to actually type now (the slip)
        let intended: [Character]   // what those positions should be
        let consumesNext: Bool      // transposition also consumed the next source char
        let correction: Correction
    }

    /// Decide whether `intended` triggers a character-level slip.
    /// `atWordStart` suppresses errors on the first letter of a word.
    static func charSlip(intended: Character,
                         next: Character?,
                         atWordStart: Bool,
                         profile: TypingProfile,
                         persona: Persona,
                         rng: RNG) -> Plan? {
        guard intended.isLetter, !atWordStart else { return nil }
        // Per-person error-proneness: the stable persona scales the mode's base typo rate,
        // so two "people" on the same mode make errors at different rates (resists a
        // population-mean forgery detector). Capped so it can never reach certainty.
        guard rng.bernoulli(min(0.95, profile.typoRate * persona.typoScale)) else { return nil }

        let kind = pickKind(next: next, rng: rng)
        let typed: [Character]
        var intendedRun: [Character] = [intended]
        var consumesNext = false

        switch kind {
        case .substitution:
            let wrong = substituteChar(intended, rng: rng)
            typed = [wrong]
        case .omission:
            typed = []                              // skipped the key
        case .insertion:
            let extra = KeyMap.adjacent(to: intended, rng: rng) ?? intended
            typed = [extra, intended]               // stray key before the real one
        case .doubling:
            typed = [intended, intended]
        case .transposition:
            guard let n = next, n.isLetter, n != intended else {
                // fall back to a substitution if we can't swap
                return Plan(kind: .substitution, typed: [substituteChar(intended, rng: rng)],
                            intended: [intended], consumesNext: false,
                            correction: correctionStyle(kind: .substitution, profile: profile, rng: rng))
            }
            typed = [n, intended]                   // swapped order
            intendedRun = [intended, n]
            consumesNext = true
        }

        return Plan(kind: kind, typed: typed, intended: intendedRun,
                    consumesNext: consumesNext,
                    correction: correctionStyle(kind: kind, profile: profile, rng: rng))
    }

    private static func pickKind(next: Character?, rng: RNG) -> Kind {
        // Weights ≈ Dhakal single-char mix (sub:53 omit:26 ins:21) + rare doubling
        // / transposition. Transposition only viable with a following letter.
        let canTranspose = (next?.isLetter ?? false)
        let r = rng.unit()
        switch r {
        case ..<0.46: return .substitution
        case ..<0.68: return .omission
        case ..<0.86: return .insertion
        case ..<0.93: return .doubling
        default:      return canTranspose ? .transposition : .substitution
        }
    }

    /// ~55% adjacent-key, otherwise a random letter (case-preserved).
    private static func substituteChar(_ ch: Character, rng: RNG) -> Character {
        if rng.bernoulli(0.55), let adj = KeyMap.adjacent(to: ch, rng: rng) { return adj }
        let letters = ch.isUppercase ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "abcdefghijklmnopqrstuvwxyz"
        let pool = Array(letters).filter { $0 != ch }   // guarantee a different char
        return rng.element(pool) ?? ch
    }

    private static func correctionStyle(kind: Kind, profile: TypingProfile, rng: RNG) -> Correction {
        // Transpositions are virtually always corrected (they read as nonsense).
        let residue = kind == .transposition ? 0 : profile.uncorrectedResidue
        if rng.bernoulli(residue) { return .leave }
        // Max Speed (delaysCorrections == false) never leaves a typo to fix later — it
        // corrects on the spot, never the look-ahead/go-back path.
        if !profile.delaysCorrections { return .immediate }
        return rng.bernoulli(profile.immediateCorrectProb) ? .immediate : .delayed
    }

    // MARK: - Grammar / homophone layer (rule-based confusables)

    /// Confusable variants keyed on the intended token (lowercased) — MULTIPLE plausible
    /// wrong variants per token, drawn at random, so the grammar-error set varies per run
    /// (open-ended, not an enumerable catalog).
    private static let confusables: [String: [String]] = [
        "its": ["it's"], "it's": ["its"],
        "your": ["you're"], "you're": ["your"],
        "their": ["there", "they're"], "there": ["their", "they're"], "they're": ["their", "there"],
        "then": ["than"], "than": ["then"],
        "to": ["too"], "too": ["to", "two"], "two": ["too", "to"],
        "affect": ["effect"], "effect": ["affect"],
        "lose": ["loose"], "loose": ["lose"],
        "whose": ["who's"], "who's": ["whose"],
        "accept": ["except"], "except": ["accept"],
        "weather": ["whether"], "whether": ["weather"],
        "advice": ["advise"], "advise": ["advice"],
        "principal": ["principle"], "principle": ["principal"],
        "complement": ["compliment"], "compliment": ["complement"],
        "stationary": ["stationery"], "stationery": ["stationary"],
        "of": ["off"], "off": ["of"],
        "quiet": ["quite"], "quite": ["quiet"],
        "where": ["were", "wear"], "were": ["where", "we're"], "we're": ["were"],
        "passed": ["past"], "past": ["passed"],
        "lead": ["led"], "led": ["lead"]
    ]

    /// Article swaps generated by rule (a ↔ an ↔ the) — common human slips, not a catalog.
    private static let articleSwaps: [String: [String]] = [
        "a": ["an", "the"], "an": ["a", "the"], "the": ["a"]
    ]

    /// A wrong-but-plausible variant for `word`, or nil. Preserves a leading capital.
    static func confusableVariant(for word: String, rng: RNG) -> String? {
        // Normalize a curly apostrophe (U+2019, common in text pasted from Docs/web) to a
        // straight one for the LOOKUP only, so "it's"/"you're" etc. still match the table.
        // The typed output is unaffected (we return table values / the original word).
        let lower = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard let pool = confusables[lower] ?? articleSwaps[lower], let wrong = rng.element(pool) else { return nil }
        if let first = word.first, first.isUppercase {
            return wrong.prefix(1).uppercased() + wrong.dropFirst()
        }
        return wrong
    }
}
