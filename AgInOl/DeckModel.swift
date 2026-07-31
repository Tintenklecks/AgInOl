//
//  DeckModel.swift
//  AgInOl
//
//  Demo-data model for Phase 1. Phase 2 replaces the demo seed with
//  live collectors (~/.claude, ~/.codex, OpenCode SQLite, ~/.kimi-code).
//

import SwiftUI
import Observation

// MARK: - Agents

enum AgentStatus: String {
    case working
    case needsYou
    case idle
    case offline

    var label: String {
        switch self {
        case .working:  String(localized: "WORKING")
        case .needsYou: String(localized: "NEED YOU")
        case .idle:     String(localized: "IDLE")
        case .offline:  String(localized: "NOT FOUND")
        }
    }

    var tint: Color {
        switch self {
        case .working:  DeckColor.green
        case .needsYou: DeckColor.amber
        case .idle:     DeckColor.gray
        case .offline:  Color(white: 0.35)
        }
    }

    var tileBackground: Color {
        switch self {
        case .working:  DeckColor.greenTile
        case .needsYou: DeckColor.amberTile
        case .idle:     DeckColor.grayTile
        case .offline:  Color(red: 0.10, green: 0.10, blue: 0.12)
        }
    }
}

/// One live session behind a key, named with whatever title the
/// provider's own logs reveal (project folder, session title, prompt).
struct AgentSession: Identifiable {
    enum State {
        case working
        case attention
        case idle
    }

    /// The collector's ack key, e.g. "claude:<sessionId>".
    let id: String
    let title: String
    let state: State
    /// Waiting time for `attention`, last activity otherwise.
    let since: Date?

    var tint: Color {
        switch state {
        case .working:   DeckColor.green
        case .attention: DeckColor.amber
        case .idle:      DeckColor.gray
        }
    }
}

struct Agent: Identifiable {
    let id: String
    let name: String
    var status: AgentStatus
    var sessions: Int
    var startedAt: Date?
    /// Models in use, most-recent first, display-shortened.
    var models: [String] = []
    /// The open sessions behind `sessions`, most interesting first
    /// (waiting, then working, then idle). Capped by the collector.
    var openSessions: [AgentSession] = []

    /// Sessions demanding a reply — empty unless `needsYou`.
    var attention: [AgentSession] { openSessions.filter { $0.state == .attention } }

    /// "1 active" / "1 attention" / "1 open". The first two count only
    /// the sessions in that state, so the number matches what the
    /// sessions sheet lists; "open" counts them all.
    var sessionCaption: String {
        switch status {
        case .working:  String(localized: "\(count(of: .working)) active")
        case .needsYou: String(localized: "\(count(of: .attention)) attention")
        case .idle:     String(localized: "\(sessions) open")
        case .offline:  ""
        }
    }

    /// Sessions in one state, falling back to the open count for data
    /// that carries no session list (pre-collector state, demo seeds).
    private func count(of state: AgentSession.State) -> Int {
        let matching = openSessions.filter { $0.state == state }.count
        return matching > 0 ? matching : sessions
    }

    /// Third line on the key: which session it is, not how to click it —
    /// the sheet the key opens lists them all.
    var hintCaption: String {
        guard status != .offline else { return String(localized: "not installed") }
        let shown = status == .needsYou ? attention : openSessions
        guard let first = shown.first else {
            return status == .needsYou ? String(localized: "waiting for you") : String(localized: "live backend")
        }
        return shown.count > 1 ? "\(first.title) +\(shown.count - 1)" : first.title
    }
}

// MARK: - Usage tiles

struct ProviderUsage: Identifiable {
    enum Kind {
        /// Plan-limit style: 34% of the 7d window used.
        case percent(fraction: Double, window: String)
        /// Token-count style: 5.18M tokens, $3.84 over 7d.
        case tokens(count: Double, cost: Double, window: String)
        /// Provider missing, still loading, or errored.
        case unavailable(caption: String)
    }

    let id: String
    let name: String
    let tint: Color
    let tileBackground: Color
    var kind: Kind
    /// Extra detail shown only on the info-bar page (e.g. Claude's 5h window).
    var secondaryText: String?
    /// When the limit window resets; shown as a live countdown in the info bar.
    var resetsAt: Date?

