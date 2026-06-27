import Foundation

/// Plays a planned `[Action]` stream on the main run loop against a MONOTONIC clock,
/// so the run stays responsive and the kill-switch tap keeps spinning.
///
/// Why a monotonic "flush everything due" loop instead of one Timer per keystroke:
/// a Timer-per-event tops out at the run loop's wake granularity (~10–16ms), which
/// silently capped fast modes (Max Speed asked for ~4ms/key but only ever delivered
/// ~one event per frame). Here every tick posts EVERY action whose planned time has
/// arrived relative to a fixed start anchor, then schedules the next wake for the next
/// not-yet-due action. The plan's average rate is therefore honored even when the run
/// loop wakes coarsely (a fast burst is flushed together), while slow modes still post
/// one-at-a-time exactly as before. A per-tick cap keeps each callback short so the
/// kill switch / UI always get serviced between flushes.
///
/// Safety invariants:
///  • It pauses ONLY at clean keystroke boundaries (no key currently held), so a
///    pause/abort can never leave a key stuck down.
///  • On abort it releases any held keys before stopping.
///  • `pauseProvider` (set by AppController) holds ONLY while it isn't safe to inject
///    (kill switch down or Secure Input active); the clock anchor is shifted by the
///    paused span so resuming does NOT dump the backlog at once.
final class Player {

    private let engine: KeyboardEngine

    var pauseProvider: () -> Bool = { false }
    var onFinish: (() -> Void)?
    var onPausedChange: ((Bool) -> Void)?

    /// When true, run the full timing/stepping pipeline but DON'T post real key events.
    /// Used by `--speedtest` to measure the Player's true delivery rate without injecting.
    var dryRun = false

    private var actions: [Action] = []
    private var planned: [Double] = []           // cumulative planned time (ms) per action
    private var index = 0
    private var heldReleases: [Action.Op] = []   // releases for keys currently down
    private var timer: Timer?
    private(set) var isRunning = false
    private(set) var isPaused = false

    // Monotonic clock (ns). `pausedAccumNs` is the total time spent holding, discounted
    // from elapsed so the planned timeline never fast-forwards after a hold.
    private var startNs: UInt64 = 0
    private var pauseStartNs: UInt64 = 0
    private var pausedAccumNs: UInt64 = 0

    /// Max events posted in a single tick before yielding to the run loop. Kept small so a
    /// late wake doesn't dump a big BURST of keys at the target app all at once (a fragile
    /// web/Electron field drops those) — we spread the catch-up over a few run-loop cycles.
    private let maxFlushPerTick = 12

    /// HARD wall-clock floor (ms) between consecutive posted events, set by AppController for
    /// reliable delivery (0 = off). This is the real fix for the "too fast / glitch" class:
    /// the serialize per-key gap lives only in the PLANNED timeline, so on a coarse/late run-
    /// loop wake the flush loop would otherwise post every due event microseconds apart,
    /// recreating the dropped/merged-space + double-space→period corruption. Enforcing a
    /// minimum monotonic-clock spacing converts any backlog into a paced drain instead of a
    /// burst — reliability no longer depends on the run loop waking finely.
    var minPostGapMs: Double = 0
    private var lastPostNs: UInt64 = 0

    /// Held for the duration of a run. `.latencyCritical` stops App Nap / timer coalescing
    /// from throttling our Timers while Typer+ is BACKGROUNDED (it deactivates so the target
    /// app has focus) — without it the run loop wakes coarsely (~16–50ms) and the flush loop
    /// delivers events in bursts the target drops, which reads as missing spaces / merged
    /// words. This keeps the stream paced and smooth.
    private var activityToken: NSObjectProtocol?

    init(engine: KeyboardEngine) {
        self.engine = engine
    }

    func play(_ actions: [Action]) {
        cancelTimer()
        beginLatencyCriticalActivity()
        self.actions = actions
        planned = []; planned.reserveCapacity(actions.count)
        var acc = 0.0
        for a in actions { acc += a.preDelayMs; planned.append(acc) }
        index = 0
        heldReleases.removeAll()
        isPaused = false
        isRunning = true
        pausedAccumNs = 0
        pauseStartNs = 0
        lastPostNs = 0
        startNs = Player.nowNs()
        scheduleTick(0)
    }

