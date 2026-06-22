import Foundation
import Carbon.HIToolbox

/// User-tunable knobs, persisted in UserDefaults and read live.
final class Settings {

    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let mode = "mode"
        static let countdownSeconds = "countdownSeconds"
        static let quickCountdownSeconds = "quickCountdownSeconds"
        static let tripleEscWindowMs = "tripleEscWindowMs"
        static let preventDisplaySleep = "preventDisplaySleep"
        static let forceUnicodeOnly = "forceUnicodeOnly"
        static let reliableDelivery = "reliableDelivery"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let persona = "persona"
        // Formatting cleanup.
        static let cleanupEnabled = "cleanupEnabled"
        // Self-made typos/corrections (OFF by default — they can desync vs a field's autocorrect).
        static let humanTyposEnabled = "humanTyposEnabled"
        // Deliver by clipboard paste (⌘V) instead of per-key typing — bulletproof for fragile
        // web/Electron editors (Feather) that drop/duplicate fast synthetic keystrokes.
        static let pasteDelivery = "pasteDelivery"
        // Floating bubble.
        static let bubbleHotkeyKeyCode = "bubbleHotkeyKeyCode"
        static let bubbleHotkeyModifiers = "bubbleHotkeyModifiers"
        static let bubbleVisible = "bubbleVisible"
        static let bubbleCorner = "bubbleCorner"
        static let bubblePointX = "bubblePointX"
        static let bubblePointY = "bubblePointY"
        static let bubbleHasCustomPoint = "bubbleHasCustomPoint"
        static let bubbleCollapsed = "bubbleCollapsed"
    }

    private init() {
        d.register(defaults: [
            Key.mode: TypingProfile.Mode.ultraFast.rawValue,
            Key.countdownSeconds: 5.0,
            Key.quickCountdownSeconds: 1.0,
            Key.tripleEscWindowMs: 900.0,
            Key.preventDisplaySleep: true,
            Key.forceUnicodeOnly: true,   // pure-Unicode = exact glyph, no wrong-keycode corruption
            // Reliable delivery ON by default: serialize keystrokes (no key overlap) + pace them
            // so fragile web/Electron targets (e.g. a contenteditable site) can't drop or batch
            // events. Turn OFF only for maximum keystroke-dynamics stealth in a tolerant app.
            Key.reliableDelivery: true,
            // Default global hotkey: ⌘⌥T (Command+Option+T).
            Key.hotkeyKeyCode: Int(kVK_ANSI_T),
            Key.hotkeyModifiers: Int(cmdKey | optionKey),
            // Formatting cleanup on by default.
            Key.cleanupEnabled: true,
            // Self-made typos off by default → verbatim, corruption-proof typing.
            Key.humanTyposEnabled: false,
            // Second global hotkey for the floating bubble: ⌘⌥B (Command+Option+B).
            Key.bubbleHotkeyKeyCode: Int(kVK_ANSI_B),
            Key.bubbleHotkeyModifiers: Int(cmdKey | optionKey),
            Key.bubbleVisible: false,
            Key.bubbleCorner: BubbleCorner.botRight.rawValue,
            Key.bubbleHasCustomPoint: false,
            Key.bubbleCollapsed: false
        ])
    }

    var mode: TypingProfile.Mode {
        get { TypingProfile.Mode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .ultraFast }
        set { d.set(newValue.rawValue, forKey: Key.mode) }
    }

    var profile: TypingProfile { TypingProfile.preset(mode) }

    /// Seconds of countdown before a normal "Type it" run (time to focus the target field).
    var countdownSeconds: Double {
        get { max(0, d.double(forKey: Key.countdownSeconds)) }
        set { d.set(newValue, forKey: Key.countdownSeconds) }
    }

    /// Shorter countdown for quick paste (clipboard hotkey + pop-out bubble).
    var quickCountdownSeconds: Double {
        get { max(0, d.double(forKey: Key.quickCountdownSeconds)) }
        set { d.set(newValue, forKey: Key.quickCountdownSeconds) }
    }

    /// Clamped both ways so the triple-Esc kill gesture can never be configured into
    /// uselessness (too small to ever register, or absurdly large).
    var tripleEscWindowSeconds: Double {
        get { let ms = d.double(forKey: Key.tripleEscWindowMs); return (ms > 0 ? ms : 900) / 1000.0 }
        set { d.set(max(0.3, min(newValue, 3.0)) * 1000.0, forKey: Key.tripleEscWindowMs) }
    }

    var preventDisplaySleep: Bool {
        get { d.bool(forKey: Key.preventDisplaySleep) }
        set { d.set(newValue, forKey: Key.preventDisplaySleep) }
    }

    /// Force the pure-Unicode (virtualKey 0) injection path for ALL characters.
    /// Default off — flip on only if the real-keycode path is rejected somewhere.
    var forceUnicodeOnly: Bool {
        get { d.bool(forKey: Key.forceUnicodeOnly) }
        set { d.set(newValue, forKey: Key.forceUnicodeOnly) }
    }

    /// Serialize keystrokes (each key fully presses + releases, paced, before the next)
    /// instead of the stealth overlap/rollover model. Default ON — the overlap is what
    /// fragile web/Electron targets drop or batch, producing merged words ("the end"→
    /// "theend") and autocorrect artifacts ("plainly"→"plainly."). The stealth overlap
    /// is one toggle away for tolerant apps (Terminal, native fields, Google Docs).
    var reliableDelivery: Bool {
        get { d.bool(forKey: Key.reliableDelivery) }
        set { d.set(newValue, forKey: Key.reliableDelivery) }
    }

    var hotkeyKeyCode: UInt32 {
        get { UInt32(d.integer(forKey: Key.hotkeyKeyCode)) }
        set { d.set(Int(newValue), forKey: Key.hotkeyKeyCode) }
    }

    var hotkeyModifiers: UInt32 {
        get { UInt32(d.integer(forKey: Key.hotkeyModifiers)) }
        set { d.set(Int(newValue), forKey: Key.hotkeyModifiers) }
    }

    // MARK: - Formatting cleanup

    /// Normalize pasted text (collapse spaces, fold newlines, strip invisibles, etc.)
    /// before typing. Default ON; the single shared `TextCleanup.clean(_:)` reads this.
    var cleanupEnabled: Bool {
        get { d.bool(forKey: Key.cleanupEnabled) }
        set { d.set(newValue, forKey: Key.cleanupEnabled) }
    }

    /// Whether to inject realistic typos + on-the-fly corrections. OFF by default: the
    /// backspace-corrections can desync against a target field's own autocorrect and
    /// corrupt the output. Off ⇒ verbatim typing (full human timing, zero text mutations).
    var humanTyposEnabled: Bool {
        get { d.bool(forKey: Key.humanTyposEnabled) }
        set { d.set(newValue, forKey: Key.humanTyposEnabled) }
    }

    /// Deliver the text by ONE clipboard paste (⌘V) instead of simulating per-key typing.
    /// This is the bulletproof path for fragile web/Electron editors (e.g. the Feather tweet
    /// composer) that drop/duplicate fast synthetic keystrokes or run their own autocorrect:
    /// a single atomic insert has no per-key events to lose and never trips the target's
    /// "double-space → period" / autocorrect / autocapitalize. The clipboard is saved and
    /// restored around the paste. Default OFF (Typer+ is a typer first); turn ON for apps
    /// where typing glitches. Ignores the typing modes/timing (paste is instant).
    var pasteDelivery: Bool {
        get { d.bool(forKey: Key.pasteDelivery) }
        set { d.set(newValue, forKey: Key.pasteDelivery) }
    }

    // MARK: - Floating bubble

    /// Second global hotkey (default ⌘⌥B) that toggles the always-on-top bubble.
    var bubbleHotkeyKeyCode: UInt32 {
        get { UInt32(d.integer(forKey: Key.bubbleHotkeyKeyCode)) }
        set { d.set(Int(newValue), forKey: Key.bubbleHotkeyKeyCode) }
    }
    var bubbleHotkeyModifiers: UInt32 {
        get { UInt32(d.integer(forKey: Key.bubbleHotkeyModifiers)) }
        set { d.set(Int(newValue), forKey: Key.bubbleHotkeyModifiers) }
    }

    /// Whether the bubble was on screen last run (restored on launch).
    var bubbleVisible: Bool {
        get { d.bool(forKey: Key.bubbleVisible) }
        set { d.set(newValue, forKey: Key.bubbleVisible) }
    }

    /// Whether the bubble is minimized to the bottom-right sliver (only + and Type clipboard).
    var bubbleCollapsed: Bool {
        get { d.bool(forKey: Key.bubbleCollapsed) }
        set { d.set(newValue, forKey: Key.bubbleCollapsed) }
    }

    /// Snap anchor (9-way grid) used when no custom drag-point is stored.
    var bubbleCorner: BubbleCorner {
        get { BubbleCorner(rawValue: d.string(forKey: Key.bubbleCorner) ?? "") ?? .botRight }
        set { d.set(newValue.rawValue, forKey: Key.bubbleCorner) }
    }

    /// The exact dragged origin (screen coords, bottom-left). `nil` means "use the
    /// corner". Set via `setBubblePoint`; cleared by snapping to a corner.
    var bubblePoint: CGPoint? {
        get {
            guard d.bool(forKey: Key.bubbleHasCustomPoint) else { return nil }
            return CGPoint(x: d.double(forKey: Key.bubblePointX),
                           y: d.double(forKey: Key.bubblePointY))
        }
    }
    func setBubblePoint(_ p: CGPoint) {
        d.set(true, forKey: Key.bubbleHasCustomPoint)
        d.set(Double(p.x), forKey: Key.bubblePointX)
        d.set(Double(p.y), forKey: Key.bubblePointY)
    }
    /// Snap to a corner and forget any custom point.
    func setBubbleCorner(_ c: BubbleCorner) {
        d.set(false, forKey: Key.bubbleHasCustomPoint)
        bubbleCorner = c
    }

    /// The persisted per-install typing persona (drawn once, then stable so the same
    /// "person" types every run). Per-keystroke variation still comes fresh each run.
    var persona: Persona {
        if let data = d.data(forKey: Key.persona),
           let p = try? JSONDecoder().decode(Persona.self, from: data) {
            return p
        }
        let p = Persona.random(RNG())
        if let data = try? JSONEncoder().encode(p) { d.set(data, forKey: Key.persona) }
        return p
    }
}
