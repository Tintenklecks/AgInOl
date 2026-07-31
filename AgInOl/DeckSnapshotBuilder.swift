//
//  DeckSnapshotBuilder.swift
//  AgInOl
//
//  Flattens the live deck model into the platform-neutral wire format.
//  Colours become semantic tokens here — the Mac's SwiftUI `Color`
//  values never go over the wire, so the companion stays free to style
//  its own grid.
//

import Foundation

extension DeckSnapshot {
    /// `Agent` and `ProviderUsage` are main-actor isolated, so the whole
    /// flattening step is too; it runs inside CollectorHub's poll cycle.
    @MainActor
    static func make(agents: [Agent],
                     usage: [ProviderUsage],
                     assignments: [KeyAssignment],
                     columns: Int,
                     rows: Int,
                     layoutRevision: Int,
                     at date: Date = Date()) -> DeckSnapshot {
        DeckSnapshot(
            capturedAt: date,
            content: DeckSnapshotContent(
                agents: agents.map(SnapshotAgent.init),
                usage: usage.map(SnapshotUsage.init),
                layout: SnapshotDeckLayout(
                    revision: layoutRevision,
                    columns: columns,
                    rows: rows,
                    assignments: assignments.map {
                        SnapshotTileAssignment(rawValue: $0.rawValue) ?? .spacer
                    }
                )
            )
        )
    }
}

private extension SnapshotAgent {
    @MainActor
    init(_ agent: Agent) {
        self.init(
            id: agent.id,
            name: agent.name,
            status: SnapshotAgentStatus(rawValue: agent.status.rawValue) ?? .offline,
            sessions: agent.sessions,
            startedAt: agent.startedAt,
            models: agent.models,
            openSessions: agent.openSessions.map(SnapshotAgentSession.init)
        )
    }
}

private extension SnapshotAgentSession {
    @MainActor
    init(_ session: AgentSession) {
        let state: State = switch session.state {
        case .working: .working
        case .attention: .attention
        case .idle: .idle
        }
        self.init(id: session.id, title: session.title, state: state, since: session.since)
    }
}

private extension SnapshotUsage {
    @MainActor
    init(_ usage: ProviderUsage) {
        let kind: Kind = switch usage.kind {
        case .percent(let fraction, let window):
            .percent(fraction: fraction, window: window)
        case .tokens(let count, let cost, let window):
            .tokens(count: count, cost: cost, window: window)
        case .unavailable(let caption):
            .unavailable(caption: caption)
        }

        self.init(
            id: usage.id,
            name: usage.name,
            palette: SnapshotPalette(tileID: usage.id, kind: kind),
            kind: kind,
            secondaryText: usage.secondaryText,
            resetsAt: usage.resetsAt
        )
    }
}

private extension SnapshotPalette {
    /// Tile ids are `"<provider>-<role>"` ("claude-usage",
    /// "codex-session", …), so the provider prefix carries the colour.
    init(tileID: String, kind: SnapshotUsage.Kind) {
        if case .unavailable = kind {
            self = .neutral
            return
        }
        switch tileID.prefix(while: { $0 != "-" }) {
        case "claude": self = .claude
        case "codex":  self = .codex
        case "kimi":   self = .kimi
        default:       self = .opencode
        }
    }
}
