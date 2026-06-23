import AppKit

/// Snapshot of what the menu needs to render.
struct MenuState {
    let statusText: String
    let ready: Bool
    let killSwitchArmed: Bool
    let typing: Bool
    let mode: TypingProfile.Mode
    let preventSleep: Bool
    let bubbleVisible: Bool
}

/// Owns the menu-bar `NSStatusItem`, its menu, and the paste-box popover. Menu
/// items target the `AppController` via selectors.
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private weak var controller: AppController?

    private var statusLine: NSMenuItem!
    private var typeItem: NSMenuItem!
    private var typeClipboardItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var modeItems: [NSMenuItem] = []
    private var preventSleepItem: NSMenuItem!
    private var bubbleItem: NSMenuItem!
    private var stopHintItem: NSMenuItem!

    private let popover = NSPopover()
    private let pasteVC = PasteBoxViewController()

    func install(controller: AppController) {
        self.controller = controller

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard",
                                           accessibilityDescription: "Typer+")

        // Popover wiring.
        pasteVC.onType = { [weak controller] text in
            controller?.beginTyping(text)
        }
        pasteVC.onModeChange = { [weak controller] mode in
            controller?.setMode(mode)
        }
        popover.behavior = .transient
        popover.contentViewController = pasteVC

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: "Typer+", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        typeItem = NSMenuItem(title: "Type pasted text…",
                              action: #selector(AppController.openPasteBox),
                              keyEquivalent: "")
        typeItem.target = controller
        menu.addItem(typeItem)

        typeClipboardItem = NSMenuItem(title: "Type clipboard now",
                                       action: #selector(AppController.typeClipboard),
                                       keyEquivalent: "")
        typeClipboardItem.target = controller
        menu.addItem(typeClipboardItem)

        stopItem = NSMenuItem(title: "Stop typing",
                              action: #selector(AppController.stopTyping),
                              keyEquivalent: "")
        stopItem.target = controller
        menu.addItem(stopItem)

        menu.addItem(.separator())

        // Floating bubble toggle (also bound to the ⌘⌥B global hotkey).
        bubbleItem = NSMenuItem(title: "Show floating bubble",
                                action: #selector(AppController.toggleBubble),
                                keyEquivalent: "")
        bubbleItem.target = controller
        menu.addItem(bubbleItem)

        menu.addItem(.separator())

        // Mode submenu.
        let modeMenu = NSMenu()
        for mode in TypingProfile.Mode.allCases {
            let it = NSMenuItem(title: mode.rawValue,
                                action: #selector(AppController.selectMode(_:)),
                                keyEquivalent: "")
            it.representedObject = mode.rawValue
            it.target = controller
            modeMenu.addItem(it)
            modeItems.append(it)
        }
        let modeParent = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        preventSleepItem = NSMenuItem(title: "Prevent display sleep",
                                      action: #selector(AppController.togglePreventSleep),
                                      keyEquivalent: "")
        preventSleepItem.target = controller
        menu.addItem(preventSleepItem)

        menu.addItem(.separator())

        let permItem = NSMenuItem(title: "Open Accessibility Settings…",
                                  action: #selector(AppController.openAccessibilitySettings),
                                  keyEquivalent: "")
        permItem.target = controller
        menu.addItem(permItem)

        menu.addItem(.separator())

        stopHintItem = NSMenuItem(title: "Stop with: Esc Esc Esc", action: nil, keyEquivalent: "")
        stopHintItem.isEnabled = false
        menu.addItem(stopHintItem)

        let quitItem = NSMenuItem(title: "Quit Typer+",
                                  action: #selector(AppController.quit),
                                  keyEquivalent: "q")
        quitItem.target = controller
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Show the paste-box popover anchored to the status item.
    func showPasteBox() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Take focus so the user can paste immediately.
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePasteBox() {
        if popover.isShown { popover.performClose(nil) }
    }

    func refresh(_ state: MenuState) {
        statusLine.title = state.statusText
        stopItem.isEnabled = state.typing
        typeItem.isEnabled = state.ready && state.killSwitchArmed
        typeClipboardItem.isEnabled = state.ready && state.killSwitchArmed

        for it in modeItems {
            it.state = (it.representedObject as? String == state.mode.rawValue) ? .on : .off
        }
        preventSleepItem.state = state.preventSleep ? .on : .off

        bubbleItem.title = state.bubbleVisible ? "Hide floating bubble" : "Show floating bubble"
        bubbleItem.state = state.bubbleVisible ? .on : .off

        stopHintItem.title = state.killSwitchArmed
            ? "Stop with: Esc Esc Esc"
            : "Stop gesture INACTIVE — grant Accessibility"

        let symbol: String
        if !state.ready { symbol = "exclamationmark.triangle" }
        else if state.typing { symbol = "keyboard.badge.ellipsis" }
        else { symbol = "keyboard" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "Typer+")
    }
}
