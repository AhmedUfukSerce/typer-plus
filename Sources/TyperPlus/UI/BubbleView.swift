//
//  BubbleView.swift
//  Typer+ — the always-on-top floating "bubble" overlay (SwiftUI content).
//
//  A tiny panel that floats above any app so the user never has to switch back to the
//  main window: pick a mode, then one button types whatever is on the clipboard into the
//  next field you click. Cleanup + the focus countdown are owned by the engine
//  (beginTyping). No text box — the source is always the clipboard (quick paste).
//
//  Built entirely from DesignSystem tokens (Theme / Typo / Spacing / Elev / Motion)
//  and the house brand mark (TyperMark) so it reads as the same product.
//
//  Architecture: the host (BubbleController) owns the borderless .statusBar-level
//  non-activating NSPanel and the persisted position; it drives this view via the
//  shared `AppModel` (so the bubble reflects the same run the menu / main window see)
//  plus four closures (drag / drag-ended / snap / close) and the current `anchor`.
//

import SwiftUI
import AppKit

// MARK: - Geometry (shared with the controller, which sizes the panel)

enum BubbleLayout {
    static let width:  CGFloat = 260
    static let height: CGFloat = 166
    static let radius: CGFloat = 20
    static let inset:  CGFloat = 14
    static let edgeMargin: CGFloat = 18   // gap from the screen edge when snapped

    // Minimized "sliver": just + (expand) and a short Type button, flush to the edge.
    static let collapsedWidth:  CGFloat = 196
    static let collapsedHeight: CGFloat = 34
    static let collapsedRadius: CGFloat = 11
}

// MARK: - Snap anchor (9-way grid, persisted)

/// Where the bubble sits when snapped. Free-dragging clears the snap (`.free`), but the
/// host remembers the last *grid* anchor so a re-snap returns there. Raw strings are the
/// persisted form in `Settings.bubbleCorner`.
enum BubbleAnchor: String, CaseIterable, Codable {
    case topLeft, topCenter, topRight
    case midLeft, center, midRight
    case botLeft, botCenter, botRight
    case free   // user-dragged; not part of the 3×3 grid

    /// Row-major 3×3 layout for the position picker.
    static let grid: [[BubbleAnchor]] = [
        [.topLeft, .topCenter, .topRight],
        [.midLeft, .center,    .midRight],
        [.botLeft, .botCenter, .botRight],
    ]

    var label: String {
        switch self {
        case .topLeft: "Top left";    case .topCenter: "Top";    case .topRight: "Top right"
        case .midLeft: "Left";        case .center: "Center";    case .midRight: "Right"
        case .botLeft: "Bottom left"; case .botCenter: "Bottom"; case .botRight: "Bottom right"
        case .free: "Custom"
        }
    }

    /// Bottom-left origin (AppKit screen coords) for a panel of `size` within `screen`
    /// (pass the screen's `visibleFrame`), inset by `margin` from the edges.
    func origin(in screen: NSRect, size: CGSize, margin: CGFloat = BubbleLayout.edgeMargin) -> CGPoint {
        let left   = screen.minX + margin
        let right  = screen.maxX - size.width - margin
        let cx     = screen.midX - size.width / 2
        let bottom = screen.minY + margin
        let top    = screen.maxY - size.height - margin
        let cy     = screen.midY - size.height / 2
        switch self {
        case .topLeft:   return CGPoint(x: left,  y: top)
        case .topCenter: return CGPoint(x: cx,    y: top)
        case .topRight:  return CGPoint(x: right, y: top)
        case .midLeft:   return CGPoint(x: left,  y: cy)
        case .center:    return CGPoint(x: cx,    y: cy)
        case .midRight:  return CGPoint(x: right, y: cy)
        case .botLeft:   return CGPoint(x: left,  y: bottom)
        case .botCenter: return CGPoint(x: cx,    y: bottom)
        case .botRight:  return CGPoint(x: right, y: bottom)
        case .free:      return CGPoint(x: cx,    y: cy)
        }
    }
}

/// `Settings.swift` persists the bubble's snap under the name `BubbleCorner`. The bubble
/// evolved into the richer 9-way `BubbleAnchor`; this alias keeps the persistence layer
/// pointed at a single source of truth (no duplicate enum; the old `.topRight` raw value
/// still resolves, so no migration is needed).
typealias BubbleCorner = BubbleAnchor

// MARK: - Run phase (drives the CTA + ambient state)

/// The bubble's CTA lifecycle. The engine owns the focus countdown (beginTyping runs its
/// own HUD), so the bubble only ever reflects pushed engine state: idle → typing/paused.
enum BubblePhase: Equatable {
    case idle
    case typing
    case paused
    case needsAccess

    var isBusy: Bool {
        switch self { case .typing: true; default: false }
    }
}

// MARK: - Compact mode metadata (speed read-out for the dense selector)

extension TypingProfile.Mode {
    /// Short cadence read-out shown beside the name in the compact menu. Derives from the
    /// single source of truth (`speedLabel`) so it never drifts from the actual preset; only
    /// Max Stealth gets a shorter custom tag for the dense bubble.
    var speedTag: String {
        switch self {
        case .maxStealth: return "stealth"
        default:          return speedLabel
        }
    }
}

