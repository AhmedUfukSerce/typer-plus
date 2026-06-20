import AppKit
import Carbon   // IsSecureEventInputEnabled()

/// Central coordinator: owns every subsystem, enforces the permission gate, runs
/// the safety watchdog, and drives a typing run (countdown → play). Lives for the
/// whole app lifetime.
final class AppController: NSObject, NSApplicationDelegate {

    private let settings = Settings.shared
    private let powerAssertion = PowerAssertion()
    private lazy var engine = KeyboardEngine()
    private lazy var killSwitch = KillSwitch(tripleEscWindow: settings.tripleEscWindowSeconds)
    private lazy var player = Player(engine: engine)
    private let menu = MenuBarController()
    private let hotkey = Hotkey()
    private let countdown = CountdownHUD()

    let appModel = AppModel()
    private lazy var mainWindow = MainWindowController(model: appModel)
    private lazy var bubble = BubbleController(model: appModel)
    private var pendingText = ""

    private var permissionPoll: Timer?
    private var safetyWatchdog: Timer?
    private var isTyping = false
    private var runGeneration = 0   // invalidates a stale countdown completion (start→stop→start)
    private var lastRunEndedAt: TimeInterval = 0   // debounce: ⌘⌥T right after a run must not retype

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another Typer+ (same bundle id) is already running, hand
        // focus to it and quit — otherwise a second launch adds a duplicate menu-bar icon.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.regular)
        menu.install(controller: self)
        appModel.controller = self
        installMainMenu()
        mainWindow.showWindow()

        killSwitch.onTripleEsc = { [weak self] in self?.stopTyping() }

        player.pauseProvider = { [weak self] in self?.shouldHold() ?? true }
        player.onFinish = { [weak self] in self?.finishTyping() }
        player.onPausedChange = { [weak self] _ in self?.refreshUI() }

        hotkey.onFire = { [weak self] in self?.hotkeyClipboardToggle() }
        hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        // Second global hotkey (default ⌘⌥B): toggle the floating bubble.
        hotkey.register(slot: .bubble,
                        keyCode: settings.bubbleHotkeyKeyCode,
                        modifiers: settings.bubbleHotkeyModifiers) { [weak self] in
            self?.toggleBubble()
        }

        // Restore the bubble if it was on screen last run.
        if settings.bubbleVisible { bubble.show() }

