import SwiftUI
import AppKit

// MARK: - Helpers

func countWords(_ s: String) -> Int { s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
func pluralize(_ n: Int, _ singular: String) -> String { "\(n) " + (n == 1 ? singular : singular + "s") }

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Screen header

struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var large: Bool = false
    init(_ title: String, subtitle: String? = nil, large: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.large = large
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(large ? Typo.displaySerif : Typo.titleSerif)   // editorial serif headings
                .tracking(large ? -0.2 : -0.1)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).font(Typo.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Mode tag (dot + label)

struct ModeTag: View {
    let mode: TypingProfile.Mode
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.modeTint(mode)).frame(width: 6, height: 6)
            Text(mode.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textBody)
        }
        .padding(.vertical, 4).padding(.horizontal, 9)
        .background(Capsule().fill(Theme.hoverFill))
        .fixedSize()
    }
}

// MARK: - Mode card (prominent, selectable — the main-page mode picker, laid out in a grid)

struct ModeCard: View {
    let mode: TypingProfile.Mode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.teal : Theme.strokeWell,
                                          lineWidth: selected ? 1.5 : 1)
                        .frame(width: 18, height: 18)
                    if selected { Circle().fill(Theme.teal).frame(width: 9, height: 9) }
                }
                Circle().fill(Theme.modeTint(mode)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue).font(AppFont.inter(.semibold, 15)).foregroundStyle(Theme.textPrimary)
                    Text(mode.subtitle).font(Typo.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: Spacing.sm)
            }
            .padding(.vertical, Spacing.sm).padding(.horizontal, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
                .fill(selected ? Theme.tealFill : (hovering ? Theme.hoverFill : Theme.beigeCard)))
            .overlay(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
                .strokeBorder(selected ? Theme.teal.opacity(0.55) : Theme.beigeStroke,
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Feed row (time + body + hover actions) — Home & History

struct FeedRow: View {
    let session: TypingSession
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(session.date, format: .dateTime.hour().minute())
                .font(Typo.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Spacing.timeColumnWidth, alignment: .leading)
            Text(session.preview)
                .font(Typo.body)
                .foregroundStyle(Theme.textBody)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .trailing) {
                ModeTag(mode: session.mode).opacity(hovering ? 0 : 1)
                RowActions(copy: { copyToPasteboard(session.text) },
                           typeAgain: { model.typeText(session.text, mode: session.mode) },
                           canType: model.ready && !model.isTyping)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : 6)
            }
            .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.vertical, Spacing.sessionRowVPadding)
        .padding(.horizontal, hovering ? Spacing.xs : 0)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hoverFill : .clear))
        .animation(Motion.spring, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct RowActions: View {
    let copy: () -> Void
    let typeAgain: () -> Void
    var canType: Bool = true
    var body: some View {
        HStack(spacing: 2) {
            RowIconButton(system: "doc.on.doc", help: "Copy", action: copy)
            RowIconButton(system: "return", help: "Type again", action: typeAgain).disabled(!canType)
        }
    }
}

struct RowIconButton: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system).icon(.affordance)
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.iconGray)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var art: AnyView? = nil
    var icon: String = "tray"
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: Spacing.sm) {
            Group {
                if let art { art.frame(width: 132, height: 100) }
                else { Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.bottom, Spacing.xxs)
            Text(title).font(Typo.cardTitle).tracking(-0.2).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Typo.caption).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320).lineSpacing(2)
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle) }.buttonStyle(PrimaryButtonStyle()).padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, Spacing.xxl)
    }
}

