// InjectTest — de-risk harness for Typer+.
//
// Proves the two BLOCKING premises from RESEARCH.md §6 before we build the app:
//   1. Chrome sees our CGEvent keystrokes as `isTrusted: true` / inputType
//      "insertText" (run the JS console listener in docs/test-instructions.md).
//   2. The Google Docs *canvas* editor ingests `CGEventKeyboardSetUnicodeString`
//      (not just plain DOM <input>/contenteditable fields).
//
// It posts real per-character keystrokes (never pastes) at the HID layer, exactly
// the way the real engine will: .hidSystemState source, .cghidEventTap, one char
// per keyDown/keyUp, real mach timestamps, autorepeat off, userData left default.
//
// USAGE: run from Terminal (Terminal needs Accessibility):
//     swift run InjectTest
// then within the countdown click into the target text field / Google Doc.

import Foundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox  // IsSecureEventInputEnabled

// The test string exercises lowercase, uppercase (needs Shift), digits,
// punctuation, and a non-ASCII char (é) to verify the Unicode path + layout
// independence.
let TEST_STRING = "The quick brown fox jumps 123 — café."

// ---- helpers ---------------------------------------------------------------

func msSleep(_ ms: Double) { usleep(useconds_t(max(0, ms) * 1000)) }

/// Post one character as a genuine keyDown/keyUp pair via the Unicode path
/// (virtualKey 0 + keyboardSetUnicodeString = layout-independent).
func postChar(_ ch: Character, source: CGEventSource?, dwellMs: Double) {
    let utf16 = Array(String(ch).utf16)

    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        FileHandle.standardError.write(Data("  ! failed to create CGEvent for \(ch)\n".utf8))
        return
    }

    utf16.withUnsafeBufferPointer { buf in
        down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
    }

    // Hardware-authentic hygiene (RESEARCH.md §6): no autorepeat, real timestamp,
    // default flags, default userData (never stamp a constant tag).
    for e in [down, up] {
        e.flags = []
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        e.timestamp = mach_absolute_time()   // match hardware: kernel stamps mach ticks, not ns
    }

    down.post(tap: .cghidEventTap)
    msSleep(dwellMs)            // key hold (dwell) — independent of the inter-key gap
    up.post(tap: .cghidEventTap)
}

// ---- preflight -------------------------------------------------------------

print("""
==========================================================
 Typer+ — injection de-risk test
==========================================================
This types: "\(TEST_STRING)"
into whatever text field is focused after a 5s countdown.

Run the console listener from docs/test-instructions.md first
to confirm isTrusted=true / inputType=insertText, and try it
once in a normal field and once in a blank Google Doc.
""")

if IsSecureEventInputEnabled() {
    print("\n⚠️  Secure Input is ON (a password field/terminal is focused).")
    print("   Injected keys would be silently dropped. Focus a normal field and retry.\n")
}

if !AXIsProcessTrusted() {
    print("""

    ⚠️  This process lacks the Accessibility permission, so injection will be
       ignored. Grant it to the app running this (e.g. Terminal) in:
       System Settings ▸ Privacy & Security ▸ Accessibility
       then re-run. Continuing anyway so you can see the countdown.
    """)
}

// ---- countdown + type ------------------------------------------------------

print("\nClick into your target field now. Typing in:")
for n in stride(from: 7, through: 1, by: -1) {
    print("  \(n)…")
    msSleep(1000)
}
print("  typing!\n")

let source = CGEventSource(stateID: .hidSystemState)
source?.localEventsSuppressionInterval = 0  // keep real-input detection instant

for ch in TEST_STRING {
    // Modest human-ish variation just so it's visibly not a paste; the real
    // engine replaces this with the research-tuned distributions.
    let dwell = Double.random(in: 60...110)
    postChar(ch, source: source, dwellMs: dwell)
    let gap = Double.random(in: 90...190)   // inter-key gap
    msSleep(gap)
}

print("Done. Check: (a) the text appeared char-by-char, (b) the console shows")
print("isTrusted=true and inputType=\"insertText\" for each character.")