    var bigValue: String {
        switch kind {
        case .percent(let fraction, _):
            "\(Int((fraction * 100).rounded()))%"
        case .tokens(let count, _, _):
            count >= 1_000_000
                ? String(format: "%.2fM", count / 1_000_000)
                : String(format: "%.0fK", count / 1_000)
        case .unavailable:
            "—"
        }
    }

    var caption: String {
        switch kind {
        case .percent(_, let window):
            String(localized: "\(window) used")
        case .tokens(_, let cost, let window):
            // A zero cost means "this provider reports no spend", not
            // "you spent nothing" — don't print $0.00 as if it were a fact.
            // Keep in step with SnapshotUsage.caption.
            cost > 0
                ? String(localized: "$\(cost, format: .number.precision(.fractionLength(2))) / \(window)")
                : String(localized: "\(window) tokens")
        case .unavailable(let caption):
            String(localized: String.LocalizationValue(caption))
        }
    }

    var barFraction: Double? {
        switch kind {
        case .percent(let fraction, _): fraction
        case .tokens, .unavailable: nil
        }
    }
}

// MARK: - Key assignments

/// What one configurable deck key displays. Chosen per key via long-press.
enum KeyAssignment: String, CaseIterable, Identifiable, Codable {
    case claudeStatus, codexStatus, opencodeStatus, kimiStatus
    case allAgents, history
    case claudeUsed, claudeLeft, claudeSpend
    case claudeSessionUsed, claudeSessionLeft
    case codexUsed, codexLeft
    case codexSessionUsed, codexSessionLeft
    case opencodeUsage, kimiUsage
    case info, clock
    case spacer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeStatus:   String(localized: "Claude · status")
        case .codexStatus:    String(localized: "Codex · status")
        case .opencodeStatus: String(localized: "OpenCode · status")
        case .kimiStatus:     String(localized: "Kimi · status")
        case .allAgents:      String(localized: "All agents")
        case .history:        String(localized: "Activity history")
        case .claudeUsed:     String(localized: "Claude · % used")
        case .claudeLeft:     String(localized: "Claude · % left")
        case .claudeSpend:    String(localized: "Claude · tokens & cost")
        case .claudeSessionUsed: String(localized: "Claude · % used session")
        case .claudeSessionLeft: String(localized: "Claude · % left session")
        case .codexUsed:      String(localized: "Codex · % used")
        case .codexLeft:      String(localized: "Codex · % left")
        case .codexSessionUsed: String(localized: "Codex · % used session")
        case .codexSessionLeft: String(localized: "Codex · % left session")
        case .opencodeUsage:  String(localized: "OpenCode · tokens")
        case .kimiUsage:      String(localized: "Kimi · tokens")
        case .info:           String(localized: "Info pages")
        case .clock:          String(localized: "Clock")
        case .spacer:         String(localized: "Empty")
        }
    }

    /// Short label for the per-provider layer of the key picker.
    var metricLabel: String {
        switch self {
        case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus: String(localized: "Status")
        case .claudeUsed, .codexUsed:                      String(localized: "% used")
        case .claudeLeft, .codexLeft:                      String(localized: "% left")
        case .claudeSessionUsed, .codexSessionUsed:        String(localized: "% used session")
        case .claudeSessionLeft, .codexSessionLeft:        String(localized: "% left session")
        case .claudeSpend, .opencodeUsage, .kimiUsage:     String(localized: "Tokens & cost")
        case .allAgents:                                   String(localized: "All agents")
        case .history:                                     String(localized: "Activity history")
        case .info:                                        String(localized: "Info pages")
        case .clock:                                       String(localized: "Clock")
        case .spacer:                                      String(localized: "Empty")
        }
    }

    /// Provider backing this assignment, if any.
    var providerID: String? {
        switch self {
        case .claudeStatus, .claudeUsed, .claudeLeft, .claudeSpend,
             .claudeSessionUsed, .claudeSessionLeft: "claude"
        case .codexStatus, .codexUsed, .codexLeft,
             .codexSessionUsed, .codexSessionLeft:   "codex"
        case .opencodeStatus, .opencodeUsage:              "opencode"
        case .kimiStatus, .kimiUsage:                      "kimi"
        case .allAgents, .history, .info, .clock, .spacer: nil
        }
    }

    /// Row-major fresh-install defaults; the first 8 are the original 4×2
    /// layout. Larger grids continue with these defaults and then use info
    /// tiles up to the configurable 6×6 maximum.
    static let defaultLayout: [KeyAssignment] = [
        .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus,
        .claudeUsed, .codexUsed, .opencodeUsage, .kimiUsage,
        .history, .allAgents, .claudeSpend, .clock,
        .claudeSessionUsed, .codexSessionUsed, .claudeLeft, .codexLeft,
        .claudeSessionLeft, .codexSessionLeft, .clock, .info,
        .info, .info, .info, .info,
    ]

    static func defaultAssignment(forSlot slot: Int) -> KeyAssignment {
        defaultLayout.indices.contains(slot) ? defaultLayout[slot] : .info
    }
}

