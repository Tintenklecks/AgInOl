//
//  DeckMirror.swift
//  AgInOl Companion
//
//  Mirrored agent data with a device-local tile layout. The first layout is
//  seeded from the Mac; subsequent tile choices belong to this Companion.
//

import Observation
import SwiftUI

struct CompanionDeckLayout: Codable, Equatable {
    var assignments: [SnapshotTileAssignment]
}

@MainActor
protocol CompanionDeckLayoutStoring: AnyObject {
    func load() -> CompanionDeckLayout?
    func save(_ layout: CompanionDeckLayout)
}

@MainActor
final class UserDefaultsCompanionDeckLayoutStore: CompanionDeckLayoutStoring {
    private static let key = "CompanionDeckLayout.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CompanionDeckLayout? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(CompanionDeckLayout.self, from: data)
    }

    func save(_ layout: CompanionDeckLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

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
    private(set) var visibleSlotCount = 0
    private(set) var deviceLayout: CompanionDeckLayout?

    @ObservationIgnored private let sync: any DeckSyncSubscribing
    @ObservationIgnored private let requester: (any CompanionRequesting)?
    @ObservationIgnored private let layoutStore: any CompanionDeckLayoutStoring
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var pending: [String: PendingRequest] = [:]

    private enum PendingRequest {
        case historyPage(reset: Bool)
        case historyDetail(eventID: String)
        case historyHidden(eventID: String, hidden: Bool)
    }

    /// Defaults to the iCloud KVS transport. Built in the body rather
    /// than as a default argument, which would be evaluated off the actor.
    init(sync: (any DeckSyncSubscribing)? = nil,
         layoutStore: (any CompanionDeckLayoutStoring)? = nil) {
        let service = sync ?? KVSDeckSyncService()
        self.sync = service
        requester = service as? any CompanionRequesting
        let resolvedLayoutStore = layoutStore ?? UserDefaultsCompanionDeckLayoutStore()
        self.layoutStore = resolvedLayoutStore
        deviceLayout = resolvedLayoutStore.load()
    }

    func start() {
        sync.onChange = { [weak self] snapshot in
            guard let self else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                self.snapshot = snapshot
                self.seedDeviceLayoutIfNeeded()
            }
        }
        requester?.onResponse = { [weak self] response in
            self?.receive(response)
        }
        sync.start()
        snapshot = sync.latest
        seedDeviceLayoutIfNeeded()

        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
    }

    var agents: [SnapshotAgent] { snapshot?.content.agents ?? [] }
    var usage: [SnapshotUsage] { snapshot?.content.usage ?? [] }
    var tileAssignments: [SnapshotTileAssignment] {
        let macSlotCount = snapshot?.content.layout.map { $0.columns * $0.rows } ?? 8
        let slotCount = visibleSlotCount > 0 ? visibleSlotCount : max(macSlotCount, 1)
        let source = deviceLayout?.assignments
            ?? snapshot?.content.layout?.assignments
            ?? legacyAssignments
        var result = source
        if result.count < slotCount {
            result.append(contentsOf: repeatElement(.spacer, count: slotCount - result.count))
        }
        if result.count > slotCount { result = Array(result.prefix(slotCount)) }
        return result
    }

    func configureSlotCount(_ count: Int) {
        let count = max(count, 1)
        guard visibleSlotCount != count else {
            seedDeviceLayoutIfNeeded()
            return
        }
        visibleSlotCount = count
        seedDeviceLayoutIfNeeded()
        guard var layout = deviceLayout, layout.assignments.count < count else { return }
        layout.assignments.append(contentsOf: repeatElement(
            .spacer,
            count: count - layout.assignments.count
        ))
        persist(layout)
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
        seedDeviceLayoutIfNeeded()
        var layout = deviceLayout ?? CompanionDeckLayout(assignments: tileAssignments)
        if layout.assignments.count <= slot {
            layout.assignments.append(contentsOf: repeatElement(
                .spacer,
                count: slot + 1 - layout.assignments.count
            ))
        }
        layout.assignments[slot] = assignment
        persist(layout)
    }

    private func seedDeviceLayoutIfNeeded() {
        guard deviceLayout == nil, visibleSlotCount > 0, snapshot != nil else { return }
        var assignments = snapshot?.content.layout?.assignments ?? legacyAssignments
        if assignments.count < visibleSlotCount {
            assignments.append(contentsOf: repeatElement(
                .spacer,
                count: visibleSlotCount - assignments.count
            ))
        }
        persist(CompanionDeckLayout(assignments: assignments))
    }

    private func persist(_ layout: CompanionDeckLayout) {
        deviceLayout = layout
        layoutStore.save(layout)
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
            isLoadingHistory = false
            historyError = message
        }
    }

    private func applyAcknowledgement(for request: PendingRequest) {
        switch request {
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
