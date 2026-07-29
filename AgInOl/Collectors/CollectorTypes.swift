//
//  CollectorTypes.swift
//  AgInOl
//
//  Shared types for the provider collectors. Logic ported from
//  neo-agent-deck (MIT, m-a-b-u) and openusage (MIT, Robin Ebers).
//

import Foundation

nonisolated enum SessionState: String, Sendable {
    case working
    case attention
    case idle
}

nonisolated struct SessionSnapshot: Sendable {
    /// Stable ack key, e.g. "claude:<sessionId>".
    var key: String
    var id: String
    var state: SessionState
    var isOpen: Bool
    var activityAt: Date
    var completionAt: Date?
    /// Most recently used model in this session, when the logs reveal it.
    var model: String?
    /// Human-readable name for this session — the provider's own title
    /// where it has one, otherwise the working directory it runs in.
    var title: String?
}

nonisolated struct UsageWindowSnapshot: Sendable {
    var label: String          // "5h", "7d", "1w"…
    var percent: Double?       // 0...1 for limit-style windows
    var tokens: Double?        // token count for token-style windows
    var resetsAt: Date?
    var periodSeconds: Double?
}

nonisolated struct UsageSnapshot: Sendable {
    var windows: [UsageWindowSnapshot] = []
    var costUSD: Double?
    var updatedAt: Date?
    var error: String?
}

nonisolated struct ProviderReport: Sendable {
    var installed: Bool
    var sessions: [SessionSnapshot] = []
    var usage = UsageSnapshot()
    /// Offline token/cost estimate from local logs (Claude only, so far).
    var spend: SpendSnapshot?
}

/// Ack bookkeeping handed to every collect() call, mirroring
/// neo-agent-deck's PersistedState.
nonisolated struct CollectorContext: Sendable {
    /// Completions older than this never demand attention (app launch time).
    var attentionSince: Date
    /// key → last time the user acknowledged that session.
    var acknowledged: [String: Date]
    /// Whether collectors may call vendor usage endpoints (user setting,
    /// default off). Local file reading is always allowed.
    var allowNetwork: Bool = false

    func isAcknowledged(_ key: String, at date: Date) -> Bool {
        guard let ack = acknowledged[key] else { return false }
        return date <= ack
    }
}

nonisolated protocol AgentCollector: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    func collect(context: CollectorContext) async -> ProviderReport
}
