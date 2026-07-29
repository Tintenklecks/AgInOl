//
//  ContentView.swift
//  AgInOl Companion
//
//  The companion's own grid — deliberately not a pixel copy of the Mac
//  deck. It reflows for phone and iPad instead of mimicking the fixed
//  4×2 key layout.
//

import SwiftUI

struct ContentView: View {
    @State private var mirror = DeckMirror()
    @State private var detail: CompanionDetail?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                if !mirror.agents.isEmpty {
                    Button {
                        detail = .summary
                    } label: {
                        SummaryTile(agents: mirror.agents)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows all agents")
                }
                ForEach(mirror.agents) { agent in
                    Button {
                        detail = .agent(agent)
                    } label: {
                        AgentTile(agent: agent, now: mirror.now)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows session details")
                }
                ForEach(mirror.usage) { usage in
                    Button {
                        detail = .usage(usage)
                    } label: {
                        UsageTile(usage: usage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows usage details")
                }
            }
            .padding(12)
        }
        .background(DeckColor.screen.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { freshnessBar }
        .overlay { if mirror.snapshot == nil { EmptyState() } }
        .onAppear { mirror.start() }
        .sheet(item: $detail) { detail in
            CompanionDetailView(detail: detail, agents: mirror.agents, now: mirror.now)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// KVS latency is measured in minutes on a bad day, so the age of
    /// the data is always on screen — a stale deck must never read as live.
    private var freshnessBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mirror.isStale ? DeckColor.amber : DeckColor.green)
                .frame(width: 6, height: 6)
            Text(mirror.ageCaption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

private enum CompanionDetail: Identifiable {
    case summary
    case agent(SnapshotAgent)
    case usage(SnapshotUsage)

    var id: String {
        switch self {
        case .summary: "summary"
        case .agent(let agent): "agent:\(agent.id)"
        case .usage(let usage): "usage:\(usage.id)"
        }
    }
}

private struct CompanionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let detail: CompanionDetail
    let agents: [SnapshotAgent]
    let now: Date

    private var title: String {
        switch detail {
        case .summary: "All Agents"
        case .agent(let agent): agent.name
        case .usage(let usage): "\(usage.name) Usage"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch detail {
                    case .summary:
                        SummaryDetails(agents: agents, now: now)
                    case .agent(let agent):
                        AgentDetails(agent: agent, now: now)
                    case .usage(let usage):
                        UsageDetails(usage: usage, now: now)
                    }
                }
                .padding(16)
            }
            .background(DeckColor.screen.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SummaryDetails: View {
    let agents: [SnapshotAgent]
    let now: Date

    private var workingCount: Int { agents.count { $0.status == .working } }

    var body: some View {
        VStack(spacing: 12) {
            DetailCard {
                HStack {
                    DetailMetric(value: agents.openSessions, label: String(localized: "OPEN"), tint: DeckColor.cyan)
                    Spacer()
                    DetailMetric(value: workingCount, label: String(localized: "WORKING"), tint: DeckColor.green)
                    Spacer()
                    DetailMetric(value: agents.attentionCount, label: String(localized: "NEED YOU"), tint: DeckColor.amber)
                }
            }

            ForEach(agents) { agent in
                DetailCard {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(agent.status.tint)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(agent.name)
                                    .font(.headline)
                                Spacer()
                                Text(agent.status.label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(agent.status.tint)
                            }
                            Text(agent.sessionCaption)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let session = agent.openSessions?.first {
                                Text(session.title)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(2)
                            } else if let startedAt = agent.startedAt {
                                Text(DeckMirror.elapsed(since: startedAt, now: now))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AgentDetails: View {
    let agent: SnapshotAgent
    let now: Date

    private var sessions: [SnapshotAgentSession] { agent.openSessions ?? [] }
    private var hiddenSessionCount: Int { max(agent.sessions - sessions.count, 0) }

    var body: some View {
        VStack(spacing: 12) {
            DetailCard {
                HStack(alignment: .firstTextBaseline) {
                    Label(agent.status.label, systemImage: "circle.fill")
                        .font(.headline)
                        .foregroundStyle(agent.status.tint)
                    Spacer()
                    Text(agent.sessionCaption)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !agent.models.isEmpty {
                    Text(agent.models.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if let startedAt = agent.startedAt {
                    Text("Active for \(DeckMirror.elapsed(since: startedAt, now: now))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            DetailCard {
                Text("SESSIONS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                if sessions.isEmpty {
                    Text(agent.sessions == 0
                         ? String(localized: "No open sessions right now.")
                         : String(localized: "Session details will appear after the next Mac sync."))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(session.state.tint)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(session.state.label)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(session.state.tint)
                            }
                            Spacer(minLength: 8)
                            if let since = session.since {
                                Text(DeckMirror.elapsed(since: since, now: now))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if hiddenSessionCount > 0 {
                        Text("+\(hiddenSessionCount) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct UsageDetails: View {
    let usage: SnapshotUsage
    let now: Date

    var body: some View {
        VStack(spacing: 12) {
            DetailCard {
                HStack(alignment: .firstTextBaseline) {
                    Text(usage.name)
                        .font(.headline)
                    Spacer()
                    Text(usage.bigValue)
                        .font(.largeTitle.weight(.heavy).monospacedDigit())
                        .foregroundStyle(usage.palette.tint)
                }
                if let fraction = usage.barFraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(usage.palette.tint)
                }
                Text(usage.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if usage.secondaryText != nil || usage.resetsAt != nil {
                DetailCard {
                    Text("DETAILS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    if let secondary = usage.secondaryText {
                        Text(secondary)
                            .font(.body)
                    }
                    if let resetsAt = usage.resetsAt {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.resetCaption(resetsAt, now: now))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(usage.palette.tint)
                            Text(resetsAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private static func resetCaption(_ resetsAt: Date, now: Date) -> String {
        let total = max(0, Int(resetsAt.timeIntervalSince(now)))
        guard total > 0 else { return "Resets now" }
        let minutes = total / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "Resets in \(days)d \(hours % 24)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(max(minutes, 1))m"
    }
}

private struct DetailMetric: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title.weight(.heavy).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DeckColor.grayTile, in: .rect(cornerRadius: 14))
    }
}

private extension SnapshotAgentSession.State {
    var tint: Color {
        switch self {
        case .working: DeckColor.green
        case .attention: DeckColor.amber
        case .idle: DeckColor.gray
        }
    }

    var label: String {
        switch self {
        case .working: "WORKING"
        case .attention: "NEED YOU"
        case .idle: "IDLE"
        }
    }
}

private struct AgentTile: View {
    let agent: SnapshotAgent
    let now: Date

    var body: some View {
        Tile(background: agent.status.tileBackground) {
            TileHeader(name: agent.name, dot: agent.status.tint)

            Text(agent.status.label)
                .font(.title3.weight(.heavy))
                .foregroundStyle(agent.status.tint)

            if !agent.models.isEmpty {
                Text(agent.models.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            // The deck pairs the status with a session count; keep the
            // same wording so the two screens agree at a glance.
            HStack(spacing: 6) {
                Text(agent.sessionCaption)
                if let startedAt = agent.startedAt {
                    Text(DeckMirror.elapsed(since: startedAt, now: now))
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// ALL AGENTS overview — derived on this side rather than shipped, since
/// it is a pure function of the agents already in the snapshot.
private struct SummaryTile: View {
    let agents: [SnapshotAgent]

    var body: some View {
        Tile(background: DeckColor.oliveTile) {
            TileHeader(name: String(localized: "ALL AGENTS"), dot: DeckColor.amber)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                stat(agents.openSessions, String(localized: "OPEN"), DeckColor.amber)
                stat(agents.attentionCount, String(localized: "NEED YOU"), DeckColor.green)
            }

            Text("\(agents.count) providers")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func stat(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.title.weight(.heavy).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct TileHeader: View {
    let name: String
    let dot: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }
}

private struct UsageTile: View {
    let usage: SnapshotUsage

    var body: some View {
        Tile(background: usage.palette.tileBackground) {
            TileHeader(name: usage.name, dot: usage.palette.tint)

            Text(usage.bigValue)
                .font(.title.weight(.heavy).monospacedDigit())
                .foregroundStyle(usage.palette.tint)

            if let fraction = usage.barFraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(usage.palette.tint)
                    .scaleEffect(y: 0.6, anchor: .center)
            }

            // `caption` names the window the big number belongs to, so it
            // must lead — showing secondaryText alone made a 7d figure
            // read as a 5h one. The extra detail goes underneath.
            Text(usage.caption)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            if let secondary = usage.secondaryText {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }
}

private struct Tile<Content: View>: View {
    let background: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(background, in: .rect(cornerRadius: 14))
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "macbook.and.iphone")
                .font(.largeTitle)
                .foregroundStyle(DeckColor.gray)
            Text("No deck yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            Text("Open AgInOl on your Mac while signed in\nto the same iCloud account.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
}
