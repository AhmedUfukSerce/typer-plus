import SwiftUI
import AppKit

// Single-page Home, no scrolling — TWO columns so everything is visible at once:
//   LEFT  : the composer (text box + Type it) and, underneath, the recent history.
//   RIGHT : the modes (prominent selectable cards), quick actions, and stats.
// The text box flexes to fill the left column's spare height; the right column holds
// everything that used to get buried, so the modes are always reachable.

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @FocusState private var composerFocused: Bool

    private var words: Int { countWords(text) }
    private var trimmedEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSFullUserName()
    }
    private var greeting: String { firstName.isEmpty ? "Welcome back" : "Welcome back, \(firstName)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ScreenHeader(greeting, subtitle: "Click a field, then send your text to it.", large: true)
            HStack(alignment: .top, spacing: Spacing.lg) {
                leftColumn
                rightColumn.frame(width: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Spacing.contentPadH)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Left — composer (flex) + recent

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            composer.frame(maxHeight: .infinity)
            recent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            textWell.frame(maxHeight: .infinity)

            Button { primaryAction() } label: {
                HStack(spacing: Spacing.xs) {
                    if model.isTyping {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    }
                    Text(ctaTitle).contentTransition(.opacity)
                }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            // Enabled WHILE typing so it doubles as a reliable Stop button (the only on-screen
            // way to halt a run); disabled only when idle with nothing to send.
            .disabled(model.ready && !model.isTyping && trimmedEmpty)
            .animation(Motion.spring, value: model.isTyping)

            HStack(spacing: 6) {
                Image(systemName: "info.circle").icon(.inlineHint)
                Text("You'll get a moment to click your field.")
                Spacer()
                Text("\(pluralize(words, "word")) · \(pluralize(text.count, "character"))")
            }
            .font(Typo.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .card(radius: Spacing.cardRadius, padding: Spacing.composerPadding, fill: Theme.panel, elevation: Elev.whisper)
    }

    private var textWell: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Paste the text you want typed out.")
                    .font(Typo.body).foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .focused($composerFocused)
                .font(Typo.body).foregroundStyle(Theme.textBody)
                .tint(Theme.teal)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        .padding(Spacing.sm)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous).fill(Theme.creamSunken))
        .overlay(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous)
            .strokeBorder(composerFocused ? Theme.teal.opacity(0.55) : Theme.strokeWell,
                          lineWidth: composerFocused ? 1.5 : 1))
        .animation(Motion.spring, value: composerFocused)
    }

    private func primaryAction() {
        if !model.ready { model.openAccessibilitySettings(); return }
        if model.isTyping { model.stop(); return }   // doubles as Stop while a run is active
        model.typeText(text)
    }
    private var ctaTitle: String {
        if !model.ready { return "Grant Accessibility access" }
        if model.isTyping && model.paused { return "Stop — paused (secure field)" }
        if model.isTyping { return Settings.shared.pasteDelivery ? "Stop" : "Stop typing" }
        return Settings.shared.pasteDelivery ? "Paste it" : "Type it"
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                SectionHeader("Recent")
                Spacer()
                if !model.sessions.isEmpty {
                    Button { model.selection = .history } label: {
                        Text("View all").font(Typo.caption).foregroundStyle(Theme.teal)
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.recent.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft").icon(.inlineHint).foregroundStyle(Theme.textTertiary)
                    Text("Text you type from here shows up here and in History.")
                        .font(Typo.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, Spacing.xs)
            } else {
                let rows = Array(model.recent.prefix(3))
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, s in
                        FeedRow(session: s)
                        if idx < rows.count - 1 { Hairline() }
                    }
                }
            }
        }
    }

    // MARK: Right — modes (prominent) + quick actions + stats

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader("Mode")
                ForEach(TypingProfile.Mode.allCases, id: \.self) { m in
                    ModeCard(mode: m, selected: m == model.mode) { model.setMode(m) }
                }
            }
            .animation(Motion.snappy, value: model.mode)   // smooth selection transition
            actionsCard
            statStrip
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button { model.typeClipboard() } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "doc.on.clipboard").icon(.affordance)
                    Text("Type clipboard"); Spacer(minLength: 0)
                    Text("⌘⌥T").font(AppFont.inter(.medium, 12)).opacity(0.6)
                }
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            .disabled(!model.ready || model.isTyping)

            Button { model.openBubble() } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "pip.enter").icon(.affordance)
                    Text("Open pop-out"); Spacer(minLength: 0)
                    Text("⌘⌥B").font(AppFont.inter(.medium, 12)).opacity(0.6)
                }
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
        }
        .padding(Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).fill(Theme.beigeCard))
        .overlay(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).strokeBorder(Theme.beigeStroke, lineWidth: 1))
    }

    private var statStrip: some View {
        let s = model.stats   // compute once (Stats.compute sorts up to 300 dates) — not per stat
        return HStack(spacing: 0) {
            stat("\(s.totalSessions)", "sessions")
            Spacer(minLength: Spacing.sm)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 26)
            Spacer(minLength: Spacing.sm)
            stat("\(s.dayStreak)", "day streak")
        }
        .padding(.vertical, Spacing.sm).padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).fill(Theme.beigeCard))
        .overlay(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).strokeBorder(Theme.beigeStroke, lineWidth: 1))
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.serif(22, .semibold)).foregroundStyle(Theme.textPrimary).monospacedDigit()
            Text(unit).font(Typo.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
