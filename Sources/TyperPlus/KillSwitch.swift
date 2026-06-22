import AppKit
import CoreGraphics

private let kEscapeKeyCode: Int64 = 53

/// C trampoline — a `CGEventTapCallBack` can't capture context, so route through
/// the `userInfo` pointer back to the owning `KillSwitch`.
private func killSwitchCallback(proxy: CGEventTapProxy,
                                type: CGEventType,
                                event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo = userInfo {
        Unmanaged<KillSwitch>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)   // .listenOnly tap: never consume
}

/// Owns the single global `CGEventTap` powering the one safety feature:
///   • triple-tap ESC within a short window → `onTripleEsc` (the only way to stop a run)
///
/// Adapted from Cursor+ for keyboard injection:
///   • Our OWN injected keystrokes are recognised by source PID and ignored — they
///     must never count toward the kill switch.
///   • We NEVER inject ESC, so a real triple-ESC can never be self-recognised away
///     — the abort gesture stays structurally independent and un-spoofable.
///   • The redundant `NSEvent` monitor handles ESC too, as a backstop should the
///     CG tap be torn down by the system.
///
/// Robustness (a dead kill switch while typing is the worst failure):
///   1. Re-enable in the callback on `.tapDisabledByTimeout/.ByUserInput`.
///   2. A persistent 2s health timer that reinstalls the tap and is never torn down
///      by a failed reinstall.
///   3. The redundant `NSEvent` global ESC monitor.
final class KillSwitch {

    var onTripleEsc: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var globalMonitor: Any?

    private var escTimestamps: [TimeInterval] = []
    private var lastEscAt: TimeInterval = 0
    private let escWindow: TimeInterval

    /// Our own posted events carry our process ID (the OS stamps it); real hardware
    /// events report PID 0. So we recognise — and ignore — our own injected keystrokes
    /// exactly by source PID, with no event tagging and no keycode collisions.
    private static let ourPID = Int64(getpid())

    init(tripleEscWindow: TimeInterval) {
        self.escWindow = tripleEscWindow
    }

    deinit { stop() }

    var isArmed: Bool {
        guard let tap = tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func start() -> Bool {
        if healthTimer == nil { startHealthTimer() }
        if globalMonitor == nil { startGlobalMonitor() }
        return installTapIfNeeded()
    }

    func stop() {
        healthTimer?.invalidate(); healthTimer = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        removeTap()
        escTimestamps.removeAll()
    }

    // MARK: Tap install / remove

    @discardableResult
    private func installTapIfNeeded() -> Bool {
        if let tap = tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        removeTap()

        // Only key-downs matter now: the kill switch watches for triple-ESC and
        // nothing else. (Mouse/scroll/flags no longer drive any pause behavior.)
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: mask,
                                             callback: killSwitchCallback,
                                             userInfo: info) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        runLoopSource = source
        return CGEvent.tapIsEnabled(tap: newTap)
    }

    private func removeTap() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)   // deterministic teardown (no port leak on reinstall)
        }
        if let tap = tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
    }

    // MARK: Event handling (main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Ignore our OWN injected events by source PID (we never inject ESC, so a real
        // ESC — PID 0 — is never ignored and always counts toward the kill switch).
        if event.getIntegerValueField(.eventSourceUnixProcessID) == KillSwitch.ourPID { return }

        if type == .keyDown {
            let auto = event.getIntegerValueField(.keyboardEventAutorepeat)
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if auto != 0 { return }
            if code == kEscapeKeyCode { recordEsc() }
        }
    }

    private func recordEsc() {
        let now = ProcessInfo.processInfo.systemUptime
        // Dedupe the SAME physical ESC arriving from BOTH the CG tap and the NSEvent monitor
        // (they fire within ~1–2ms). Keep this window tight: at 60ms it also swallowed a
        // genuinely fast "Esc Esc Esc" (taps <60ms apart counted as one), so the advertised
        // emergency stop could silently need a 4th tap. 25ms still collapses the duplicate
        // pair with margin while passing any real human triple-tap.
        if now - lastEscAt < 0.025 { return }
        lastEscAt = now
        // Read the window LIVE so a Settings change takes effect immediately (no relaunch).
        let window = max(0.3, Settings.shared.tripleEscWindowSeconds)
        escTimestamps.append(now)
        escTimestamps.removeAll { now - $0 > window }
        if escTimestamps.count >= 3 {
            escTimestamps.removeAll()
            onTripleEsc?()
        }
    }

    // MARK: Redundant global ESC monitor (ESC only — see class note)

    private func startGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return }
            if ev.keyCode == UInt16(kEscapeKeyCode) { self.recordEsc() }
        }
    }

    // MARK: Persistent health check

    private func startHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.installTapIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}
