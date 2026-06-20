import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Posts real OS-level keystrokes at the HID layer — never pastes, never touches
/// the clipboard. This is the injection primitive the whole tool rests on.
///
/// Detectability hygiene (RESEARCH.md §3.6 / §6):
///  • Source is `.hidSystemState` → events enter at the HID layer and read as
///    genuine hardware (the page sees `isTrusted: true`).
///  • `localEventsSuppressionInterval = 0` keeps real-input detection instant.
///  • Every event carries a real `mach_absolute_time()` timestamp (a posted event
///    defaults to timestamp 0 — a deterministic synthetic tell).
///  • Autorepeat is forced off; `eventSourceUserData` is left default (a constant
///    tag would be a readable self-fingerprint).
///  • One character per keyDown/keyUp pair (batching destroys per-key timing).
///
/// Text path: Unicode (`keyboardSetUnicodeString`, virtualKey 0) by default —
/// layout-independent and the path validated by the de-risk test. `preferKeycodePath`
/// flips to a US-QWERTY keycode+Shift path (set this if the de-risk test shows a
/// context needs a real `event.code`). Special keys (backspace/arrows/return/tab)
/// always use the keycode path.
final class KeyboardEngine {

    private let source: CGEventSource?

    /// Pure-Unicode path (virtualKey 0) for ALL characters — DEFAULT ON for correctness.
    /// The keycode path posted a REAL US-QWERTY virtual key alongside the Unicode string;
    /// for any char not on the US layout (shifted punctuation, accents, smart quotes, emoji,
    /// or anything routed through the last-resort fallback keycode) that real keycode could
    /// COMPETE with the Unicode string and a code-reading / non-US-layout field would render
    /// the wrong glyph (stray letters / periods — the reported corruption). vk 0 + the exact
    /// Unicode string is unambiguous in every field. Flip OFF only for keycode "authenticity"
    /// in a context that's verified to honor it.
    var forceUnicodeOnly = true

    /// Modifier flags currently "held" (driven by shiftDown/shiftUp from the planner).
    /// Every posted event reflects these, exactly like real hardware while Shift is held.
    private var heldFlags: CGEventFlags = []

    init() {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        self.source = s
    }

    // MARK: Text characters

    func charDown(_ ch: Character) { postChar(ch, down: true) }
    func charUp(_ ch: Character) { postChar(ch, down: false) }

    // MARK: Special keys (backspace, arrows, return, tab)

    func keyDown(_ code: CGKeyCode) { postCode(code, down: true) }
    func keyUp(_ code: CGKeyCode) { postCode(code, down: false) }

    // MARK: Modifier (left Shift) — real key events around shifted-char runs

    // Modifiers mirror ONLY what the OS actually saw: the flag is set after a successful
    // post (down) and always cleared on release. A dropped CGEvent can therefore never
    // leave a modifier "stuck" in our mirror and silently shift every following character.
    func shiftDown()  { if postCode(KeyMap.shift,  down: true)  { heldFlags.insert(.maskShift) } }
    func shiftUp()    { heldFlags.remove(.maskShift);  _ = postCode(KeyMap.shift,  down: false) }
    func optionDown() { if postCode(KeyMap.option, down: true)  { heldFlags.insert(.maskAlternate) } }
    func optionUp()   { heldFlags.remove(.maskAlternate); _ = postCode(KeyMap.option, down: false) }

    /// Idempotent safety reset — release any modifier we might be holding and clear the
    /// mirror. Posting an already-up modifier is a no-op for the OS, so calling this on
    /// abort/finish guarantees a run can never leave Shift/Option stuck for the user's own
    /// subsequent typing. (Releasing an already-up key never produces a character.)
    func resetModifiers() {
        if heldFlags.contains(.maskShift)     { _ = postCode(KeyMap.shift,  down: false) }
        if heldFlags.contains(.maskAlternate) { _ = postCode(KeyMap.option, down: false) }
        heldFlags = []
    }

    // MARK: Posting (text characters, special keys, and the ⌘V paste shortcut)

    /// Synthesize a single ⌘V: Command down, V down (⌘ held), V up, Command up. Used by the
    /// paste-delivery path. Posts at the HID tap like every other event, so the target sees a
    /// genuine paste. One atomic insert — nothing for a fragile editor to drop/merge/duplicate.
    func pasteShortcut() {
        let cmd: CGKeyCode = 0x37   // kVK_Command (left ⌘)
        let v: CGKeyCode = 0x09     // kVK_ANSI_V
        post(cmd, down: true,  flags: .maskCommand)
        post(v,   down: true,  flags: .maskCommand)
        post(v,   down: false, flags: .maskCommand)
        post(cmd, down: false, flags: [])
    }

    /// Low-level single keycode post with explicit flags (used by `pasteShortcut`).
    private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        e.timestamp = mach_absolute_time()
        e.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func postChar(_ ch: Character, down: Bool) -> Bool {
        // Default (forceUnicodeOnly): vk 0 + the exact Unicode string — the only
        // specification, so no keycode can compete and render a wrong glyph.
        let stroke = forceUnicodeOnly ? nil : KeyMap.stroke(for: ch)
        let vk = stroke?.code ?? (forceUnicodeOnly ? 0 : KeyMap.fallbackCode(for: ch))
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return false }
        if down {
            let u = Array(String(ch).utf16)
            u.withUnsafeBufferPointer { buf in
                e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
        }
        finalize(e, flags: heldFlags)
        e.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private func postCode(_ code: CGKeyCode, down: Bool) -> Bool {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return false }
        finalize(e, flags: heldFlags)
        e.post(tap: .cghidEventTap)
        return true
    }

    private func finalize(_ e: CGEvent, flags: CGEventFlags) {
        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        // Match what real hardware events actually carry: the kernel stamps CGEvents with
        // mach_absolute_time() (the monotonic TICK counter). On Intel the timebase is 1:1
        // so ticks ≈ ns (matching the stale "nanoseconds" header comment); on Apple Silicon
        // one tick = 41.67 ns, so the field is ticks, NOT ns. Using true ns (clock_gettime)
        // would read ~42x out of band to a tap on M-series — the opposite of the goal.
        e.timestamp = mach_absolute_time()
    }
}

/// Holds an IOPMAssertion so the display won't sleep mid-run. (Reused from Cursor+.)
final class PowerAssertion {

    private var id: IOPMAssertionID = 0
    private var active = false

    func begin() {
        guard !active else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Typer+ typing" as CFString,
            &newID)
        if result == kIOReturnSuccess { id = newID; active = true }
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
        id = 0
    }

    deinit { end() }   // never leak the display-sleep assertion
}
