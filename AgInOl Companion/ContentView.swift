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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                if !mirror.agents.isEmpty {
                    SummaryTile(agents: mirror.agents)
                }
                ForEach(mirror.agents) { agent in
                    AgentTile(agent: agent, now: mirror.now)
                }
                ForEach(mirror.usage) { usage in
                    UsageTile(usage: usage)
                }
            }
            .padding(12)
        }
        .background(DeckColor.screen.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { freshnessBar }
        .overlay { if mirror.snapshot == nil { EmptyState() } }
        .onAppear { mirror.start() }
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
            TileHeader(name: "ALL AGENTS", dot: DeckColor.amber)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                stat(agents.openSessions, "OPEN", DeckColor.amber)
                stat(agents.attentionCount, "NEED YOU", DeckColor.green)
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
