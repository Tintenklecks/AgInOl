//
//  DeckMirror.swift
//  AgInOl Companion
//
//  Mirrored view of the Mac deck. Companion interactions are sent as
//  requests; only the Mac applies and persists them as source of truth.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class DeckMirror {
    private(set) var snapshot: DeckSnapshot?
    /// Ticks so elapsed-time labels stay live between snapshots.
    private(set) var now = Date()
    private(set) var historyEntries: [SnapshotHistoryEntry] = []
    private(set) var historyContents: [String: String] = [:]
    private(set) var historyNextCursor: SnapshotHistoryCursor?
    private(set) var isLoadingHistory = false
    private(set) var historyError: String?
    private(set) var includingHiddenHistory = false

    @ObservationIgnored private let sync: any DeckSyncSubscribing
    @ObservationIgnored private let requester: (any CompanionRequesting)?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var pending: [String: PendingRequest] = [:]
    @ObservationIgnored private var assignmentOverrides: [Int: SnapshotTileAssignment] = [:]

    private enum PendingRequest {
        case tile(slot: Int, assignment: SnapshotTileAssignment, sentAt: Date)
        case historyPage(reset: Bool)
        case historyDetail(eventID: String)
        case historyHidden(eventID: String, hidden: Bool)
    }

    /// Defaults to the iCloud KVS transport. Built in the body rather
    /// than as a default argument, which would be evaluated off the actor.
    init(sync: (any DeckSyncSubscribing)? = nil) {
        let service = sync ?? KVSDeckSyncService()
        self.sync = service
        requester = service as? any CompanionRequesting
    }

    func start() {
        sync.onChange = { [weak self] snapshot in
            guard let self else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                self.snapshot = snapshot
                if let layout = snapshot.content.layout {
                    self.assignmentOverrides = self.assignmentOverrides.filter { slot, assignment in
                        guard layout.assignments.indices.contains(slot) else { return false }
                        return layout.assignments[slot] != assignment
                    }
                }
            }
        }
        requester?.onResponse = { [weak self] response in
            self?.receive(response)
        }
        sync.start()
        snapshot = sync.latest

        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
    }

    var agents: [SnapshotAgent] { snapshot?.content.agents ?? [] }
    var usage: [SnapshotUsage] { snapshot?.content.usage ?? [] }
    var layout: SnapshotDeckLayout? { snapshot?.content.layout }

    var tileAssignments: [SnapshotTileAssignment] {
        let slotCount = max((layout?.columns ?? 4) * (layout?.rows ?? 2), 1)
        var result = layout?.assignments ?? legacyAssignments
        if result.count < slotCount {
            result.append(contentsOf: repeatElement(.spacer, count: slotCount - result.count))
        }
        if result.count > slotCount { result = Array(result.prefix(slotCount)) }
        for (slot, assignment) in assignmentOverrides where result.indices.contains(slot) {
            result[slot] = assignment
        }
        return result
    }

    private var legacyAssignments: [SnapshotTileAssignment] {
        var assignments = agents.compactMap {
            SnapshotTileAssignment(rawValue: $0.id + "Status")
        }
        assignments.append(contentsOf: usage.compactMap { usage in
            switch usage.id {
            case "claude-usage": .claudeUsed
            case "claude-session": .claudeSessionUsed
            case "claude-spend": .claudeSpend
            case "codex-usage": .codexUsed
            case "codex-session": .codexSessionUsed
            case "opencode-usage": .opencodeUsage
            case "kimi-usage": .kimiUsage
            default: nil
            }
        })
        return assignments
    }

    func assign(_ assignment: SnapshotTileAssignment, toSlot slot: Int) {
        guard tileAssignments.indices.contains(slot) else { return }
        assignmentOverrides[slot] = assignment
        send(.setTile(slot: slot, assignment: assignment), pending: .tile(
            slot: slot,
            assignment: assignment,
            sentAt: Date()
        ))
    }

    func loadFirstHistoryPage(includingHidden: Bool? = nil) {
        if let includingHidden { includingHiddenHistory = includingHidden }
        historyEntries = []
        historyContents = [:]
        historyNextCursor = nil
        requestHistoryPage(reset: true, before: nil)
    }

    func loadNextHistoryPage() {
        guard !isLoadingHistory, let historyNextCursor else { return }
        requestHistoryPage(reset: false, before: historyNextCursor)
    }

    func loadHistoryDetail(eventID: String) {
        guard historyContents[eventID] == nil else { return }
        send(.historyDetail(eventID: eventID), pending: .historyDetail(eventID: eventID))
    }

    func setHistoryHidden(_ hidden: Bool, eventID: String) {
        send(.setHistoryHidden(eventID: eventID, hidden: hidden),
             pending: .historyHidden(eventID: eventID, hidden: hidden))
    }

    private func requestHistoryPage(reset: Bool, before: SnapshotHistoryCursor?) {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        send(.historyPage(limit: 10, before: before, includingHidden: includingHiddenHistory),
             pending: .historyPage(reset: reset))
    }

    private func send(_ action: CompanionRequest.Action, pending pendingRequest: PendingRequest) {
        guard let requester else {
            historyError = String(localized: "Mac request channel unavailable")
            isLoadingHistory = false
            return
        }
        let request = CompanionRequest(
            id: UUID().uuidString.lowercased(),
            deviceID: requester.deviceID,
            sentAt: Date(),
            action: action
        )
        pending[request.id] = pendingRequest
        requester.send(request)
    }

    private func receive(_ response: CompanionResponse) {
        guard let request = pending.removeValue(forKey: response.requestID) else { return }
        switch response.payload {
        case .acknowledged:
            applyAcknowledgement(for: request)
        case .historyPage(let entries, let nextCursor):
            guard case .historyPage(let reset) = request else { return }
            historyEntries = reset ? entries : merged(historyEntries, with: entries)
            historyNextCursor = nextCursor
            isLoadingHistory = false
        case .historyDetail(let eventID, let content):
            historyContents[eventID] = content
        case .failed(let message):
            if case .tile(let slot, _, _) = request { assignmentOverrides[slot] = nil }
            isLoadingHistory = false
            historyError = message
        }
    }

    private func applyAcknowledgement(for request: PendingRequest) {
        switch request {
        case .tile(let slot, let assignment, _):
            // Keep the optimistic value until the next authoritative layout
            // snapshot arrives from the Mac.
            assignmentOverrides[slot] = assignment
        case .historyHidden(let eventID, let hidden):
            if includingHiddenHistory {
                historyEntries = historyEntries.map { entry in
                    guard entry.eventID == eventID else { return entry }
                    return SnapshotHistoryEntry(
                        eventID: entry.eventID,
                        occurredAt: entry.occurredAt,
                        providerID: entry.providerID,
                        providerName: entry.providerName,
                        preview: entry.preview,
                        hasFullContent: entry.hasFullContent,
                        isHidden: hidden
                    )
                }
            } else if hidden {
                historyEntries.removeAll { $0.eventID == eventID }
            }
        case .historyPage:
            isLoadingHistory = false
        case .historyDetail:
            break
        }
    }

    private func merged(_ current: [SnapshotHistoryEntry],
                        with next: [SnapshotHistoryEntry]) -> [SnapshotHistoryEntry] {
        var seen = Set(current.map(\.eventID))
        return current + next.filter { seen.insert($0.eventID).inserted }
    }

    /// iCloud KVS delivers in seconds-to-minutes, so the age of the data
    /// is part of the data — never render a stale deck as if it were live.
    var age: TimeInterval? {
        snapshot.map { now.timeIntervalSince($0.capturedAt) }
    }

    var ageCaption: String {
        guard let age else { return String(localized: "waiting for Mac…") }
        let seconds = max(0, Int(age))
        return switch seconds {
        case ..<45:    String(localized: "just now")
        case ..<3600:  String(localized: "\(seconds / 60) min ago")
        default:       String(localized: "\(seconds / 3600) h ago")
        }
    }

    var isStale: Bool { (age ?? .infinity) > 300 }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60, s = seconds % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }
}