// MARK: - Model-name shortening

enum ModelName {
    /// "claude-opus-4-8-20260101" → "opus-4-8"; "gpt-5.6-sol" stays.
    static func short(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        name = name.replacingOccurrences(of: #"-20\d{6}$"#, with: "",
                                         options: .regularExpression)
        return name
    }
}

// MARK: - Model

@Observable
final class DeckModel {
    var agents: [Agent]
    var usage: [ProviderUsage]
    var now = Date()
    var infoPageIndex = 0
    var keyAssignments: [KeyAssignment]
    private(set) var layoutRevision: Int

    private var tickTimer: Timer?
    private var pageTimer: Timer?

    private static let assignmentsKey = "KeyAssignments"
    private static let layoutRevisionKey = "KeyLayoutRevision"

    init(agents: [Agent], usage: [ProviderUsage]) {
        self.agents = agents
        self.usage = usage
        layoutRevision = UserDefaults.standard.integer(forKey: Self.layoutRevisionKey)
        if let stored = UserDefaults.standard.stringArray(forKey: Self.assignmentsKey),
           !stored.isEmpty {
            keyAssignments = stored.enumerated().map { slot, raw in
                KeyAssignment(rawValue: raw) ?? KeyAssignment.defaultAssignment(forSlot: slot)
            }
        } else {
            keyAssignments = KeyAssignment.defaultLayout
        }
    }

    /// Assignment shown in `slot`, falling back to defaults for slots the
    /// stored layout hasn't covered yet (the grid can grow in settings).
    func assignment(forSlot slot: Int) -> KeyAssignment {
        keyAssignments.indices.contains(slot) ? keyAssignments[slot]
            : KeyAssignment.defaultAssignment(forSlot: slot)
    }

    func assign(_ assignment: KeyAssignment, toSlot slot: Int) {
        guard slot >= 0 else { return }
        while keyAssignments.count <= slot {
            keyAssignments.append(KeyAssignment.defaultAssignment(forSlot: keyAssignments.count))
        }
        guard keyAssignments[slot] != assignment else { return }
        keyAssignments[slot] = assignment
        UserDefaults.standard.set(keyAssignments.map(\.rawValue), forKey: Self.assignmentsKey)
        layoutRevision += 1
        UserDefaults.standard.set(layoutRevision, forKey: Self.layoutRevisionKey)
    }

    // MARK: Lookups for key rendering

    func agent(withID id: String) -> Agent? {
        agents.first { $0.id == id }
    }

    func usageEntry(forProvider id: String) -> ProviderUsage? {
        usage.first { $0.id.hasPrefix(id) }
    }

    func usageEntry(withID id: String) -> ProviderUsage? {
        usage.first { $0.id == id }
    }

    func pageIndex(forUsageID id: String) -> Int? {
        usage.firstIndex { $0.id == id }.map { agents.count + 1 + $0 }
    }

