import AppKit
import ApplicationServices
import CoreGraphics

/// Typer+ needs the same macOS grants as Cursor+:
///   • Post Events  — to synthesize keystrokes (CGRequestPostEventAccess)
///   • Input Monitoring (ListenEvent) — for the global key tap (triple-Esc kill switch)
///   • Accessibility — the master grant that in practice also enables posting +
///     listening for this app.
///
/// Readiness keys off Accessibility alone (requiring Input Monitoring separately
/// produced false "needs permission" reports in Cursor+). A non-sandboxed binary
/// is required — injection cannot run in the App Sandbox.
enum Permissions {

    @discardableResult
    static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }

    @discardableResult
    static func requestListenEvents() -> Bool { CGRequestListenEventAccess() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var accessibilityUsable: Bool { AXIsProcessTrusted() }

    static var allReady: Bool { accessibilityUsable }

    static func requestAll() {
        _ = requestPostEvents()
        _ = requestListenEvents()
        _ = requestAccessibility()
    }

    /// Deep-link to Settings ▸ Privacy & Security ▸ Accessibility (modern id, legacy fallback).
    static func openAccessibilitySettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
    }
}
