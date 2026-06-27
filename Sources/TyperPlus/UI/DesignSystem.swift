//
//  DesignSystem.swift
//  Typer+ — color, type, spacing, elevation, motion, and shared components.
//  Warm-minimal: black primary actions, a single teal data accent, neutral nav,
//  serif display numbers. One source of truth.
//

import SwiftUI

// MARK: - Color hex convenience

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Theme

enum Theme {
    // Surfaces — warm plaster + oak beige (RenderPlus palette).
    static let cream          = Color(red: 0.957, green: 0.945, blue: 0.911) // #F4F1E8 window / plaster
    static let panel          = Color(red: 0.981, green: 0.973, blue: 0.947) // #FAF8F1 cards / surface
    static let beigeCard      = Color(red: 0.922, green: 0.902, blue: 0.851) // #EBE6D9 warm-beige card
    static let creamSunken    = Color(red: 0.906, green: 0.883, blue: 0.827) // #E7E1D3 wells / sunken

    // Interaction tints (warm ink, low alpha).
    static let hoverFill      = Color(red: 0.10, green: 0.09, blue: 0.06).opacity(0.035)
    static let pressedFill    = Color(red: 0.10, green: 0.09, blue: 0.06).opacity(0.060)

    // The single rationed accent + primary — RenderPlus sage-olive green (was teal).
    // Name kept as `teal` so every existing call site re-tints to green automatically.
    static let teal        = Color(red: 0.309, green: 0.435, blue: 0.321) // #4F6F52 sage-olive green
    static let tealPressed = Color(red: 0.271, green: 0.384, blue: 0.289) // #45624A
    static let tealFill    = Color(red: 0.309, green: 0.435, blue: 0.321).opacity(0.13)

    // Alias kept for the few call sites that read `accent` (Settings/Help/Glyphs).
    static let accent = teal

    // Text — warm ink ramp, no pure black.
    static let textPrimary     = Color(red: 0.169, green: 0.165, blue: 0.150) // #2B2A26 warm ink
    static let textBody        = Color(red: 0.227, green: 0.216, blue: 0.196) // #3A3732
    static let textSecondary   = Color(red: 0.561, green: 0.541, blue: 0.514) // #8F8A83
    static let textTertiary    = Color(red: 0.690, green: 0.671, blue: 0.643) // #B0ABA4
    static let iconGray        = Color(red: 0.482, green: 0.467, blue: 0.443) // #7B7771

    // Hairlines / strokes — warm, low contrast.
    static let divider     = Color(red: 0.114, green: 0.106, blue: 0.094).opacity(0.07)
    static let strokeWell  = Color(red: 0.114, green: 0.106, blue: 0.094).opacity(0.10)
    static let beigeStroke = Color(red: 0.114, green: 0.106, blue: 0.094).opacity(0.06)

    // Status.
    static let success = teal
    static let warning = Color(red: 0.78, green: 0.52, blue: 0.18) // #C7852E
    static let danger  = Color(red: 0.74, green: 0.27, blue: 0.22) // #BD4538

    // Per-mode tints — muted, cohesive, no purple.
    static func modeTint(_ m: TypingProfile.Mode) -> Color {
        switch m {
        case .careful:    return Color(red: 0.231, green: 0.451, blue: 0.380) // sage green
        case .ultraFast:  return Color(red: 0.275, green: 0.435, blue: 0.580) // dusty blue
        case .maxSpeed:   return Color(red: 0.792, green: 0.353, blue: 0.235) // hot red-orange
        case .maxStealth: return Color(red: 0.380, green: 0.365, blue: 0.341) // graphite
        }
    }
}

// MARK: - Typography

enum Typo {
    // Editorial serif (New York) — big display headings, à la RenderPlus's Fraunces.
    static let displaySerif  = AppFont.serif(32, .semibold)
    static let titleSerif    = AppFont.serif(24, .semibold)

    // Sans (Inter) — the UI.
    static let welcome       = AppFont.inter(.semibold, 28, relativeTo: .largeTitle)
    static let screenTitle   = AppFont.inter(.semibold, 22, relativeTo: .title)
    static let cardTitle     = AppFont.inter(.semibold, 17, relativeTo: .headline)
    static let body          = AppFont.inter(.regular, 16, relativeTo: .body)
    static let bodyTight     = AppFont.inter(.regular, 15, relativeTo: .callout)
    static let buttonLabel   = AppFont.inter(.semibold, 14.5, relativeTo: .subheadline)
    static let caption       = AppFont.inter(.regular, 13, relativeTo: .footnote)
    static let caption2      = AppFont.inter(.regular, 12, relativeTo: .caption)
    static let sectionHeader = AppFont.inter(.semibold, 11.5, relativeTo: .caption2)
    static let logo          = AppFont.inter(.bold, 21, relativeTo: .title2)
}