    private func beginLatencyCriticalActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Typer+ keystroke pacing")
    }

    private func endLatencyCriticalActivity() {
        if let t = activityToken { ProcessInfo.processInfo.endActivity(t); activityToken = nil }
    }

    /// Stop immediately, releasing any held keys first.
    func abort() {
        guard isRunning else { return }
        cancelTimer()
        endLatencyCriticalActivity()
        releaseHeldKeys()
        let wasPaused = isPaused
        isRunning = false
        isPaused = false
        actions = []
        planned = []
        index = 0
        if wasPaused { onPausedChange?(false) }
        onFinish?()
    }

    // MARK: - Stepping

    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Wall-clock ms since `startNs`, excluding time spent paused.
    private func elapsedMs() -> Double {
        let raw = Player.nowNs() &- startNs
        let eff = raw > pausedAccumNs ? raw - pausedAccumNs : 0
        return Double(eff) / 1_000_000.0
    }

    private func tick() {
        guard isRunning else { return }
        var flushed = 0
        var hitCap = false
        while index < actions.count {
            // Not yet due? (0.6ms slack absorbs timer wake jitter.) Wait for it.
            if planned[index] > elapsedMs() + 0.6 { break }
            let act = actions[index]

            // Pause only at a clean boundary: no key held AND the next op is a press.
            // (Mid-keystroke releases always run, so nothing stays stuck.)
            if heldReleases.isEmpty, isPress(act.op), pauseProvider() {
                if !isPaused { isPaused = true; pauseStartNs = Player.nowNs(); onPausedChange?(true) }
                scheduleTick(120)   // hold here and poll
                return
            }
            if isPaused {
                // Resumed: discount the held span so the backlog doesn't flush at once.
                pausedAccumNs &+= Player.nowNs() &- pauseStartNs
                isPaused = false
                onPausedChange?(false)
            }

            // Reliable delivery: never post two events closer than `minPostGapMs` in WALL
            // CLOCK, even on a coarse wake — so the serialize per-key spacing can't collapse
            // into a burst the target drops/duplicates. Reschedule for the remaining gap.
            if minPostGapMs > 0, lastPostNs != 0 {
                let sinceLastMs = Double(Player.nowNs() &- lastPostNs) / 1_000_000.0
                if sinceLastMs < minPostGapMs { scheduleTick(minPostGapMs - sinceLastMs); return }
            }

            execute(act.op)
            lastPostNs = Player.nowNs()
            index += 1
            flushed += 1
            if flushed >= maxFlushPerTick { hitCap = true; break }   // yield to the run loop
        }

        if index >= actions.count { finish(); return }
        // When catching up a backlog (cap hit ⇒ more events already due), schedule the next
        // tick with a SMALL real delay instead of 0. A zero-delay re-fire keeps the run loop
        // from sleeping, which can STARVE the kill-switch event tap and the Stop button (they
        // share this run loop) — i.e. make the run un-stoppable under heavy load. A ~1.5ms
        // yield lets the loop service input before the next flush; throughput is unaffected at
        // any real typing rate (12 keys / 1.5ms ≫ even Max Speed).
        let base = planned[index] - elapsedMs()
        let delayMs = max(hitCap ? 1.5 : 0, base)
        scheduleTick(delayMs)
    }

    private func finish() {
        cancelTimer()
        endLatencyCriticalActivity()
        // Belt-and-suspenders, same as abort(): if the plan's final shiftUp/charUp/keyUp was
        // dropped by the OS under load, a key/modifier could be left "down" for the user's own
        // typing. releaseHeldKeys() + resetModifiers() is idempotent (no-op when balanced).
        releaseHeldKeys()
        isRunning = false
        isPaused = false
        actions = []
        planned = []
        index = 0
        onFinish?()
    }

    // MARK: - Op execution

    private func execute(_ op: Action.Op) {
        switch op {
        case .charDown(let c):
            if !dryRun { engine.charDown(c) }; heldReleases.append(.charUp(c))
        case .charUp(let c):
            if !dryRun { engine.charUp(c) }; removeHeld(.charUp(c))
        case .keyDown(let k):
            if !dryRun { engine.keyDown(k) }; heldReleases.append(.keyUp(k))
        case .keyUp(let k):
            if !dryRun { engine.keyUp(k) }; removeHeld(.keyUp(k))
        case .shiftDown:
            if !dryRun { engine.shiftDown() }; heldReleases.append(.shiftUp)
        case .shiftUp:
            if !dryRun { engine.shiftUp() }; removeHeld(.shiftUp)
        case .optionDown:
            if !dryRun { engine.optionDown() }; heldReleases.append(.optionUp)
        case .optionUp:
            if !dryRun { engine.optionUp() }; removeHeld(.optionUp)
        }
    }

    private func releaseHeldKeys() {
        if !dryRun {
            for op in heldReleases {
                switch op {
                case .charUp(let c): engine.charUp(c)
                case .keyUp(let k): engine.keyUp(k)
                case .shiftUp: engine.shiftUp()
                case .optionUp: engine.optionUp()
                default: break
                }
            }
        }
        heldReleases.removeAll()
        // Belt-and-suspenders: guarantee no modifier is left stuck for the user's own
        // subsequent typing, even if a release event above was dropped.
        if !dryRun { engine.resetModifiers() }
    }

    private func isPress(_ op: Action.Op) -> Bool {
        switch op {
        case .charDown, .keyDown, .shiftDown, .optionDown: return true
        case .charUp, .keyUp, .shiftUp, .optionUp: return false
        }
    }

    private func removeHeld(_ op: Action.Op) {
        if let idx = heldReleases.firstIndex(where: { sameOp($0, op) }) {
            heldReleases.remove(at: idx)
        }
    }

    private func sameOp(_ a: Action.Op, _ b: Action.Op) -> Bool {
        switch (a, b) {
        case (.charUp(let x), .charUp(let y)): return x == y
        case (.keyUp(let x), .keyUp(let y)): return x == y
        case (.shiftUp, .shiftUp): return true
        case (.optionUp, .optionUp): return true
        default: return false
        }
    }

    private func scheduleTick(_ delayMs: Double) {
        cancelTimer()
        let t = Timer(timeInterval: max(0, delayMs) / 1000.0, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}
