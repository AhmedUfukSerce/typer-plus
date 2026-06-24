import SwiftUI
import AppKit

// MARK: - Root shell — ONE page, no sidebar.
//
// Home is the always-on main page (composer + modes + recent feed). The secondary pages
// (History / Settings / Help) are reached from the top-right cluster and push over Home
// with a back button. Snippets was removed. The whole app lives on this single surface.

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            screen
                .id(model.selection)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                        removal: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.cream.ignoresSafeArea())
        .preferredColorScheme(.light)
        .animation(Motion.screen, value: model.selection)
    }

    @ViewBuilder private var screen: some View {
        switch model.selection {
        case .home:     HomeView()
        case .history:  HistoryView()
        case .settings: SettingsView()
        case .help:     HelpView()
        }
    }
}

// MARK: - Top bar — brand / back on the left, nav cluster + account on the right

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    private var onHome: Bool { model.selection == .home }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if onHome {
                HStack(spacing: Spacing.xs) {
                    TyperMark().frame(width: 22, height: 22)
                    Text("Typer+").font(Typo.logo).tracking(-0.4)
                        .foregroundStyle(Theme.textPrimary).fixedSize()
                }
                .allowsHitTesting(false)   // let the brand area drag the window too
            } else {
                BackButton(title: "Home") { withAnimation(Motion.screen) { model.selection = .home } }
            }
            Spacer(minLength: Spacing.md)
            NavCluster()
        }
        .frame(height: 28)
        .padding(.top, 10)
        .padding(.bottom, Spacing.xs)
        .padding(.leading, Layout.trafficLightInset)   // clear the window traffic lights
        .padding(.trailing, Spacing.lg)
        // Native drag region (the same performDrag helper the bubble uses): gives the main
        // window a reliable, full-width title-bar grab area. Without it the whole surface is
        // a SwiftUI NSHostingView whose opaque background defeats the native titlebar drag, so
        // the window felt un-movable / "snapped back" (only isMovableByWindowBackground caught
        // tiny slivers). The NavCluster buttons sit in front and keep working.
        .background(WindowDragArea())
    }
}

// Back affordance — generic "Home" target (so it never duplicates the page's own title),
// with the same hover language as the right-cluster icon buttons.
struct BackButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text(title).font(AppFont.inter(.semibold, 17)).tracking(-0.2)
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textBody)
            .padding(.vertical, 4).padding(.trailing, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Theme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to Home")
    }
}

// MARK: - Nav cluster (top-right): pop-out • History / Settings / Help • account

struct NavCluster: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Permission pill — shown only when access is missing (actionable, not a fake avatar).
            if !model.ready {
                Button { model.openAccessibilitySettings() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                        Text("Grant access").font(AppFont.inter(.medium, 12)).foregroundStyle(Theme.warning)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Capsule().fill(Theme.warning.opacity(0.12)))
                }
                .buttonStyle(.plain).help("Typer+ needs Accessibility access")
            }

            TopBarButton(symbol: "pip.enter", help: "Open pop-out (⌘⌥B)") { model.openBubble() }

            Rectangle().fill(Theme.divider).frame(width: 1, height: 18)

            ForEach(Screen.secondary) { s in
                TopBarButton(symbol: s.symbol, help: s.rawValue,
                             active: model.selection == s,
                             warn: s == .settings && !model.ready) {
                    model.selection = s
                }
            }
        }
    }
}

struct TopBarButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var warn: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).icon(.affordance)
                .foregroundStyle(active ? Theme.teal : (hovering ? Theme.textPrimary : Theme.iconGray))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.tealFill : (hovering ? Theme.hoverFill : .clear)))
                .overlay(alignment: .topTrailing) {
                    if warn { Circle().fill(Theme.warning).frame(width: 5, height: 5).offset(x: -3, y: 3) }
                }
        }
        .buttonStyle(.plain).help(help).onHover { hovering = $0 }
    }
}