// MARK: - The bubble

struct BubbleView: View {
    @EnvironmentObject var model: AppModel

    /// Hide the bubble.
    var onClose: () -> Void = {}
    /// Minimize to the bottom-right sliver.
    var onMinimize: () -> Void = {}
    /// Restore from the sliver to the full bubble.
    var onExpand: () -> Void = {}
    /// Whether to render the minimized sliver (only + and Type clipboard).
    var collapsed: Bool = false

    @State private var ctaHover = false

    /// Phase resolved purely from pushed engine state — no local countdown anymore;
    /// AppController.beginTyping owns the cleanup + the canonical countdown HUD.
    private var resolvedPhase: BubblePhase {
        if !model.ready { return .needsAccess }
        if model.isTyping { return model.paused ? .paused : .typing }
        return .idle
    }

    /// Mid-run states. While busy, hovering the CTA arms a red "Cancel" (big ✕) that stops it.
    private var ctaBusy: Bool { resolvedPhase == .typing || resolvedPhase == .paused }
    private var ctaCancel: Bool { ctaBusy && ctaHover }

    var body: some View {
        Group {
            if collapsed { collapsedBar } else { fullBubble }
        }
        .animation(Motion.spring, value: resolvedPhase)
    }

    // MARK: Full bubble — header + mode picker + the big Type-clipboard CTA

    private var fullBubble: some View {
        VStack(spacing: Spacing.sm) {
            header
            modePicker
            primaryCTA
        }
        .padding(BubbleLayout.inset)
        .frame(width: BubbleLayout.width, height: BubbleLayout.height)
        .background(surface(BubbleLayout.radius))
        .clipShape(RoundedRectangle(cornerRadius: BubbleLayout.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BubbleLayout.radius, style: .continuous)
                .strokeBorder(Theme.beigeStroke, lineWidth: 1)
        )
    }

    // MARK: Collapsed sliver — only + (expand) and Type clipboard; everything else off

    private var collapsedBar: some View {
        HStack(spacing: 5) {
            Button { onExpand() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.creamSunken))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeWell, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Expand")

            Button { primaryAction() } label: {
                HStack(spacing: 6) {
                    if ctaCancel {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        Text("Cancel")
                    } else {
                        ctaLeading
                        Text(shortCtaTitle).lineLimit(1)
                    }
                }
                .contentTransition(.opacity)
                .font(AppFont.inter(.semibold, 13))
                .foregroundStyle(ctaCancel ? .white : (ctaRole == .warning ? Theme.warning : .white))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ctaCancel ? Theme.danger
                          : (ctaRole == .warning ? Theme.warning.opacity(0.12) : Theme.teal)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { ctaHover = $0 }
            .help(ctaBusy ? "Cancel typing" : ctaHelp)
            .keyboardShortcut(.return, modifiers: [.command])
            .animation(Motion.snappy, value: ctaCancel)
        }
        .padding(4)
        .frame(width: BubbleLayout.collapsedWidth, height: BubbleLayout.collapsedHeight)
        .background(surface(BubbleLayout.collapsedRadius))
        .clipShape(RoundedRectangle(cornerRadius: BubbleLayout.collapsedRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BubbleLayout.collapsedRadius, style: .continuous)
                .strokeBorder(Theme.beigeStroke, lineWidth: 1)
        )
    }

    /// Short label for the tight sliver (the full "Type clipboard" truncates).
    private var shortCtaTitle: String {
        switch resolvedPhase {
        case .idle:        return "Type"
        case .typing:      return "Typing…"
        case .paused:      return "Paused"
        case .needsAccess: return "Grant"
        }
    }

    // MARK: Surface — warm floating card with a faint top-light

