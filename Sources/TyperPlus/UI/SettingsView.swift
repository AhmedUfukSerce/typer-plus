import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var countdown = Settings.shared.countdownSeconds
    @State private var preventSleep = Settings.shared.preventDisplaySleep
    @State private var forceUnicode = Settings.shared.forceUnicodeOnly
    @State private var reliableDelivery = Settings.shared.reliableDelivery
    @State private var pasteDelivery = Settings.shared.pasteDelivery

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ScreenHeader("Settings")

                card("General") {
                    settingRow("Default mode") {
                        Picker("", selection: model.modeBinding) {
                            ForEach(TypingProfile.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                card("Typing") {
                    settingRow("Countdown before typing") {
                        HStack(spacing: Spacing.sm) {
                            Slider(value: $countdown, in: 0...10, step: 1) { _ in
                                Settings.shared.countdownSeconds = countdown
                            }
                            .frame(width: 160)
                            Text("\(Int(countdown))s")
                                .font(Typo.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    Hairline()
                    settingRow("Prevent display sleep while typing") {
                        Toggle("", isOn: $preventSleep)
                            .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                            .onChange(of: preventSleep) { _, v in Settings.shared.preventDisplaySleep = v }
                    }
                    Hairline()
                    settingRow("Paste instead of type (fixes glitchy apps)") {
                        Toggle("", isOn: $pasteDelivery)
                            .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                            .onChange(of: pasteDelivery) { _, v in Settings.shared.pasteDelivery = v }
                    }
                    Text("Delivers your text as ONE instant paste (⌘V) instead of keystroke-by-keystroke. Bulletproof for web/Electron editors that glitch when typed into (random periods, dropped/merged spaces) — e.g. Feather. Ignores the typing mode/speed (it's instant) and your clipboard is restored afterward. Turn off for keystroke-level realism in apps that type fine.")
                        .font(Typo.caption2).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Hairline()
                    settingRow("Reliable delivery (works in every app)") {
                        Toggle("", isOn: $reliableDelivery)
                            .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                            .onChange(of: reliableDelivery) { _, v in Settings.shared.reliableDelivery = v }
                    }
                    Text("Types one key at a time so web / Electron apps (and sites) can't drop or batch keystrokes — no merged words or stray periods. Turn off only for maximum keystroke-dynamics stealth in a forgiving app (Terminal, native fields, Google Docs).")
                        .font(Typo.caption2).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Hairline()
                    settingRow("Force Unicode-only path (compatibility)") {
                        Toggle("", isOn: $forceUnicode)
                            .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                            .onChange(of: forceUnicode) { _, v in Settings.shared.forceUnicodeOnly = v }
                    }
                }

                card("Hotkey") {
                    settingRow("Type clipboard from anywhere") {
                        Text("⌘⌥T")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textBody)
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.creamSunken))
                    }
                }

                card("Residue policy") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.accent)
                        Text("Max Stealth deliberately leaves a few subtle, uncorrected slips (homophone / grammar only) so a Docs version-history replay looks organically composed. Careful, Ultra Fast and Max Speed keep output clean — every typo and grammar slip is corrected.")
                            .font(Typo.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                card("Permissions") {
                    settingRow(nil) {
                        HStack(spacing: 8) {
                            Image(systemName: model.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(model.ready ? Theme.success : Theme.warning)
                            Text("Accessibility").font(Typo.body).foregroundStyle(Theme.textBody)
                            Spacer()
                            Text(model.ready ? "Granted" : "Not granted")
                                .font(Typo.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if !model.ready {
                        Button { model.openAccessibilitySettings() } label: { Text("Open Accessibility Settings") }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.top, Spacing.xs)
                        Text("Typer+ needs Accessibility to send keystrokes to other apps.")
                            .font(Typo.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentPadH)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
            .clampContentWidth()
        }
    }

    // Card with a section title
    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: Spacing.sm) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: Spacing.cardRadius, padding: Spacing.lg)
        }
    }

    // A label + trailing control row
    private func settingRow<Trailing: View>(_ label: String?, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            if let label {
                Text(label).font(Typo.body).foregroundStyle(Theme.textBody)
            }
            Spacer()
            trailing()
        }
    }
}
