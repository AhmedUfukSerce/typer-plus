import Foundation

/// Normalizes pasted text before it is handed to the planner/engine. ONE shared
/// entry point used by BOTH the bubble and the main app, so what you see typed is
/// identical no matter where you paste it.
///
/// Why this exists: pasted text (especially from Slack/Docs/web/PDF) carries
/// invisible junk — zero-width chars, non-breaking spaces, exotic unicode spaces,
/// CRLF / lone CR line endings, runs of trailing spaces, and arbitrarily deep
/// blank-line stacks. Typing that verbatim both looks robotic and slows the run.
///
/// Design notes:
///   • Pure, deterministic, no side effects — trivially unit-testable.
///   • Default-on but gated by `Settings.cleanupEnabled`; the *only* public call
///     site is `clean(_:)`, which short-circuits to identity when the toggle is off.
///   • Conservative: it never changes the *words*, only normalizes whitespace and
///     strips invisibles. It deliberately does NOT touch typographic quotes/dashes
///     (the engine types those fine and the user may want them).
enum TextCleanup {

    /// Settings-gated public entry point. Call this everywhere text enters the
    /// typing pipeline. Returns the input unchanged when cleanup is disabled.
    static func clean(_ text: String, enabled: Bool = Settings.shared.cleanupEnabled) -> String {
        guard enabled else { return text }
        return normalize(text)
    }

    /// The unconditional transform (exposed for tests / previews). Steps run in an
    /// order chosen so each one sees the output of the previous (e.g. exotic spaces
    /// become ordinary spaces BEFORE multi-space collapsing runs).
    static func normalize(_ text: String) -> String {
        var s = text

        // 1. Normalize newlines: CRLF and lone CR → LF. Also fold the Unicode line/
        //    paragraph separators (U+2028 / U+2029) and the vertical tab / form feed
        //    that some sources emit instead of a newline.
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r",   with: "\n")
        for sep in ["\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}", "\u{0085}"] {
            s = s.replacingOccurrences(of: sep, with: "\n")
        }

        // 2. Strip zero-width / formatting invisibles outright (no replacement). These
        //    are pure noise that would cost keystrokes and can confuse target fields:
        //    ZWSP, ZWNJ, ZWJ, WORD JOINER, BOM/ZWNBSP, the bidi marks, and the
        //    invisible soft hyphen.
        for zw in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
                   "\u{200E}", "\u{200F}", "\u{00AD}"] {
            s = s.replacingOccurrences(of: zw, with: "")
        }

        // 3. Fold "exotic" horizontal whitespace to a plain ASCII space. Covers the
        //    non-breaking space (#1 offender from web/Docs), narrow/figure/thin/hair
        //    spaces, the em/en/ideographic spaces, and the tab. Newlines are NOT in
        //    this set, so paragraph structure survives.
        for ws in ["\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}",
                   "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}",
                   "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}",
                   "\u{3000}", "\t"] {
            s = s.replacingOccurrences(of: ws, with: " ")
        }

        // 4. Per-line cleanup: collapse runs of 2+ spaces to one, and trim trailing
        //    spaces. Done line-by-line so we never collapse a newline into a space.
        //    `omittingEmptySubsequences: false` preserves blank lines for step 5.
        let collapsed = s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseSpaces(in: String($0)) }
            .joined(separator: "\n")
        s = collapsed

        // 5. Cap consecutive blank lines: never type more than ONE empty line in a row
        //    (i.e. at most one blank line between paragraphs → "\n\n").
        s = capBlankLines(s, maxConsecutiveBlank: 1)

        // 6. Final trim of leading/trailing whitespace+newlines around the whole block.
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        return s
    }

    // MARK: - Helpers

    /// Normalize one line: STRIP leading indentation entirely, collapse any run of 2+
    /// spaces to one, and trim trailing spaces. So "        weird   indent  " → "weird
    /// indent" — pasted text comes out clean and left-aligned, like dropping it into a
    /// browser search bar (no stray indentation surviving from PDFs/Docs/code blocks).
    private static func collapseSpaces(in line: String) -> String {
        var out = String(); out.reserveCapacity(line.count)
        // Start "in a space run" so any LEADING spaces are dropped (full de-indent).
        var lastWasSpace = true
        for ch in line {
            if ch == " " {
                if !lastWasSpace { out.append(ch) }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Reduce any stack of >`maxConsecutiveBlank` blank lines down to that many.
    private static func capBlankLines(_ s: String, maxConsecutiveBlank: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []; out.reserveCapacity(lines.count)
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= maxConsecutiveBlank { out.append(line) }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