    /// Info-bar page index showing this agent / usage entry.
    func pageIndex(forAgent id: String) -> Int? {
        agents.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    func pageIndex(forUsageProvider id: String) -> Int? {
        usage.firstIndex { $0.id.hasPrefix(id) }.map { agents.count + 1 + $0 }
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

    /// Set by CollectorHub; when nil (previews/demo) the tile flips locally.
    var onAcknowledge: ((String) -> Void)?

    func acknowledge(_ agent: Agent) {
        guard agent.status == .needsYou else { return }
        if let onAcknowledge {
            onAcknowledge(agent.id)
            return
        }
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index].status = .working
        agents[index].startedAt = Date()
    }

    /// Replace the demo/previous data with a fresh collector snapshot.
    func apply(agents newAgents: [Agent], usage newUsage: [ProviderUsage]) {
        agents = newAgents
        usage = newUsage
        if infoPageIndex >= infoPages.count {
            infoPageIndex = 0
        }
    }

    /// Neutral pre-collector state so real data never has to displace
    /// convincing-looking fake numbers.
    static func initial() -> DeckModel {
        DeckModel(
            agents: [
                Agent(id: "claude", name: "CLAUDE", status: .idle, sessions: 0, startedAt: nil),
                Agent(id: "codex", name: "CODEX", status: .idle, sessions: 0, startedAt: nil),
                Agent(id: "opencode", name: "OPENCODE", status: .idle, sessions: 0, startedAt: nil),
                Agent(id: "kimi", name: "KIMI", status: .idle, sessions: 0, startedAt: nil),
            ],
            usage: [
                ProviderUsage(id: "claude-usage", name: "CLAUDE", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
                ProviderUsage(id: "claude-session", name: "CLAUDE", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
                ProviderUsage(id: "codex-usage", name: "CODEX", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
                ProviderUsage(id: "codex-session", name: "CODEX", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
                ProviderUsage(id: "opencode-usage", name: "OPENCODE", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
                ProviderUsage(id: "kimi-usage", name: "KIMI", tint: DeckColor.gray,
                              tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")),
            ]
        )
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
                Agent(id: "claude", name: "CLAUDE", status: .working, sessions: 2,
                      startedAt: Date().addingTimeInterval(-742),
                      openSessions: [
                        AgentSession(id: "claude:a", title: "AgInOl", state: .working,
                                     since: Date().addingTimeInterval(-742)),
                        AgentSession(id: "claude:b", title: "PUCO App", state: .idle,
                                     since: Date().addingTimeInterval(-1840)),
                      ]),
                Agent(id: "codex", name: "CODEX", status: .needsYou, sessions: 1,
                      startedAt: Date().addingTimeInterval(-3120),
                      openSessions: [
                        AgentSession(id: "codex:demo", title: "Stage Rehersal",
                                     state: .attention,
                                     since: Date().addingTimeInterval(-96)),
                      ]),
                Agent(id: "opencode", name: "OPENCODE", status: .idle, sessions: 1,
                      startedAt: nil,
                      openSessions: [
                        AgentSession(id: "opencode:a", title: "refactor the deck view",
                                     state: .idle,
                                     since: Date().addingTimeInterval(-5400)),
                      ]),
                Agent(id: "kimi", name: "KIMI", status: .working, sessions: 4,
                      startedAt: Date().addingTimeInterval(-210),
                      openSessions: [
                        AgentSession(id: "kimi:a", title: "add mcp for IBKR", state: .working,
                                     since: Date().addingTimeInterval(-210)),
                        AgentSession(id: "kimi:b", title: "2ndbrain", state: .idle,
                                     since: Date().addingTimeInterval(-960)),
                        AgentSession(id: "kimi:c", title: "invoice parser", state: .idle,
                                     since: Date().addingTimeInterval(-3200)),
                        AgentSession(id: "kimi:d", title: "site rebuild", state: .idle,
                                     since: Date().addingTimeInterval(-8400)),
                      ]),
            ],
            usage: [
                ProviderUsage(id: "claude-usage", name: "CLAUDE",
                              tint: DeckColor.orange, tileBackground: DeckColor.brownTile,
                              kind: .percent(fraction: 0.34, window: "7d")),
                ProviderUsage(id: "claude-session", name: "CLAUDE",
                              tint: DeckColor.orange, tileBackground: DeckColor.brownTile,
                              kind: .percent(fraction: 0.42, window: "5h")),
                ProviderUsage(id: "codex-usage", name: "CODEX",
                              tint: DeckColor.cyan, tileBackground: DeckColor.blueTile,
                              kind: .percent(fraction: 0.25, window: "1w")),
                ProviderUsage(id: "codex-session", name: "CODEX",
                              tint: DeckColor.cyan, tileBackground: DeckColor.blueTile,
                              kind: .percent(fraction: 0.15, window: "5h")),
                ProviderUsage(id: "opencode-usage", name: "OPENCODE",
                              tint: DeckColor.purple, tileBackground: DeckColor.purpleTile,
                              kind: .tokens(count: 5_180_000, cost: 3.84, window: "7d")),
                ProviderUsage(id: "kimi-usage", name: "KIMI",
                              tint: DeckColor.magenta, tileBackground: DeckColor.magentaTile,
                              kind: .tokens(count: 1_240_000, cost: 0, window: "7d")),
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
