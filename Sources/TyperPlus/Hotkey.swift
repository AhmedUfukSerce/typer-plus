import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`. The user's REAL press fires these
/// even on macOS 26 — the Tahoe `CGXSenderCanSynthesizeEvents` filter only blocks
/// *synthetic* keys from hotkey matchers (RESEARCH.md §3.6), and we never synthesize
/// a hotkey.
///
/// This owns ONE shared Carbon event handler and a small table of registered hotkeys
/// (the primary "type clipboard" key + the bubble-toggle key), each addressed by a
/// stable `EventHotKeyID.id`. The handler trampolines back here and dispatches to the
/// matching closure by id.
private func hotkeyHandler(_ next: EventHandlerCallRef?,
                           _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData, let event = event else { return noErr }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    guard status == noErr else { return noErr }
    Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().fire(id: hkID.id)
    return noErr
}

final class Hotkey {

    /// A logical hotkey slot. Each maps to a distinct Carbon `EventHotKeyID.id` so the
    /// shared handler can route the press to the right closure.
    enum Slot: UInt32 {
        case primary = 1   // existing ⌘⌥T → type clipboard
        case bubble  = 2   // new      ⌘⌥B → toggle floating bubble
    }

    /// Fired when the PRIMARY hotkey is pressed. Kept for source-compat with the
    /// existing `hotkey.onFire = …` wiring in AppController.
    var onFire: (() -> Void)?

    /// Per-slot handlers (the primary slot also calls `onFire`).
    private var handlers: [UInt32: () -> Void] = [:]

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// Register the PRIMARY hotkey (back-compat shape; calls `onFire`).
    func register(keyCode: UInt32, modifiers: UInt32) {
        register(slot: .primary, keyCode: keyCode, modifiers: modifiers) { [weak self] in
            self?.onFire?()
        }
    }

    /// Register (or replace) an arbitrary slot with its own action.
    func register(slot: Slot, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installSharedHandlerIfNeeded()
        unregister(slot: slot)

        handlers[slot.rawValue] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x54595052) /* 'TYPR' */, id: slot.rawValue)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs[slot.rawValue] = ref
    }

    /// Dispatch a press (called by the C trampoline).
    fileprivate func fire(id: UInt32) { handlers[id]?() }

    private func installSharedHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            hotkeyHandler,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &handler)
    }

    func unregister(slot: Slot) {
        if let ref = refs[slot.rawValue] { UnregisterEventHotKey(ref); refs[slot.rawValue] = nil }
        handlers[slot.rawValue] = nil
    }

    /// Tear down every hotkey + the shared handler.
    func unregister() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }

    deinit { unregister() }   // avoid a dangling userData pointer in the Carbon handler
}
