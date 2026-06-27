import AppKit
import SwiftUI

/// Owns the SwiftUI main window. Created and retained by AppController. The window is
/// built once and reused (never released on close), so the menu bar / hotkey keep the
/// app alive in the background and a Dock-click can re-show it instantly.
final class MainWindowController {

    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = RootView().environmentObject(model).ignoresSafeArea()
        let host = FirstMouseHostingController(rootView: root)
        // Don't let SwiftUI's measured content size drive a minimum that overrides the
        // window's own `minSize` below — otherwise the window resists shrinking and "snaps
        // back" to a larger size. The window stays freely resizable down to `minSize`.
        if #available(macOS 13.0, *) { host.sizingOptions = [] }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        win.contentViewController = host
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.title = "Typer+"
        win.isReleasedWhenClosed = false          // mandatory: reused on reopen
        win.minSize = NSSize(width: 720, height: 560)
        win.backgroundColor = NSColor(Theme.cream)   // single source of truth (DesignSystem)
        win.center()
        win.setFrameAutosaveName("TyperPlusMain")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

/// Hosting view that accepts the FIRST mouse click even when the window is in the
/// background. During a run Typer+ is deactivated (so the target app keeps focus), so the
/// main window is a background window — without this, clicking the on-screen Stop button
/// would be consumed just to re-activate the app (the button wouldn't fire until a 2nd
/// click, and the activation would steal focus mid-run). With it, the Stop button halts
/// the run on the very first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() { view = FirstMouseHostingView(rootView: rootView) }
}
