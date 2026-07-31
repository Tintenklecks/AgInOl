//
//  DeckSnapshot.swift
//  AgInOl — shared by the Mac app and the companion
//
//  Wire format for mirroring the Mac deck onto companion devices.
//  Deliberately free of SwiftUI types: the receiver owns its own palette
//  and grid, so the phone can restyle without breaking the format.
//

import Foundation

struct DeckSnapshot: Codable, Sendable {
    /// Bump when a change stops being decodable by shipped builds.
    /// Receivers drop snapshots they don't understand rather than
    /// rendering a half-decoded deck.
    static let currentVersion = 1

    var version: Int = DeckSnapshot.currentVersion
    var capturedAt: Date
    var content: DeckSnapshotContent
}

/// Split out from the envelope so change detection can ignore
/// `capturedAt` — otherwise every poll would look like a change.
struct DeckSnapshotContent: Codable, Equatable, Sendable {
    var agents: [SnapshotAgent]
    var usage: [SnapshotUsage]
    /// Optional so Companion builds that still receive a v1 snapshot can
    /// fall back to their legacy automatically-generated grid.
    var layout: SnapshotDeckLayout? = nil
}

struct SnapshotDeckLayout: Codable, Equatable, Sendable {
    let revision: Int
    let columns: Int
    let rows: Int
    let assignments: [SnapshotTileAssignment]
}

/// Platform-neutral counterpart of the Mac's `KeyAssignment`. Raw values
/// deliberately match so the Mac can validate and apply Companion commands.
enum SnapshotTileAssignment: String, Codable, CaseIterable, Identifiable, Sendable {
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
}

// MARK: - Companion requests and responses

/// KVS mailbox message written by a Companion. The Mac is the only process
/// that applies mutations or reads the authoritative history database.
struct CompanionRequest: Codable, Sendable {
    enum Action: Codable, Sendable {
        case setTile(slot: Int, assignment: SnapshotTileAssignment)
        case historyPage(limit: Int, before: SnapshotHistoryCursor?, includingHidden: Bool)
        case historyDetail(eventID: String)
        case setHistoryHidden(eventID: String, hidden: Bool)
    }

    let id: String
    let deviceID: String
    let sentAt: Date
    let action: Action
}

struct CompanionResponse: Codable, Sendable {
    enum Payload: Codable, Sendable {
        case acknowledged
        case historyPage(entries: [SnapshotHistoryEntry], nextCursor: SnapshotHistoryCursor?)
        case historyDetail(eventID: String, content: String)
        case failed(message: String)
    }

    let requestID: String
    let deviceID: String
    let sentAt: Date
    let payload: Payload
}

struct SnapshotHistoryCursor: Codable, Hashable, Sendable {
    let occurredAt: Date
    let sequence: Int64

    private enum CodingKeys: String, CodingKey {
        case occurredAtSeconds, sequence
    }

    init(occurredAt: Date, sequence: Int64) {
        self.occurredAt = occurredAt
        self.sequence = sequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        occurredAt = Date(timeIntervalSince1970: try container.decode(
            Double.self,
            forKey: .occurredAtSeconds
        ))
        sequence = try container.decode(Int64.self, forKey: .sequence)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(occurredAt.timeIntervalSince1970, forKey: .occurredAtSeconds)
        try container.encode(sequence, forKey: .sequence)
    }
}

struct SnapshotHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let eventID: String
    let occurredAt: Date
    let providerID: String
    let providerName: String
    let preview: String
    let hasFullContent: Bool
    let isHidden: Bool

    var id: String { eventID }
}

struct SnapshotAgent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let status: SnapshotAgentStatus
    let sessions: Int
    /// Absolute, so the receiver can tick the elapsed label locally
    /// instead of needing a fresh snapshot every second.
    let startedAt: Date?
    let models: [String]
    /// Optional for wire compatibility with snapshots written by older Mac builds.
    let openSessions: [SnapshotAgentSession]?

    init(id: String, name: String, status: SnapshotAgentStatus, sessions: Int,
         startedAt: Date?, models: [String],
         openSessions: [SnapshotAgentSession]? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.sessions = sessions
        self.startedAt = startedAt
        self.models = models
        self.openSessions = openSessions
    }
}

enum SnapshotAgentStatus: String, Codable, Sendable {
    case working, needsYou, idle, offline
}

struct SnapshotAgentSession: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case working, attention, idle
    }

    let id: String
    let title: String
    let state: State
    let since: Date?
}

struct SnapshotUsage: Codable, Equatable, Sendable, Identifiable {
    enum Kind: Codable, Equatable, Sendable {
        case percent(fraction: Double, window: String)
        case tokens(count: Double, cost: Double, window: String)
        case unavailable(caption: String)
    }

    let id: String
    let name: String
    let palette: SnapshotPalette
    let kind: Kind
    let secondaryText: String?
    /// Optional for wire compatibility with snapshots written by older Mac builds.
    let resetsAt: Date?

    init(id: String, name: String, palette: SnapshotPalette, kind: Kind,
         secondaryText: String?, resetsAt: Date? = nil) {
        self.id = id
        self.name = name
        self.palette = palette
        self.kind = kind
        self.secondaryText = secondaryText
        self.resetsAt = resetsAt
    }
}

/// Semantic colour token rather than an encoded RGB value, so each
/// platform picks its own shades.
enum SnapshotPalette: String, Codable, Sendable {
    case claude, codex, kimi, opencode, neutral
}

// MARK: - Display helpers (identical on both platforms)

extension SnapshotUsage {
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

extension SnapshotAgentStatus {
    var label: String {
        switch self {
        case .working:  String(localized: "WORKING")
        case .needsYou: String(localized: "NEED YOU")
        case .idle:     String(localized: "IDLE")
        case .offline:  String(localized: "NOT FOUND")
        }
    }
}

extension SnapshotAgent {
    /// "4 active" / "1 attention" / "0 open" — mirrors the deck's own
    /// session caption so both platforms word it identically.
    var sessionCaption: String {
        switch status {
        case .working:  String(localized: "\(sessions) active")
        case .needsYou: String(localized: "\(sessions) attention")
        case .idle:     String(localized: "\(sessions) open")
        case .offline:  ""
        }
    }
}

extension Collection where Element == SnapshotAgent {
    var openSessions: Int { reduce(0) { $0 + $1.sessions } }
    var attentionCount: Int { count { $0.status == .needsYou } }
}
