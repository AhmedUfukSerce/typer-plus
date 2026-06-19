import AppKit

// Headless correctness checks (no GUI): `swift run TyperPlus --selftest`.
if CommandLine.arguments.contains("--selftest") {
    exit(Int32(TyperPlusSelfTest.run()))
}

// Objective detector scorecard (no GUI): `swift run TyperPlus --detect`.
if CommandLine.arguments.contains("--detect") {
    exit(Int32(Detector.run()))
}

// Real-delivery throughput check (no GUI): `swift run TyperPlus --speedtest`.
if CommandLine.arguments.contains("--speedtest") {
    exit(Int32(TyperPlusSelfTest.runSpeedTest()))
}

// Entry point. Typer+ is a regular windowed app (Dock icon + main window) that ALSO
// keeps a menu-bar item, global hotkey, and the triple-Esc kill switch alive in the
// background. The AppController is held by a top-level binding so it lives for the whole
// run; NSApplication.delegate is a weak reference.
InterFonts.registerAll()   // register bundled Inter before any UI renders

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
