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
    ]

    private let attentionSince = Date()
    private var acknowledged: [String: Date]
    private var workingSince: [String: Date] = [:]
    private var attentionKeys: [String: [String]] = [:]
    private var loop: Task<Void, Never>?

    private static let ackDefaultsKey = "CollectorAcknowledged"

    init(model: DeckModel) {
        self.model = model
        let stored = UserDefaults.standard.dictionary(forKey: Self.ackDefaultsKey) as? [String: Double] ?? [:]
        acknowledged = stored.mapValues { Date(timeIntervalSince1970: $0) }
        model.onAcknowledge = { [weak self] providerID in
            self?.acknowledge(providerID: providerID)
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
        apply(reports)
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

            agents.append(Agent(
                id: id,
                name: collector.displayName,
                status: status,
                sessions: open.count,
                startedAt: workingSince[id]
            ))
            usage.append(Self.usageTile(providerID: id, name: collector.displayName, report: report))
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            model.apply(agents: agents, usage: usage)
        }
    }

    // MARK: - Usage mapping

    private static func usageTile(providerID: String, name: String, report: ProviderReport) -> ProviderUsage {
        let (tint, tile): (Color, Color) = switch providerID {
        case "claude": (DeckColor.orange, DeckColor.brownTile)
        case "codex": (DeckColor.cyan, DeckColor.blueTile)
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
}
