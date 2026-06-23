import AppKit

/// A small, non-activating floating HUD that counts down before typing begins, so
/// the user can click into the target field. It never takes key focus (so it can't
/// become the "frontmost" app and steal the keystrokes).
final class CountdownHUD {

    private var window: NSWindow?
    private var label: NSTextField?
    private var timer: Timer?
    private var remaining = 0
    private var onDone: (() -> Void)?
    private var onCancel: (() -> Void)?

    /// Count down `seconds`, then call `completion`. `cancelled` fires if `cancel()`
    /// is called mid-countdown (e.g. the user aborts).
    func start(seconds: Int, completion: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        // Hard-reset WITHOUT firing the previous run's onCancel (avoids a stale callback
        // when a new run starts before the old one was explicitly cancelled).
        timer?.invalidate(); timer = nil
        teardownWindow()
        onDone = completion
        onCancel = cancelled
        remaining = max(seconds, 0)

        if remaining == 0 { finish(); return }
        buildWindow()
        render()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        teardownWindow()
        if let c = onCancel { onCancel = nil; onDone = nil; c() }
    }

    // MARK: -

    private func tick() {
        remaining -= 1
        if remaining <= 0 { finish() } else { render() }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        teardownWindow()
        let done = onDone
        onDone = nil; onCancel = nil
        done?()
    }

    private func render() {
        label?.stringValue = "Typing in \(remaining)…  (click your target field · Esc Esc Esc to stop)"
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 64),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .systemFont(ofSize: 15, weight: .semibold)
        lbl.textColor = .labelColor
        lbl.alignment = .center
        lbl.frame = bg.bounds.insetBy(dx: 16, dy: 20)
        lbl.autoresizingMask = [.width, .height]
        bg.addSubview(lbl)
        w.contentView?.addSubview(bg)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - 230, y: f.minY + f.height * 0.18))
        }
        w.orderFrontRegardless()   // show without activating / taking key focus
        window = w
        label = lbl
    }

    private func teardownWindow() {
        window?.orderOut(nil)
        window = nil
        label = nil
    }
}
