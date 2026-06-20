import CoreGraphics

/// US-QWERTY mapping + keyboard geometry the engine needs:
///   • virtual keycodes (+ whether Shift is required) for the keycode text path
///     and for special keys (backspace, arrows, return, tab),
///   • hand assignment per letter (for bigram timing classification),
///   • physical adjacency (for open-ended "fat-finger" typo generation).
///
/// The default text path is Unicode (layout-independent, virtualKey 0), so the
/// keycode table is used for special keys and the optional keycode text path.
enum KeyMap {

    // MARK: Special-key virtual keycodes (kVK_*)

    static let backspace: CGKeyCode = 51   // kVK_Delete (the Delete/Backspace key)
    static let forwardDelete: CGKeyCode = 117
    static let returnKey: CGKeyCode = 36
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let escape: CGKeyCode = 53
    static let shift: CGKeyCode = 56       // kVK_Shift (left shift)
    static let option: CGKeyCode = 58      // kVK_Option (left option/alt) — for ⌥← word jumps
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126

    // MARK: Char → (keycode, needsShift)

    /// Base (unshifted) character for each US keycode.
    private static let baseChars: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
        " ": space, "\t": tab, "\n": returnKey
    ]

    /// Shifted character → the base character whose key + Shift produces it.
    private static let shiftedToBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    /// The keycode + Shift requirement for `ch`, or nil if it has no US-QWERTY key
    /// (e.g. é, em-dash, emoji) — those go through the Unicode path instead.
    static func stroke(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
        if let code = baseChars[ch] { return (code, false) }
        if let lower = ch.lowercased().first, ch.isUppercase, let code = baseChars[lower] {
            return (code, true)
        }
        if let base = shiftedToBase[ch], let code = baseChars[base] { return (code, true) }
        return nil
    }

    /// A plausible physical key for a character that has no direct US-QWERTY key
    /// (accents, em/en dash, smart quotes, ellipsis). Used so the injected event still
    /// carries a real `event.code` while the Unicode string supplies the true glyph.
    private static let unicodeFallback: [Character: CGKeyCode] = [
        "\u{2014}": 27, "\u{2013}": 27,                 // em/en dash → hyphen key
        "\u{2026}": 47,                                  // ellipsis → period key
        "\u{2018}": 39, "\u{2019}": 39,                 // smart single quotes → ' key
        "\u{201C}": 39, "\u{201D}": 39                  // smart double quotes → ' key
    ]

    static func fallbackCode(for ch: Character) -> CGKeyCode {
        if let c = unicodeFallback[ch] { return c }
        // Accented latin letter → its base-letter key (é → e, ñ → n, …).
        let folded = String(ch).folding(options: .diacriticInsensitive, locale: nil)
        if let base = folded.lowercased().first, base.isLetter, base.isASCII,
           let s = stroke(for: base) {
            return s.code
        }
        // Last resort (emoji / non-Latin): a stable plausible letter key, so the event
        // NEVER carries an empty event.code (a key with no physical key is impossible on
        // real hardware). True emoji/IME entry is an edge case for a prose typer.
        let letterCodes: [CGKeyCode] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 46, 45, 31, 35,
                                        12, 15, 8, 17, 16, 9, 13, 7, 14, 32, 34, 18, 6]
        return letterCodes[Int(ch.unicodeScalars.first?.value ?? 97) % letterCodes.count]
    }

    // MARK: Hand assignment (letters only; for bigram timing)

    private static let leftHand: Set<Character> = Set("qwertasdfgzxcvb")
    private static let rightHand: Set<Character> = Set("yuiophjklnm")

    enum Hand { case left, right, neutral }

    static func hand(of ch: Character) -> Hand {
        let c = Character(ch.lowercased())
        if leftHand.contains(c) { return .left }
        if rightHand.contains(c) { return .right }
        return .neutral
    }

    // MARK: Physical adjacency (for fat-finger substitutions / insertions)

    private static let neighbors: [Character: [Character]] = [
        "q": ["w", "a", "s"],
        "w": ["q", "e", "a", "s", "d"],
        "e": ["w", "r", "s", "d", "f"],
        "r": ["e", "t", "d", "f", "g"],
        "t": ["r", "y", "f", "g", "h"],
        "y": ["t", "u", "g", "h", "j"],
        "u": ["y", "i", "h", "j", "k"],
        "i": ["u", "o", "j", "k", "l"],
        "o": ["i", "p", "k", "l"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z", "x"],
        "s": ["q", "w", "e", "a", "d", "z", "x", "c"],
        "d": ["w", "e", "r", "s", "f", "x", "c", "v"],
        "f": ["e", "r", "t", "d", "g", "c", "v", "b"],
        "g": ["r", "t", "y", "f", "h", "v", "b", "n"],
        "h": ["t", "y", "u", "g", "j", "b", "n", "m"],
        "j": ["y", "u", "i", "h", "k", "n", "m"],
        "k": ["u", "i", "o", "j", "l", "m"],
        "l": ["i", "o", "p", "k"],
        "z": ["a", "s", "x"],
        "x": ["a", "s", "d", "z", "c"],
        "c": ["s", "d", "f", "x", "v"],
        "v": ["d", "f", "g", "c", "b"],
        "b": ["f", "g", "h", "v", "n"],
        "n": ["g", "h", "j", "b", "m"],
        "m": ["h", "j", "k", "n"]
    ]

    /// A random physically-adjacent key to `ch`, case-preserved. nil if `ch` is not
    /// a letter with known neighbours.
    static func adjacent(to ch: Character, rng: RNG) -> Character? {
        let lower = Character(ch.lowercased())
        guard let opts = neighbors[lower], let pick = rng.element(opts) else { return nil }
        return ch.isUppercase ? Character(pick.uppercased()) : pick
    }

    static func hasNeighbors(_ ch: Character) -> Bool {
        neighbors[Character(ch.lowercased())] != nil
    }

    // MARK: Touch-typing finger assignment (for same-finger digraph penalty)

    // 0-3 = left pinky→index, 4-7 = right index→pinky, 8 = thumb (space).
    private static let fingerByChar: [Character: Int] = [
        "q": 0, "a": 0, "z": 0, "1": 0,
        "w": 1, "s": 1, "x": 1, "2": 1,
        "e": 2, "d": 2, "c": 2, "3": 2,
        "r": 3, "f": 3, "v": 3, "t": 3, "g": 3, "b": 3, "4": 3, "5": 3,
        "y": 4, "h": 4, "n": 4, "u": 4, "j": 4, "m": 4, "6": 4, "7": 4,
        "i": 5, "k": 5, ",": 5, "8": 5,
        "o": 6, "l": 6, ".": 6, "9": 6,
        "p": 7, ";": 7, "/": 7, "0": 7, "-": 7, "=": 7, "[": 7, "]": 7, "'": 7, "\\": 7,
        " ": 8
    ]

    static func finger(of ch: Character) -> Int {
        let c = Character(ch.lowercased())
        if let f = fingerByChar[c] { return f }
        return 100 + Int(c.unicodeScalars.first?.value ?? 0)   // unique; never a real finger
    }

    /// Two consecutive characters typed by the same physical finger (the slowest,
    /// most awkward digraph class — a big latency penalty in real typing).
    static func sameFinger(_ a: Character, _ b: Character) -> Bool {
        let fa = finger(of: a)
        return fa <= 8 && fa == finger(of: b) && a.lowercased() != b.lowercased()
    }

    // MARK: Per-key dwell baselines (ms) — frequent home-row keys are held briefer.

    private static let dwellByChar: [Character: Double] = [
        "e": 70, "t": 75, "a": 80, "o": 85, "i": 80, "n": 75, "s": 80, "h": 85,
        "r": 90, "d": 95, "l": 90, "c": 100, "u": 95, "m": 105, "w": 110, "f": 100,
        "g": 100, "y": 105, "p": 115, "b": 105, "v": 110, "k": 120, "j": 115,
        "x": 125, "q": 130, "z": 120, " ": 80
    ]

    /// Reference mean of the per-key table, used to renormalise to a profile's target
    /// dwell mean. This is the ENGLISH-FREQUENCY-WEIGHTED mean (e/t/a/o/i/n dominate and
    /// are held briefer), not the unweighted table mean (95) — otherwise real prose comes
    /// out ~13% under the profile's target hold time.
    static let dwellReferenceMean: Double = 84

    static func dwellBase(for ch: Character) -> Double {
        dwellByChar[Character(ch.lowercased())] ?? 108   // digits/punctuation: a bit slower
    }
}
