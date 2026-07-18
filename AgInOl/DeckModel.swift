//
//  DeckModel.swift
//  AgInOl
//
//  Demo-data model for Phase 1. Phase 2 replaces the demo seed with
//  live collectors (~/.claude, ~/.codex, OpenCode SQLite).
//

import SwiftUI
import Observation

// MARK: - Palette (matched to the Neo Agent Deck reference)

enum DeckColor {
    static let green  = Color(red: 0.22, green: 0.87, blue: 0.45)
    static let amber  = Color(red: 1.00, green: 0.72, blue: 0.10)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.26)
    static let cyan   = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let purple = Color(red: 0.72, green: 0.60, blue: 0.99)
    static let gray   = Color(white: 0.62)

    // Tile card backgrounds
    static let greenTile  = Color(red: 0.09, green: 0.23, blue: 0.15)
    static let amberTile  = Color(red: 0.29, green: 0.20, blue: 0.05)
    static let grayTile   = Color(red: 0.15, green: 0.16, blue: 0.19)
    static let oliveTile  = Color(red: 0.26, green: 0.19, blue: 0.04)
    static let brownTile  = Color(red: 0.25, green: 0.13, blue: 0.06)
    static let blueTile   = Color(red: 0.06, green: 0.15, blue: 0.25)
    static let purpleTile = Color(red: 0.15, green: 0.11, blue: 0.27)
    static let indigoTile = Color(red: 0.18, green: 0.13, blue: 0.30)

    static let screen = Color(red: 0.05, green: 0.055, blue: 0.07)
}

// MARK: - Agents

enum AgentStatus: String {
    case working
    case needsYou
    case idle

    var label: String {
        switch self {
        case .working:  "WORKING"
        case .needsYou: "NEED YOU"
        case .idle:     "IDLE"
        }
    }

    var tint: Color {
        switch self {
        case .working:  DeckColor.green
        case .needsYou: DeckColor.amber
        case .idle:     DeckColor.gray
        }
    }

    var tileBackground: Color {
        switch self {
        case .working:  DeckColor.greenTile
        case .needsYou: DeckColor.amberTile
        case .idle:     DeckColor.grayTile
        }
    }
}

struct Agent: Identifiable {
    let id: String
    let name: String
    var status: AgentStatus
    var sessions: Int
    var startedAt: Date?

    /// "1 active" / "1 attention" / "1 open"
    var sessionCaption: String {
        switch status {
        case .working:  "\(sessions) active"
        case .needsYou: "\(sessions) attention"
        case .idle:     "\(sessions) open"
        }
    }

    var hintCaption: String {
        status == .needsYou ? "tap to acknowledge" : "live backend"
    }
}

// MARK: - Usage tiles

struct ProviderUsage: Identifiable {
    enum Kind {
        /// Plan-limit style: 34% of the 7d window used.
        case percent(fraction: Double, window: String)
        /// Token-count style: 5.18M tokens, $3.84 over 7d.
        case tokens(count: Double, cost: Double, window: String)
    }

    let id: String
    let name: String
    let tint: Color
    let tileBackground: Color
    var kind: Kind

    var bigValue: String {
        switch kind {
        case .percent(let fraction, _):
            "\(Int((fraction * 100).rounded()))%"
        case .tokens(let count, _, _):
            count >= 1_000_000
                ? String(format: "%.2fM", count / 1_000_000)
                : String(format: "%.0fK", count / 1_000)
        }
    }

    var caption: String {
        switch kind {
        case .percent(_, let window):
            "\(window) used"
        case .tokens(_, let cost, let window):
            String(format: "$%.2f / %@", cost, window)
        }
    }

    var barFraction: Double? {
        switch kind {
        case .percent(let fraction, _): fraction
        case .tokens: nil
        }
    }
}

// MARK: - Model

@Observable
final class DeckModel {
    var agents: [Agent]
    var usage: [ProviderUsage]
    var now = Date()
    var infoPageIndex = 0

    private var tickTimer: Timer?
    private var pageTimer: Timer?

    init(agents: [Agent], usage: [ProviderUsage]) {
        self.agents = agents
        self.usage = usage
    }

    // MARK: Aggregates (ALL AGENTS tile + info bar)

    var openSessions: Int { agents.reduce(0) { $0 + $1.sessions } }
    var workingCount: Int { agents.filter { $0.status == .working }.count }
    var attentionCount: Int { agents.filter { $0.status == .needsYou }.count }

    // MARK: Info bar pages

    struct InfoPage: Identifiable {
        enum Content {
            /// ALL AGENTS · 4 OPEN 1 WORK 1 NEED YOU
            case summary
            case agent(Agent)
            case usage(ProviderUsage)
        }

        let id: Int
        let content: Content
    }

    var infoPages: [InfoPage] {
        var pages: [InfoPage] = [InfoPage(id: 0, content: .summary)]
        for agent in agents {
            pages.append(InfoPage(id: pages.count, content: .agent(agent)))
        }
        for entry in usage {
            pages.append(InfoPage(id: pages.count, content: .usage(entry)))
        }
        return pages
    }

    var currentPage: InfoPage? { infoPages[safe: infoPageIndex] }

    func advancePage(by delta: Int) {
        let count = max(infoPages.count, 1)
        infoPageIndex = (infoPageIndex + delta + count) % count
    }

    func showSummaryPage() {
        infoPageIndex = 0
    }

    func acknowledge(_ agent: Agent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        if agents[index].status == .needsYou {
            agents[index].status = .working
            agents[index].startedAt = Date()
        }
    }

    // MARK: Timers

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        pageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    self.advancePage(by: 1)
                }
            }
        }
    }

    // MARK: Formatting

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60, s = seconds % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Demo seed (mirrors the reference image)

    static func demo() -> DeckModel {
        DeckModel(
            agents: [
                Agent(id: "claude", name: "CLAUDE", status: .working, sessions: 1,
                      startedAt: Date().addingTimeInterval(-742)),
                Agent(id: "codex", name: "CODEX", status: .needsYou, sessions: 1,
                      startedAt: Date().addingTimeInterval(-3120)),
                Agent(id: "opencode", name: "OPENCODE", status: .idle, sessions: 1,
                      startedAt: nil),
            ],
            usage: [
                ProviderUsage(id: "claude-usage", name: "CLAUDE",
                              tint: DeckColor.orange, tileBackground: DeckColor.brownTile,
                              kind: .percent(fraction: 0.34, window: "7d")),
                ProviderUsage(id: "codex-usage", name: "CODEX",
                              tint: DeckColor.cyan, tileBackground: DeckColor.blueTile,
                              kind: .percent(fraction: 0.25, window: "1w")),
                ProviderUsage(id: "opencode-usage", name: "OPENCODE",
                              tint: DeckColor.purple, tileBackground: DeckColor.purpleTile,
                              kind: .tokens(count: 5_180_000, cost: 3.84, window: "7d")),
            ]
        )
    }
}

// MARK: - Helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
