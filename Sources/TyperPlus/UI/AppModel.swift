import SwiftUI
import AppKit

// MARK: - Codable conformance for the existing mode enum (String-raw → free)

extension TypingProfile.Mode: Codable {}

// MARK: - Models

/// One completed typing run, shown in History / the Home feed and driving the stats.
struct TypingSession: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let text: String
    let mode: TypingProfile.Mode
    let wordCount: Int
    let charCount: Int

    init(text: String, mode: TypingProfile.Mode, date: Date) {
        self.id = UUID()
        self.date = date
        self.text = text
        self.mode = mode
        self.charCount = text.count
        self.wordCount = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    /// Single-line, trimmed preview for row display.
    var preview: String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count <= 120 ? one : String(one.prefix(120)) + "…"
    }
}

/// Derived usage stats for the recent-feed header.
struct Stats {
    let totalSessions: Int
    let dayStreak: Int

    static func compute(from sessions: [TypingSession],
                        now: Date = Date(),
                        cal: Calendar = .current) -> Stats {
        let days = Set(sessions.map { cal.startOfDay(for: $0.date) }).sorted(by: >)
        var streak = 0
        var cursor = cal.startOfDay(for: now)
        // Don't break the streak just because they haven't typed yet *today*.
        if let newest = days.first, newest < cursor,
           let yday = cal.date(byAdding: .day, value: -1, to: cursor), newest == yday {
            cursor = yday
        }
        for d in days {
            if d == cursor {
                streak += 1
                cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            } else if d < cursor { break }
        }
        return Stats(totalSessions: sessions.count, dayStreak: streak)
    }
}

// MARK: - Navigation

enum Screen: String, Identifiable {
    case home = "Home", history = "History"
    case settings = "Settings", help = "Help"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home:     return "house"
        case .history:  return "clock"
        case .settings: return "gearshape"
        case .help:     return "questionmark"
        }
    }
    /// Secondary pages reached from the top-right cluster. Home is the always-on main page.
    static let secondary: [Screen] = [.history, .settings, .help]
}

// MARK: - AppModel (the single source of truth the SwiftUI tree observes)

/// Bridges the SwiftUI window to the existing AppKit engine. AppController owns this
/// strongly and pushes engine state into it via `apply(...)`; it holds a *weak* back
/// reference to the controller so there is no retain cycle. Also owns the persisted
/// session history (JSON in Application Support).
final class AppModel: ObservableObject {

    // Navigation
    @Published var selection: Screen = .home

    // Engine state (pushed from AppController.refreshUI on the main thread)
    @Published var ready = false
    @Published var armed = false
    @Published var isTyping = false
    @Published var paused = false
    @Published var statusText = "Typer+"
    @Published var mode: TypingProfile.Mode = Settings.shared.mode

    // Persisted data
    @Published private(set) var sessions: [TypingSession] = []

    weak var controller: AppController?

    var stats: Stats { Stats.compute(from: sessions) }
    var recent: [TypingSession] { Array(sessions.prefix(6)) }

    // MARK: Files — ~/Library/Application Support/Typer+/sessions.json
    private let dir: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typer+", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }

    init() { load() }

    // MARK: Intents (UI → engine)

    /// Home / History "Type it": optionally switch mode, then run.
    func typeText(_ text: String, mode: TypingProfile.Mode? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { NSSound.beep(); return }
        if let mode { controller?.setMode(mode) }
        controller?.beginTyping(text)   // AppController records the session when typing starts
    }

    func typeClipboard() { controller?.typeClipboard() }
    func toggleBubble() { controller?.toggleBubble() }
    func openBubble() { controller?.openBubble() }
    func stop() { controller?.stopTyping() }
    func setMode(_ m: TypingProfile.Mode) { controller?.setMode(m) }
    func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }

    /// Two-way binding for mode pickers.
    var modeBinding: Binding<TypingProfile.Mode> {
        Binding(get: { [weak self] in self?.mode ?? .ultraFast },
                set: { [weak self] in self?.setMode($0) })
    }

    // MARK: State push (AppController, main thread)

    func apply(ready: Bool, armed: Bool, isTyping: Bool, paused: Bool,
               statusText: String, mode: TypingProfile.Mode) {
        // Assign only on change: every @Published write fires objectWillChange (re-rendering
        // the whole SwiftUI tree) even when the value is identical, and AppController calls
        // this from refreshUI() repeatedly. Guarding keeps idle/typing refreshes cheap.
        if self.ready != ready { self.ready = ready }
        if self.armed != armed { self.armed = armed }
        if self.isTyping != isTyping { self.isTyping = isTyping }
        if self.paused != paused { self.paused = paused }
        if self.statusText != statusText { self.statusText = statusText }
        if self.mode != mode { self.mode = mode }
    }

    // MARK: Data mutations

    func recordSession(text: String, mode: TypingProfile.Mode, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions.insert(TypingSession(text: text, mode: mode, date: date), at: 0)
        if sessions.count > 300 { sessions.removeLast(sessions.count - 300) }
        save(sessions, to: sessionsURL)
    }
    func deleteSession(_ s: TypingSession) {
        sessions.removeAll { $0.id == s.id }; save(sessions, to: sessionsURL)
    }
    func clearHistory() { sessions.removeAll(); save(sessions, to: sessionsURL) }

    // MARK: IO

    private func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: sessionsURL),
           let v = try? dec.decode([TypingSession].self, from: d) { sessions = v }
    }
    /// Background serial queue for session persistence — keeps the JSON encode + atomic disk
    /// write OFF the main thread. recordSession() runs at the instant typing starts, so a
    /// synchronous write here would hitch the first keystrokes.
    private static let ioQueue = DispatchQueue(label: "com.aus.typerplus.sessions.io", qos: .utility)

    private func save<T: Encodable>(_ value: T, to url: URL) {
        AppModel.ioQueue.async {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }
}
