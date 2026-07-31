//
//  CollectorHub.swift
//  AgInOl
//
//  Polls the collectors every 3 s off the main actor and maps their
//  reports into the DeckModel. This is the single choke point future
//  sinks (CloudKit publisher, LAN server) will also hang off.
//

import SwiftUI

@MainActor
final class CollectorHub {
    private let model: DeckModel
    private let collectors: [any AgentCollector] = [
        ClaudeCollector(),
        CodexCollector(),
        OpenCodeCollector(),
        KimiCodeCollector(),
    ]

    private let attentionSince = Date()
    private var acknowledged: [String: Date]
    private var workingSince: [String: Date] = [:]
    private var attentionKeys: [String: [String]] = [:]
    private var observedHistoryKeys: Set<String> = []
    private var loop: Task<Void, Never>?
    /// Outbound mirror. Held behind the protocol so the iCloud KVS
    /// transport can be swapped for a faster one without touching the
    /// poll cycle.
    private let sync: any DeckSyncPublishing

    private static let ackDefaultsKey = "CollectorAcknowledged"

    /// `sync` defaults to the iCloud KVS transport; default arguments are
    /// evaluated off the actor, so it is built here rather than inline.
    init(model: DeckModel, sync: (any DeckSyncPublishing)? = nil) {
        self.model = model
        self.sync = sync ?? KVSDeckSyncService()
        let stored = UserDefaults.standard.dictionary(forKey: Self.ackDefaultsKey) as? [String: Double] ?? [:]
        acknowledged = stored.mapValues { Date(timeIntervalSince1970: $0) }
        model.onAcknowledge = { [weak self] providerID in
            self?.acknowledge(providerID: providerID)
        }
        if let requestServer = self.sync as? any CompanionRequestServing {
            requestServer.onRequest = { [weak self] request in
                self?.handleCompanionRequest(request)
            }
            requestServer.startServingRequests()
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// User clicked a NEED YOU tile: silence that provider's current
    /// attention sessions and refresh immediately.
    func acknowledge(providerID: String) {
        let now = Date()
        for key in attentionKeys[providerID] ?? [] {
            acknowledged[key] = now
        }
        persistAcks()
        Task { await tick() }
    }

    private func persistAcks() {
        // Only keep recent acks so the defaults dictionary can't grow forever.
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        acknowledged = acknowledged.filter { $0.value > cutoff }
        UserDefaults.standard.set(
            acknowledged.mapValues { $0.timeIntervalSince1970 },
            forKey: Self.ackDefaultsKey
        )
    }

    // MARK: - Poll cycle

    private func tick() async {
        let context = CollectorContext(
            attentionSince: attentionSince,
            acknowledged: acknowledged,
            allowNetwork: AppSettings.shared.onlineAccess
        )
        var reports: [(collector: any AgentCollector, report: ProviderReport)] = []
        for collector in collectors {
            reports.append((collector, await collector.collect(context: context)))
        }
        await recordSessionStarts(from: reports)
        apply(reports)
    }

    private func recordSessionStarts(
        from reports: [(collector: any AgentCollector, report: ProviderReport)]
    ) async {
        for (collector, report) in reports where !report.startCandidates.isEmpty {
            let fresh = report.startCandidates.filter {
                !observedHistoryKeys.contains("\(collector.providerID):\($0.sessionID)")
            }
            guard !fresh.isEmpty else { continue }
            do {
                try await ActivityHistoryStore.shared.append(
                    fresh,
                    providerID: collector.providerID,
                    providerName: collector.displayName
                )
                observedHistoryKeys.formUnion(
                    fresh.map { "\(collector.providerID):\($0.sessionID)" }
                )
            } catch {
                NSLog("AgInOl activity history: %@", error.localizedDescription)
            }
        }
    }

    private func apply(_ reports: [(collector: any AgentCollector, report: ProviderReport)]) {
        var agents: [Agent] = []
        var usage: [ProviderUsage] = []
        attentionKeys = [:]

        for (collector, report) in reports {
            let id = collector.providerID
            let open = report.sessions.filter(\.isOpen)
            let working = report.sessions.contains { $0.state == .working }
            let attention = report.sessions.filter { $0.state == .attention }
            attentionKeys[id] = attention.map(\.key)

            let status: AgentStatus = !report.installed ? .offline
                : working ? .working
                : !attention.isEmpty ? .needsYou
                : .idle

            if status == .working {
                if workingSince[id] == nil { workingSince[id] = Date() }
            } else {
                workingSince[id] = nil
            }

            // Models most-recently-active first; open sessions win, with the
            // latest closed session as fallback so idle providers still show one.
            let byRecency = report.sessions.sorted { $0.activityAt > $1.activityAt }
            var models: [String] = []
            for session in byRecency where session.isOpen {
                if let model = session.model, !models.contains(model) { models.append(model) }
            }
            if models.isEmpty, let model = byRecency.first(where: { $0.model != nil })?.model {
                models.append(model)
            }

            agents.append(Agent(
                id: id,
                name: collector.displayName,
                status: status,
                sessions: open.count,
                startedAt: workingSince[id],
                models: models.prefix(3).map(ModelName.short),
                openSessions: Self.sessionList(open)
            ))
            usage.append(Self.usageTile(providerID: id, name: collector.displayName, report: report))
            if let sessionTile = Self.sessionUsageTile(providerID: id, name: collector.displayName, report: report) {
                usage.append(sessionTile)
            }
            if id == "claude", let spend = report.spend, spend.tokens7d > 0 {
                var tile = ProviderUsage(
                    id: "claude-spend", name: collector.displayName,
                    tint: DeckColor.orange, tileBackground: DeckColor.brownTile,
                    kind: .tokens(count: spend.tokens7d, cost: spend.cost7d, window: "7d")
                )
                tile.secondaryText = String(format: "24h $%.2f", spend.cost24h)
                usage.append(tile)
            }
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            model.apply(agents: agents, usage: usage)
        }

        // Mirror outward on every cycle; the transport decides what is
        // actually worth sending.
        publishDeck()
    }

    private func publishDeck() {
        let settings = AppSettings.shared
        sync.publish(DeckSnapshot.make(
            agents: model.agents,
            usage: model.usage,
            assignments: model.keyAssignments,
            columns: settings.gridColumns,
            rows: settings.gridRows,
            layoutRevision: model.layoutRevision
        ))
    }

    // MARK: - Companion requests

    private func handleCompanionRequest(_ request: CompanionRequest) {
        switch request.action {
        case .setTile(let slot, let assignment):
            guard slot >= 0, slot < AppSettings.shared.keyCount,
                  let macAssignment = KeyAssignment(rawValue: assignment.rawValue) else {
                respond(.failed(message: "Invalid tile assignment"), to: request)
                return
            }
            model.assign(macAssignment, toSlot: slot)
            publishDeck()
            respond(.acknowledged, to: request)

        case .historyPage(let requestedLimit, let cursor, let includingHidden):
            Task { [weak self] in
                guard let self else { return }
                do {
                    let limit = min(max(requestedLimit, 1), 20)
                    let page = try await ActivityHistoryStore.shared.entries(
                        limit: limit + 1,
                        before: cursor,
                        includingHidden: includingHidden
                    )
                    let entries = Array(page.prefix(limit))
                    let snapshots = entries.map { entry in
                        let preview = CollectorFiles.contentSnippet(entry.snippet, limit: 240) ?? entry.snippet
                        return SnapshotHistoryEntry(
                            eventID: entry.eventID,
                            occurredAt: entry.occurredAt,
                            providerID: entry.providerID,
                            providerName: entry.providerName,
                            preview: preview,
                            hasFullContent: preview != entry.snippet,
                            isHidden: entry.isHidden
                        )
                    }
                    let nextCursor = page.count > limit ? entries.last.map {
                        SnapshotHistoryCursor(occurredAt: $0.occurredAt, sequence: $0.sequence)
                    } : nil
                    respond(.historyPage(entries: snapshots, nextCursor: nextCursor), to: request)
                } catch {
                    respond(.failed(message: error.localizedDescription), to: request)
                }
            }

        case .historyDetail(let eventID):
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let entry = try await ActivityHistoryStore.shared.entry(eventID: eventID) else {
                        respond(.failed(message: "History entry not found"), to: request)
                        return
                    }
                    respond(.historyDetail(eventID: eventID, content: entry.snippet), to: request)
                } catch {
                    respond(.failed(message: error.localizedDescription), to: request)
                }
            }

        case .setHistoryHidden(let eventID, let hidden):
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await ActivityHistoryStore.shared.setHidden(hidden, eventID: eventID)
                    respond(.acknowledged, to: request)
                } catch {
                    respond(.failed(message: error.localizedDescription), to: request)
                }
            }
        }
    }

    private func respond(_ payload: CompanionResponse.Payload, to request: CompanionRequest) {
        guard let requestServer = sync as? any CompanionRequestServing else { return }
        requestServer.respond(CompanionResponse(
            requestID: request.id,
            deviceID: request.deviceID,
            sentAt: Date(),
            payload: payload
        ))
    }

    // MARK: - Session mapping

    /// The provider's open sessions as key rows: waiting first, then
    /// working, then idle, each newest-first. Bounded because a provider
    /// like Kimi keeps every session it has ever recorded open.
    private static func sessionList(_ sessions: [SessionSnapshot]) -> [AgentSession] {
        func rank(_ state: SessionState) -> Int {
            switch state {
            case .attention: 0
            case .working:   1
            case .idle:      2
            }
        }
        func mapped(_ state: SessionState) -> AgentSession.State {
            switch state {
            case .working:   .working
            case .attention: .attention
            case .idle:      .idle
            }
        }
        return sessions
            .sorted {
                rank($0.state) != rank($1.state)
                    ? rank($0.state) < rank($1.state)
                    : ($0.completionAt ?? $0.activityAt) > ($1.completionAt ?? $1.activityAt)
            }
            .prefix(12)
            .map { session in
                AgentSession(
                    id: session.key,
                    title: session.title ?? String(localized: "session \(session.id.prefix(6))"),
                    state: mapped(session.state),
                    // Attention rows count how long the reply has been
                    // owed; the others show time since last activity.
                    since: session.completionAt ?? session.activityAt
                )
            }
    }

    // MARK: - Usage mapping

    private static func usageTile(providerID: String, name: String, report: ProviderReport) -> ProviderUsage {
        let (tint, tile): (Color, Color) = switch providerID {
        case "claude": (DeckColor.orange, DeckColor.brownTile)
        case "codex": (DeckColor.cyan, DeckColor.blueTile)
        case "kimi": (DeckColor.magenta, DeckColor.magentaTile)
        default: (DeckColor.purple, DeckColor.purpleTile)
        }

        func unavailable(_ caption: String) -> ProviderUsage {
            ProviderUsage(id: providerID + "-usage", name: name,
                          tint: DeckColor.gray, tileBackground: DeckColor.grayTile,
                          kind: .unavailable(caption: caption))
        }

        guard report.installed else { return unavailable("not installed") }
        let windows = report.usage.windows

        switch providerID {
        case "claude":
            guard let weekly = windows.first(where: { $0.label == "7d" }),
                  let percent = weekly.percent else {
                let caption = report.usage.error == "online access disabled" ? "online off"
                    : report.usage.error == nil ? "loading" : "no data"
                return unavailable(caption)
            }
            var tileModel = ProviderUsage(id: "claude-usage", name: name, tint: tint,
                                          tileBackground: tile,
                                          kind: .percent(fraction: percent, window: "7d"))
            if let session = windows.first(where: { $0.label == "5h" }), let p = session.percent {
                tileModel.secondaryText = "5h \(Int((p * 100).rounded()))%"
            }
            tileModel.resetsAt = weekly.resetsAt
            return tileModel

        case "codex":
            // Prefer the weekly (longest) window for the tile, like the
            // reference design; the shorter session window becomes the
            // info-bar detail.
            let sorted = windows.sorted { ($0.periodSeconds ?? 0) > ($1.periodSeconds ?? 0) }
            guard let main = sorted.first, let percent = main.percent else {
                return unavailable(report.usage.error == nil ? "loading" : "no data")
            }
            var tileModel = ProviderUsage(id: "codex-usage", name: name, tint: tint,
                                          tileBackground: tile,
                                          kind: .percent(fraction: percent, window: main.label))
            if sorted.count > 1, let p = sorted[1].percent {
                tileModel.secondaryText = "\(sorted[1].label) \(Int((p * 100).rounded()))%"
            }
            tileModel.resetsAt = main.resetsAt
            return tileModel

        case "kimi":
            guard let week = windows.first(where: { $0.label == "7d" }), let tokens = week.tokens else {
                return unavailable(report.usage.error == nil ? "loading" : "no data")
            }
            var tileModel = ProviderUsage(id: "kimi-usage", name: name, tint: tint,
                                          tileBackground: tile,
                                          kind: .tokens(count: tokens, cost: 0, window: "7d"))
            if let day = windows.first(where: { $0.label == "24h" }), let t = day.tokens {
                tileModel.secondaryText = String(format: "24h %.1fK", t / 1000)
            }
            return tileModel

        default:
            guard let week = windows.first(where: { $0.label == "7d" }), let tokens = week.tokens else {
                return unavailable(report.usage.error == nil ? "loading" : "no data")
            }
            return ProviderUsage(id: "opencode-usage", name: name, tint: tint,
                                 tileBackground: tile,
                                 kind: .tokens(count: tokens,
                                               cost: report.usage.costUSD ?? 0,
                                               window: "7d"))
        }
    }

    private static func sessionUsageTile(providerID: String, name: String, report: ProviderReport) -> ProviderUsage? {
        guard report.installed else { return nil }
        let windows = report.usage.windows

        switch providerID {
        case "claude":
            guard let session = windows.first(where: { $0.label == "5h" }),
                  let percent = session.percent else { return nil }
            var tile = ProviderUsage(id: "claude-session", name: name,
                                     tint: DeckColor.orange, tileBackground: DeckColor.brownTile,
                                     kind: .percent(fraction: percent, window: "5h"))
            tile.resetsAt = session.resetsAt
            return tile

        case "codex":
            // Codex's short (≈5h) window only — newer CLIs log just the
            // weekly limit ("primary" is 10080 min, "secondary" null), and
            // the weekly number must never pose as the session amount.
            let session = windows
                .filter { ($0.periodSeconds ?? 0) > 0 && $0.periodSeconds! <= 24 * 3600 }
                .min { ($0.periodSeconds ?? 0) < ($1.periodSeconds ?? 0) }
            guard let session, let percent = session.percent else { return nil }
            var tile = ProviderUsage(id: "codex-session", name: name,
                                     tint: DeckColor.cyan, tileBackground: DeckColor.blueTile,
                                     kind: .percent(fraction: percent, window: session.label))
            tile.resetsAt = session.resetsAt
            return tile

        default:
            return nil
        }
    }
}