        engine.forceUnicodeOnly = settings.forceUnicodeOnly

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        if !Permissions.allReady { Permissions.requestAll() }
        armIfPossible()
        if !Permissions.allReady { startPermissionPoll() }

        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        countdown.cancel()
        player.abort()
        stopSafetyWatchdog()
        killSwitch.stop()
        hotkey.unregister()
        powerAssertion.end()
    }

    // MARK: - URL scheme (typerplus://clipboard | typerplus://stop)

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), url.scheme?.lowercased() == "typerplus" else { return }
        switch (url.host ?? "").lowercased() {
        case "clipboard", "type": typeClipboard()
        case "stop": stopTyping()
        default: NSLog("Typer+: unknown URL command in \(s)")
        }
    }

    // MARK: - Permissions / arming

    @discardableResult
    private func armIfPossible() -> Bool {
        if !killSwitch.isArmed { _ = killSwitch.start() }
        return killSwitch.isArmed
    }

    private var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Safe to inject right now? Only if the kill switch is live and Secure Input
    /// isn't blinding it (a password field would swallow keys and break the abort).
    private var safeToRun: Bool { killSwitch.isArmed && !secureInputActive }

    /// Player hold condition: hold ONLY while it isn't safe to inject — i.e. the
    /// kill switch is down or Secure Input (a password field) is swallowing keys.
    /// Real user activity (mouse/typing/tab switch) deliberately does NOT pause:
    /// the only way to stop a run is triple-Esc (→ stopTyping). The Secure-Input
    /// case self-resumes the moment the password field loses focus, so there is no
    /// "paused, can't resume" dead-end.
    private func shouldHold() -> Bool {
        !safeToRun
    }

    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.armIfPossible()
            self.refreshUI()
            if Permissions.allReady { self.permissionPoll?.invalidate(); self.permissionPoll = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionPoll = t
    }

    // MARK: - Typing run

    /// Plan and type `text`: countdown → play. Honors permission gate + kill switch.
    ///
    /// Formatting cleanup runs HERE — the single shared entry point used by the bubble,
    /// the menu paste box, the clipboard hotkey, and the main window — so what gets
    /// typed is identical regardless of source. `TextCleanup.clean` is a no-op when the
    /// Settings toggle is off.
    func beginTyping(_ text: String, quick: Bool = false) {
        // Single in-flight run: a second start (during countdown or mid-type) is ignored,
        // never silently merged/replaced into corrupted output. ⌘⌥T stops first, then starts.
        guard !isTyping && !player.isRunning else { return }
        // Post-run debounce, enforced HERE (the one chokepoint every start path flows through:
        // hotkey, Home button, bubble, URL scheme, menu). A (re)start within a short window
        // after any run ends is ignored — so a Stop click/press that lands as the run finishes,
        // or a 2nd press meant to stop, can never silently retype everything. `lastRunEndedAt`
        // is stamped in finishTyping() on both natural finish and abort/cancel.
        guard ProcessInfo.processInfo.systemUptime - lastRunEndedAt >= 0.8 else { return }
        // Always fold CRLF / lone CR → LF, independent of the cosmetic cleanup toggle: a
        // "\r\n" is a SINGLE Swift Character that isn't "\n", so it would otherwise bypass the
        // Return path and get injected as a stray blob, mangling every line break.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let cleaned = TextCleanup.clean(normalized)
        guard !cleaned.isEmpty else { return }
        pendingText = cleaned
        guard Permissions.allReady else {
            Permissions.requestAll()
            Permissions.openAccessibilitySettings()
            startPermissionPoll()
            refreshUI()
            return
        }
        guard armIfPossible() else { refreshUI(); return }

        menu.closePasteBox()
        NSApp.deactivate()           // hand focus back to the user's target app/field
        countdown.cancel()
        if player.isRunning { player.abort() }

        engine.forceUnicodeOnly = settings.forceUnicodeOnly
        var profile = settings.profile
        // VERBATIM by default: never inject self-made typos/grammar slips/false-starts, so
        // there are NO backspace-corrections that a target field's own autocorrect /
        // autocomplete / "double-space→period" / auto-capitalization could desync and turn
        // into stray periods, misspellings, or extra letters. Human TIMING/pauses/rhythm are
        // untouched — only the text-mutating error layer is off. (Opt back in via Settings.)
        if !settings.humanTyposEnabled {
            // VERBATIM for ALL modes, INCLUDING Max Speed. The self-typo layer's backspace
            // CORRECTIONS were the regression that re-broke fragile editors: they assume the
            // field still holds exactly what was typed, but a web editor's async autocorrect
            // rewrites the token underneath, so the fix-up deletes the wrong characters and
            // leaves the misspelling — "writes everything wrong and never fixes it." (Earlier
            // this exempted Max Speed; that is exactly what corrupted Feather again.) Re-enable
            // misclicks globally in Settings only if you accept that risk on fragile targets.
            profile.typoRate = 0
            profile.uncorrectedResidue = 0
            profile.revisionRate = 0
            profile.grammarEnabled = false
        }
        // Paste delivery skips the per-key plan entirely (one atomic ⌘V — see deliverPaste).
        let usePaste = settings.pasteDelivery
        let plan = usePaste ? []
            : Planner(profile: profile, rng: RNG(), persona: settings.persona,
                      serialize: settings.reliableDelivery).plan(cleaned)

        runGeneration += 1
        let gen = runGeneration
        isTyping = true
        reconcilePowerAssertion(running: true)
        startSafetyWatchdog()
        refreshUI()

        let secs = Int((quick ? settings.quickCountdownSeconds : settings.countdownSeconds).rounded())
        countdown.start(seconds: secs, completion: { [weak self] in
            guard let self = self, gen == self.runGeneration, self.isTyping else { return }
            guard self.safeToRun else { self.finishTyping(); return }
            self.appModel.recordSession(text: self.pendingText, mode: self.settings.mode)
            if usePaste {
                // One atomic clipboard paste — no per-key events to drop/merge/duplicate, and
                // the target's autocorrect / double-space→period never fire. Finish shortly
                // after (paste is instant; the delay just spans the clipboard restore).
                self.deliverPaste(self.pendingText)
                self.refreshUI()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self, gen == self.runGeneration else { return }
                    self.finishTyping()
                }
            } else {
                self.player.play(plan)
                self.refreshUI()
            }
        }, cancelled: { [weak self] in
            self?.finishTyping()
        })
    }

    private func finishTyping() {
        guard isTyping else { return }
        isTyping = false
        lastRunEndedAt = ProcessInfo.processInfo.systemUptime
        stopSafetyWatchdog()
        powerAssertion.end()
        refreshUI()
    }

    // MARK: - Paste delivery (bulletproof path for fragile web/Electron editors)

    /// Put `text` on the clipboard, fire one synthetic ⌘V into the focused field, then restore
    /// the user's previous clipboard. A single atomic insert: nothing for a fragile editor to
    /// drop/merge/duplicate, and the field's own autocorrect / "double-space→period" / smart
    /// quotes never fire (they act on typed keystrokes, not on a paste).
    private func deliverPaste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        engine.pasteShortcut()
        // Restore once the target has consumed the paste (so we don't clobber what it read).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restorePasteboard(pb, items: saved)
        }
    }

    /// Deep-copy the current clipboard contents (all representations) so they survive a
    /// clearContents()/setString and can be written back verbatim.
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        var copies: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            if !copy.types.isEmpty { copies.append(copy) }
        }
        return copies
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private func reconcilePowerAssertion(running: Bool) {
        if running && settings.preventDisplaySleep { powerAssertion.begin() }
        else { powerAssertion.end() }
    }

    private func startSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTyping else { return }
            if !self.killSwitch.isArmed { _ = self.killSwitch.start() }
            self.refreshUI()
        }
        RunLoop.main.add(t, forMode: .common)
        safetyWatchdog = t
    }

    private func stopSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        safetyWatchdog = nil
    }

    // MARK: - Menu actions

    @objc func openPasteBox() {
        guard Permissions.allReady else {
            Permissions.requestAll(); Permissions.openAccessibilitySettings(); startPermissionPoll(); refreshUI(); return
        }
        menu.showPasteBox()
    }

    @objc func typeClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            NSSound.beep(); return
        }
        beginTyping(s, quick: true)
    }

    /// ⌘⌥T behaves as a toggle: if a run is already underway (countdown or typing),
    /// pressing it again cancels it; otherwise it starts typing the clipboard. The
    /// "don't restart right after a stop" debounce lives in beginTyping(), so it covers
    /// this AND every other start path uniformly.
    @objc func hotkeyClipboardToggle() {
        if isTyping { stopTyping() } else { typeClipboard() }
    }

    @objc func stopTyping() {
        runGeneration += 1            // invalidate any in-flight countdown completion
        countdown.cancel()
        if player.isRunning { player.abort() } else { finishTyping() }
    }

    /// Toggle the always-on-top floating bubble (menu item + ⌘⌥B hotkey).
    @objc func toggleBubble() {
        bubble.toggle()
        refreshUI()
    }

    /// Explicit "Open pop-out" button — always brings up the full bubble (never toggles off).
    @objc func openBubble() {
        bubble.present()
        refreshUI()
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TypingProfile.Mode(rawValue: raw) else { return }
        setMode(mode)
    }

    func setMode(_ mode: TypingProfile.Mode) {
        settings.mode = mode
        refreshUI()
    }

    @objc func togglePreventSleep() {
        settings.preventDisplaySleep.toggle()
        reconcilePowerAssertion(running: isTyping)
        refreshUI()
    }

    @objc func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }

    @objc func quit() {
        stopTyping()
        killSwitch.stop()
        NSApp.terminate(nil)
    }

    // MARK: - UI

    private func refreshUI() {
        let ready = Permissions.allReady
        let armed = killSwitch.isArmed

        let status: String
        if !ready { status = "Typer+: needs permission" }
        else if !armed { status = "Typer+: kill switch unavailable" }
        else if isTyping && player.isPaused { status = "Typer+: holding (secure input active)" }
        else if isTyping { status = "Typer+: typing — \(settings.mode.rawValue)" }
        else { status = "Typer+ · \(settings.mode.rawValue)" }

        menu.refresh(MenuState(
            statusText: status,
            ready: ready,
            killSwitchArmed: armed,
            typing: isTyping,
            mode: settings.mode,
            preventSleep: settings.preventDisplaySleep,
            bubbleVisible: bubble.isVisible))

        appModel.apply(
            ready: ready,
            armed: armed,
            isTyping: isTyping,
            paused: player.isPaused,
            statusText: status,
            mode: settings.mode)
        // The bubble (when shown) observes `appModel` directly, so the apply above
        // already drives its live state — no separate push needed.
    }

    // MARK: - Window / main menu

    @objc func showMainWindow() { mainWindow.showWindow() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.showWindow() }
        return true
    }

    /// Minimal main menu so ⌘Q / ⌘W and — critically — ⌘C/⌘V/⌘A work in the SwiftUI text
    /// editors (a .regular app gets no Edit menu for free, which would break pasting).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Typer+", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Typer+ Window", action: #selector(showMainWindow), keyEquivalent: "0")
        openItem.target = self; appMenu.addItem(openItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Typer+", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }
}
