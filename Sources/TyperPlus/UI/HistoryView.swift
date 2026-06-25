import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter: TypingProfile.Mode? = nil

    private var filtered: [TypingSession] {
        model.sessions.filter {
            (filter == nil || $0.mode == filter) &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ScreenHeader("History")

                HStack(spacing: Spacing.sm) {
                    searchField
                    modeFilter
                    Spacer()
                    if !model.sessions.isEmpty {
                        Button { withAnimation(Motion.gentle) { model.clearHistory() } } label: {
                            Text("Clear all").font(Typo.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.sessions.isEmpty {
                    EmptyStateView(art: AnyView(EmptyHistoryArt()), title: "No sessions yet",
                                   message: "Every block you type is saved here with its mode and time, so you can run it again later.")
                        .frame(maxWidth: .infinity).padding(.top, Spacing.xxl)
                } else if filtered.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Nothing matches",
                                   message: "No sessions match that search or filter.")
                        .frame(maxWidth: .infinity).padding(.top, Spacing.xxl)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, s in
                            FeedRow(session: s)
                                .staggeredAppear(idx)
                                .contextMenu {
                                    Button("Type again") { model.typeText(s.text, mode: s.mode) }
                                    Button("Copy text") { copyToPasteboard(s.text) }
                                    Button("Delete", role: .destructive) { model.deleteSession(s) }
                                }
                            if idx < filtered.count - 1 { Hairline() }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.contentPadH)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
            .clampContentWidth()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").icon(.affordance).foregroundStyle(Theme.iconGray)
            TextField("Search sessions", text: $query).textFieldStyle(.plain).font(Typo.caption)
        }
        .padding(.horizontal, Spacing.sm)
        .frame(maxWidth: 230)
        .frame(height: Spacing.fieldHeight)
        .background(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous).fill(Theme.creamSunken))
        .overlay(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous).strokeBorder(Theme.strokeWell, lineWidth: 1))
    }

    private var modeFilter: some View {
        Menu {
            Button("All modes") { filter = nil }
            ForEach(TypingProfile.Mode.allCases, id: \.self) { m in Button(m.rawValue) { filter = m } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").icon(.affordance)
                Text(filter?.rawValue ?? "All modes").font(Typo.caption)
            }
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, Spacing.sm)
            .frame(height: Spacing.fieldHeight)
            .background(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous).fill(Theme.creamSunken))
            .overlay(RoundedRectangle(cornerRadius: Spacing.fieldRadius, style: .continuous).strokeBorder(Theme.strokeWell, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
