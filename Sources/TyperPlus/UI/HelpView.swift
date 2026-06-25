import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ScreenHeader("Help")

                HelpCard(title: "How to use", icon: "list.number") {
                    NumberedList([
                        "Paste or type your text into the composer on Home.",
                        "Pick a Mode (Careful, Ultra Fast, Max Speed, or Max Stealth).",
                        "Click “Type it” — a short countdown starts.",
                        "During the countdown, click the field you want typed into.",
                        "Typer+ types it character-by-character, like a person.",
                        "Need to stop? Press Esc three times fast."
                    ])
                }

                HelpCard(title: "Safety", icon: "hand.raised") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        bullet("xmark.octagon", "Triple-Esc kill switch — press Esc Esc Esc within ~0.9s to stop typing instantly. This is the only thing that stops a run. Typing, moving the mouse, or switching tabs does NOT interrupt it. Typer+ never injects Esc, so this gesture is always yours.")
                        bullet("lock.shield", "It freezes in password fields (Secure Input) so keystrokes are never dropped, then resumes automatically when the field loses focus.")
                    }
                }

                HelpCard(title: "How detectable is this? (honest)", icon: "eye.trianglebadge.exclamationmark") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Typer+ sends real OS-level keystrokes, so the page or app sees genuine hardware key events with no paste — this defeats the web / JavaScript layer that catches paste-and-bot behavior.")
                        Text("It does NOT make you invisible. A native local monitor can read the source process ID of injected events — an unavoidable ceiling against native lockdown / proctoring apps. The web, Docs and biometric layers can't see it; a hardened native app can.")
                        Text("Our timing model is self-graded against research baselines — a built-in regression guard, not a guarantee against real commercial detectors.")
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.contentPadH)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
            .clampContentWidth()
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 18)
            Text(text).font(Typo.caption).foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HelpCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Theme.textPrimary)
                Text(title).font(Typo.cardTitle).foregroundStyle(Theme.textPrimary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Spacing.cardRadius, padding: Spacing.lg)
    }
}

struct NumberedList: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Text("\(i + 1)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.accent.opacity(0.14)))
                    Text(t).font(Typo.body).foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