    private func surface(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.panel)
            .overlay(
                LinearGradient(colors: [Color.white.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .center)
                    .blendMode(.softLight)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .elevation(Elev.popover)
    }

    // MARK: Header — brand • drag handle • minimize • close
    //
    // The whole header is a drag region: the brand, the grip dots, and the gaps sit on a
    // native performDrag layer (allowsHitTesting(false) lets the click fall through), while
    // the minimize + close buttons stay interactive. With the panel's
    // isMovableByWindowBackground you can grab the bubble almost anywhere and move it.
    private var header: some View {
        HStack(spacing: Spacing.xs) {
            TyperMark()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Text("Typer+")
                .font(AppFont.inter(.bold, 15.5)).tracking(-0.3)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
                .allowsHitTesting(false)

            DragHandle()
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

            HeaderIconButton(system: "minus", help: "Minimize to corner") { onMinimize() }
            HeaderIconButton(system: "xmark", help: "Hide bubble (⌘⌥B)") { onClose() }
        }
        .frame(height: 24)
        .background(WindowDragArea())
    }

    // MARK: Mode picker — compact, bound to the shared mode (lock-step with Home/Settings)

    private var modePicker: some View {
        Menu {
            Picker("Mode", selection: model.modeBinding) {
                ForEach(TypingProfile.Mode.allCases, id: \.self) { m in
                    Text("\(m.rawValue)  ·  \(m.speedTag)").tag(m)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Theme.modeTint(model.mode)).frame(width: 7, height: 7)
                Text(model.mode.rawValue).font(AppFont.inter(.semibold, 12.5)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                Text(model.mode.speedTag).font(AppFont.inter(.medium, 11)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Spacing.navRadius, style: .continuous).fill(Theme.creamSunken))
            .overlay(RoundedRectangle(cornerRadius: Spacing.navRadius, style: .continuous).strokeBorder(Theme.strokeWell, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(resolvedPhase != .idle)
        .help("Typing mode")
    }

    // MARK: Primary CTA — the one quick-paste button, fills the remaining height

    private var primaryCTA: some View {
        Button { primaryAction() } label: {
            HStack(spacing: 7) {
                if ctaCancel {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    Text("Cancel")
                } else {
                    ctaLeading
                    Text(ctaTitle).lineLimit(1)
                }
            }
            .contentTransition(.opacity)
        }
        .buttonStyle(BubblePrimaryButtonStyle(role: ctaCancel ? .danger : ctaRole))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { ctaHover = $0 }
        .help(ctaBusy ? "Cancel typing" : ctaHelp)
        .keyboardShortcut(.return, modifiers: [.command])   // ⌘↩ quick-pastes
        .animation(Motion.snappy, value: ctaCancel)
    }

    @ViewBuilder private var ctaLeading: some View {
        switch resolvedPhase {
        case .typing:      TypingDots()
        case .paused:      Image(systemName: "pause.fill").font(.system(size: 12, weight: .bold))
        case .needsAccess: Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
        case .idle:        Image(systemName: "doc.on.clipboard").font(.system(size: 12, weight: .semibold))
        }
    }

    private var ctaTitle: String {
        switch resolvedPhase {
        case .idle:        return "Type clipboard"
        case .typing:      return "Typing…"
        case .paused:      return "Paused"
        case .needsAccess: return "Grant access"
        }
    }

    private var ctaRole: BubbleCTARole {
        switch resolvedPhase {
        case .needsAccess: .warning
        case .typing, .paused: .busy
        case .idle: .primary
        }
    }

    private var ctaHelp: String {
        switch resolvedPhase {
        case .idle:        "Type whatever is on your clipboard into the next field you click"
        case .typing:      "Stop typing"
        case .paused:      "Stop typing"
        case .needsAccess: "Open Accessibility settings"
        }
    }

    private func primaryAction() {
        switch resolvedPhase {
        case .needsAccess:     model.openAccessibilitySettings()
        case .idle:            model.typeClipboard()   // cleanup + countdown owned by engine
        case .typing, .paused: model.stop()
        }
    }

}

// MARK: - Native window drag (AppKit performDrag — smooth, no coordinate-space feedback)

/// A transparent NSView that hands a mouse-down straight to `window.performDrag(with:)`.
/// AppKit then drives the move at the window-server level (no jitter), and `performDrag`
/// returns when the mouse is released — so we fire `onEnded` for snap-to-corner + persist.
struct WindowDragArea: NSViewRepresentable {
    var onEnded: () -> Void = {}
    func makeNSView(context: Context) -> NSView { DragView(onEnded: onEnded) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragView)?.onEnded = onEnded
    }
    final class DragView: NSView {
        var onEnded: () -> Void
        init(onEnded: @escaping () -> Void) { self.onEnded = onEnded; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            onEnded()
        }
    }
}

// MARK: - Drag handle (centered grip dots)

private struct DragHandle: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Theme.textTertiary.opacity(0.55)).frame(width: 3, height: 3)
            }
        }
        .frame(height: 22)
        .accessibilityLabel("Drag to move")
    }
}

// MARK: - Header icon button (small, hover-lit)

private struct HeaderIconButton: View {
    let system: String
    var help: String = ""
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Theme.teal : (hovering ? Theme.textPrimary : Theme.iconGray))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Theme.tealFill : (hovering ? Theme.hoverFill : .clear))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Primary CTA style (role-tinted: black / teal-busy / amber-warning)

enum BubbleCTARole { case primary, busy, warning, danger }

struct BubblePrimaryButtonStyle: ButtonStyle {
    var role: BubbleCTARole = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.buttonLabel)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .padding(.horizontal, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Spacing.navRadius, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.navRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: role == .warning ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role { case .warning: Theme.warning; default: .white }
    }
    private var strokeColor: Color {
        role == .warning ? Theme.warning.opacity(0.5) : .clear
    }
    private func background(pressed: Bool) -> Color {
        switch role {
        case .primary: pressed ? Theme.tealPressed : Theme.teal   // green primary (matches the app)
        case .busy:    pressed ? Theme.tealPressed : Theme.teal
        case .warning: pressed ? Theme.warning.opacity(0.14) : Theme.warning.opacity(0.10)
        case .danger:  pressed ? Theme.danger.opacity(0.85) : Theme.danger
        }
    }
}