// MARK: - Spacing & metrics

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 40

    static let contentPadH: CGFloat = 36

    // Architectural radii (RenderPlus 6/8) — off the generic 12/18.
    static let cardRadius: CGFloat = 8
    static let navRadius: CGFloat = 6
    static let buttonRadius: CGFloat = 6
    static let fieldRadius: CGFloat = 6

    static let buttonHeight: CGFloat = 40
    static let fieldHeight: CGFloat = 36

    static let cardPadding: CGFloat = 22
    static let composerPadding: CGFloat = 20
    static let sessionRowVPadding: CGFloat = 14

    static let timeColumnWidth: CGFloat = 58
    static let sectionTracking: CGFloat = 0.8
}

// MARK: - Motion

enum Motion {
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.80)
    static let gentle = Animation.easeOut(duration: 0.20)
    static let screen = Animation.easeInOut(duration: 0.22)
}

// MARK: - Elevation

struct ShadowLayer { let color: Color; let radius: CGFloat; let x: CGFloat; let y: CGFloat }
struct Elevation { let contact: ShadowLayer; let ambient: ShadowLayer }

enum Elev {
    private static func warm(_ a: Double) -> Color { Color(red: 0.118, green: 0.090, blue: 0.055).opacity(a) }
    static let navPill = Elevation(contact: ShadowLayer(color: warm(0.05), radius: 1, x: 0, y: 1),
                                   ambient: ShadowLayer(color: warm(0.04), radius: 5, x: 0, y: 2))
    // Borders-first (RenderPlus): static cards carry NO resting shadow — just a hairline.
    static let card    = Elevation(contact: ShadowLayer(color: .clear, radius: 0, x: 0, y: 0),
                                   ambient: ShadowLayer(color: .clear, radius: 0, x: 0, y: 0))
    static let whisper = card
    static let flat    = Elevation(contact: ShadowLayer(color: .clear, radius: 0, x: 0, y: 0),
                                   ambient: ShadowLayer(color: warm(0.03), radius: 8, x: 0, y: 2))
    static let popover = Elevation(contact: ShadowLayer(color: warm(0.07), radius: 4, x: 0, y: 2),
                                   ambient: ShadowLayer(color: warm(0.12), radius: 40, x: 0, y: 20))
}

extension View {
    func elevation(_ e: Elevation) -> some View {
        self.shadow(color: e.contact.color, radius: e.contact.radius, x: e.contact.x, y: e.contact.y)
            .shadow(color: e.ambient.color, radius: e.ambient.radius, x: e.ambient.x, y: e.ambient.y)
    }
}

// MARK: - Card

struct CardModifier: ViewModifier {
    var radius: CGFloat = Spacing.cardRadius
    var padding: CGFloat = Spacing.cardPadding
    var fill: Color = Theme.panel
    var elevation: Elevation = Elev.card
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.strokeWell, lineWidth: 1))
            .elevation(elevation)
    }
}
extension View {
    func card(radius: CGFloat = Spacing.cardRadius, padding: CGFloat = Spacing.cardPadding,
              fill: Color = Theme.panel, elevation: Elevation = Elev.card) -> some View {
        modifier(CardModifier(radius: radius, padding: padding, fill: fill, elevation: elevation))
    }
}

// MARK: - Hover lift (subtle)

struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(hovering && !reduceMotion ? 0.05 : 0),
                    radius: hovering ? 8 : 0, x: 0, y: hovering ? 3 : 0)
            .animation(Motion.gentle, value: hovering)
            .onHover { hovering = $0 }
    }
}
extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

// MARK: - Staggered appear

struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.easeOut(duration: 0.26).delay(min(Double(index) * 0.035, 0.25))) { shown = true }
            }
    }
}
extension View { func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) } }

// MARK: - Icon cohesion

enum IconRole {
    case nav, affordance, inlineHint
    var size: CGFloat { switch self { case .nav: 16.5; case .affordance: 14.5; case .inlineHint: 12 } }
    var weight: Font.Weight { self == .nav ? .regular : .medium }
}
extension Image {
    func icon(_ role: IconRole) -> some View {
        self.font(.system(size: role.size, weight: role.weight))
            .symbolRenderingMode(.monochrome)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.buttonLabel)
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: Spacing.buttonHeight)
            .padding(.horizontal, Spacing.md)
            .background(RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                .fill(configuration.isPressed ? Theme.tealPressed : Theme.teal))   // sage-green primary
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.buttonLabel)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: Spacing.buttonHeight)
            .padding(.horizontal, Spacing.md)
            .background(RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                .fill(configuration.isPressed ? Theme.pressedFill : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                .strokeBorder(Theme.strokeWell, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(Typo.sectionHeader)
            .tracking(Spacing.sectionTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Hairline

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.divider).frame(height: 1) }
}
