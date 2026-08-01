//
//  ContentView.swift
//  AgInOl Companion
//
//  Full-screen Companion deck. Agent data comes from the Mac; the tile
//  layout is configured and persisted independently on each iOS device.
//

import SwiftUI

struct ContentView: View {
    @State private var mirror = DeckMirror()
    @State private var detail: CompanionDetail?
    @State private var editingSlot: Int?
    @State private var showHistory = false
    @State private var reviewCoordinator = AppReviewCoordinator()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DeckColor.screen.ignoresSafeArea()
                if mirror.snapshot == nil {
                    EmptyState()
                } else {
                    let grid = CompanionGridMetrics(size: proxy.size)
                    CompanionDeckGrid(
                        mirror: mirror,
                        size: proxy.size,
                        grid: grid,
                        onTap: open,
                        onLongPress: { editingSlot = $0 }
                    )
                    .padding(8)
                    .onAppear { mirror.configureSlotCount(grid.slotCount) }
                    .onChange(of: grid.slotCount) { _, count in
                        mirror.configureSlotCount(count)
                    }
                }
            }
        }
#if DEBUG
        .onTapGesture(count: 4) {
            reviewCoordinator.requestReviewForDebug()
        }
#endif
        .overlay(alignment: .bottomTrailing) { freshnessPill.padding(12) }
        .onAppear { mirror.start() }
        .sheet(item: $detail) { detail in
            CompanionDetailView(detail: detail, agents: mirror.agents, now: mirror.now)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .onAppear { reviewCoordinator.detailDidAppear() }
        }
        .sheet(isPresented: Binding(
            get: { editingSlot != nil },
            set: { if !$0 { editingSlot = nil } }
        )) {
            if let slot = editingSlot {
                TilePickerView(
                    slot: slot,
                    current: mirror.tileAssignments[slot],
                    onSelect: { assignment in
                        mirror.assign(assignment, toSlot: slot)
                        editingSlot = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showHistory) {
            CompanionHistoryView(mirror: mirror)
        }
    }

    private func open(_ assignment: SnapshotTileAssignment) {
        switch assignment {
        case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus:
            if let id = assignment.providerID,
               let agent = mirror.agents.first(where: { $0.id == id }) {
                detail = .agent(agent)
            }
        case .allAgents, .info:
            detail = .summary
        case .history:
            mirror.loadFirstHistoryPage()
            showHistory = true
        case .claudeUsed, .claudeLeft, .claudeSpend,
             .claudeSessionUsed, .claudeSessionLeft,
             .codexUsed, .codexLeft, .codexSessionUsed, .codexSessionLeft,
             .opencodeUsage, .kimiUsage:
            if let usage = mirror.usage.first(where: { $0.id == assignment.usageID }) {
                detail = .usage(usage)
            }
        case .clock, .spacer:
            break
        }
    }

    /// Compact overlay: every safe-area point underneath remains tile space.
    private var freshnessPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mirror.isStale ? DeckColor.amber : DeckColor.green)
                .frame(width: 6, height: 6)
            Text(mirror.ageCaption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }
}

private struct CompanionDeckGrid: View {
    let mirror: DeckMirror
    let size: CGSize
    let grid: CompanionGridMetrics
    let onTap: (SnapshotTileAssignment) -> Void
    let onLongPress: (Int) -> Void

    private let spacing: CGFloat = 8

    var body: some View {
        let assignments = Array(mirror.tileAssignments.prefix(grid.slotCount))
        let height = max(
            44,
            (size.height - 16 - CGFloat(grid.rows - 1) * spacing) / CGFloat(grid.rows)
        )
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: grid.columns)

        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(Array(assignments.enumerated()), id: \.offset) { slot, assignment in
                CompanionTileButton(
                    onTap: { onTap(assignment) },
                    onLongPress: { onLongPress(slot) }
                ) {
                    AssignmentTile(assignment: assignment, mirror: mirror)
                        .frame(height: height)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct CompanionTileButton<Content: View>: View {
    let onTap: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder let content: Content

    @GestureState private var isPressed = false
    @State private var pressBeganAt: Date?

    var body: some View {
        content
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .highPriorityGesture(interactionGesture)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: Text("Change tile")) { onLongPress() }
            .accessibilityHint("Long press to change this tile")
    }

    private var interactionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, state, _ in state = true }
            .onChanged { value in
                if pressBeganAt == nil { pressBeganAt = value.time }
            }
            .onEnded { value in
                let duration = pressBeganAt.map { value.time.timeIntervalSince($0) } ?? 0
                pressBeganAt = nil
                switch CompanionPressClassifier.classify(
                    duration: duration,
                    translation: value.translation
                ) {
                case .longPress:
                    onLongPress()
                case .tap:
                    onTap()
                case .cancelled:
                    break
                }
            }
    }
}

enum CompanionPressKind: Equatable {
    case tap
    case longPress
    case cancelled
}

enum CompanionPressClassifier {
    static func classify(duration: TimeInterval, translation: CGSize) -> CompanionPressKind {
        let travel = hypot(translation.width, translation.height)
        guard travel <= 24 else { return .cancelled }
        return duration >= 0.5 ? .longPress : .tap
    }
}

struct CompanionGridMetrics: Equatable {
    let columns: Int
    let rows: Int

    var slotCount: Int { columns * rows }

    init(size: CGSize) {
        let spacing: CGFloat = 8
        let inset: CGFloat = 16
        // Large, nearly square Stream-Deck-style keys. Bigger displays gain
        // rows and columns instead of stretching the same eight assignments.
        let preferredEdge: CGFloat = 148
        let width = max(size.width - inset, preferredEdge)
        let height = max(size.height - inset, preferredEdge)
        if width <= height {
            let fittedRows = Int((height + spacing) / (preferredEdge + spacing))
            rows = min(6, max(1, fittedRows))
            columns = min(6, max(1, Int((CGFloat(rows) * width / height).rounded())))
        } else {
            let fittedColumns = Int((width + spacing) / (preferredEdge + spacing))
            columns = min(6, max(1, fittedColumns))
            rows = min(6, max(1, Int((CGFloat(columns) * height / width).rounded())))
        }
    }
}

private struct AssignmentTile: View {
    let assignment: SnapshotTileAssignment
    let mirror: DeckMirror

    @ViewBuilder var body: some View {
        switch assignment {
        case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus:
            if let providerID = assignment.providerID,
               let agent = mirror.agents.first(where: { $0.id == providerID }) {
                AgentTile(agent: agent, now: mirror.now)
            } else {
                EmptyDataTile(title: assignment.displayName)
            }
        case .allAgents:
            SummaryTile(agents: mirror.agents)
        case .history:
            Tile(background: DeckColor.indigoTile) {
                TileHeader(name: String(localized: "HISTORY"), dot: DeckColor.cyan)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(DeckColor.cyan)
                Text("OPEN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case .clock:
            Tile(background: DeckColor.indigoTile) {
                TileHeader(name: String(localized: "CLOCK"), dot: DeckColor.purple)
                Text(mirror.now.formatted(date: .omitted, time: .shortened))
                    .font(.title2.weight(.heavy).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                Text(mirror.now.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .info:
            Tile(background: DeckColor.indigoTile) {
                TileHeader(name: String(localized: "INFO"), dot: DeckColor.cyan)
                Text("\(mirror.agents.openSessions)")
                    .font(.title.weight(.heavy).monospacedDigit())
                    .foregroundStyle(DeckColor.cyan)
                Text("OPEN SESSIONS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .spacer:
            Color.clear
                .contentShape(Rectangle())
                .accessibilityLabel("Empty tile")
        default:
            if let usage = mirror.usage.first(where: { $0.id == assignment.usageID }) {
                UsageAssignmentTile(usage: usage, showRemaining: assignment.showsRemaining)
            } else {
                EmptyDataTile(title: assignment.displayName)
            }
        }
    }
}

private struct UsageAssignmentTile: View {
    let usage: SnapshotUsage
    let showRemaining: Bool

    private var bigValue: String {
        guard showRemaining, case .percent(let fraction, _) = usage.kind else {
            return usage.bigValue
        }
        return "\(Int(((1 - fraction) * 100).rounded()))%"
    }

    var body: some View {
        Tile(background: usage.palette.tileBackground) {
            TileHeader(name: usage.name, dot: usage.palette.tint)
            Text(bigValue)
                .font(.title.weight(.heavy).monospacedDigit())
                .foregroundStyle(usage.palette.tint)
            if let fraction = usage.barFraction {
                ProgressView(value: showRemaining ? 1 - fraction : fraction)
                    .tint(usage.palette.tint)
                    .scaleEffect(y: 0.6, anchor: .center)
            }
            Text(showRemaining ? String(localized: "remaining") : usage.caption)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }
}

private struct EmptyDataTile: View {
    let title: String

    var body: some View {
        Tile(background: DeckColor.grayTile) {
            TileHeader(name: title, dot: DeckColor.gray)
            Spacer(minLength: 0)
            Text("—")
                .font(.title.weight(.heavy))
                .foregroundStyle(DeckColor.gray)
            Text("NO DATA")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

private extension SnapshotTileAssignment {
    var displayName: String {
        switch self {
        case .claudeStatus: "Claude · Status"
        case .codexStatus: "Codex · Status"
        case .opencodeStatus: "OpenCode · Status"
        case .kimiStatus: "Kimi · Status"
        case .allAgents: String(localized: "All Agents")
        case .history: String(localized: "Activity History")
        case .claudeUsed: "Claude · % used"
        case .claudeLeft: "Claude · % left"
        case .claudeSpend: "Claude · tokens & cost"
        case .claudeSessionUsed: "Claude · session used"
        case .claudeSessionLeft: "Claude · session left"
        case .codexUsed: "Codex · % used"
        case .codexLeft: "Codex · % left"
        case .codexSessionUsed: "Codex · session used"
        case .codexSessionLeft: "Codex · session left"
        case .opencodeUsage: "OpenCode · tokens"
        case .kimiUsage: "Kimi · tokens"
        case .info: String(localized: "Info")
        case .clock: String(localized: "Clock")
        case .spacer: "LEER"
        }
    }

    var providerID: String? {
        switch self {
        case .claudeStatus, .claudeUsed, .claudeLeft, .claudeSpend,
             .claudeSessionUsed, .claudeSessionLeft: "claude"
        case .codexStatus, .codexUsed, .codexLeft,
             .codexSessionUsed, .codexSessionLeft: "codex"
        case .opencodeStatus, .opencodeUsage: "opencode"
        case .kimiStatus, .kimiUsage: "kimi"
        default: nil
        }
    }

    var usageID: String? {
        switch self {
        case .claudeUsed, .claudeLeft: "claude-usage"
        case .claudeSessionUsed, .claudeSessionLeft: "claude-session"
        case .claudeSpend: "claude-spend"
        case .codexUsed, .codexLeft: "codex-usage"
        case .codexSessionUsed, .codexSessionLeft: "codex-session"
        case .opencodeUsage: "opencode-usage"
        case .kimiUsage: "kimi-usage"
        default: nil
        }
    }

    var showsRemaining: Bool {
        switch self {
        case .claudeLeft, .claudeSessionLeft, .codexLeft, .codexSessionLeft: true
        default: false
        }
    }
}

private struct TilePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let slot: Int
    let current: SnapshotTileAssignment
    let onSelect: (SnapshotTileAssignment) -> Void

    private let sections: [(String, [SnapshotTileAssignment])] = [
        ("General", [.allAgents, .history, .info, .clock, .spacer]),
        ("Claude", [.claudeStatus, .claudeUsed, .claudeLeft,
                    .claudeSessionUsed, .claudeSessionLeft, .claudeSpend]),
        ("Codex", [.codexStatus, .codexUsed, .codexLeft,
                   .codexSessionUsed, .codexSessionLeft]),
        ("OpenCode", [.opencodeStatus, .opencodeUsage]),
        ("Kimi", [.kimiStatus, .kimiUsage]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { title, assignments in
                    Section(title) {
                        ForEach(assignments) { assignment in
                            Button {
                                onSelect(assignment)
                            } label: {
                                HStack {
                                    Text(assignment.displayName)
                                    Spacer()
                                    if assignment == current {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(DeckColor.cyan)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Tile \(slot + 1)")
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

private struct CompanionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let mirror: DeckMirror

    @State private var expandedEventID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mirror.historyEntries.isEmpty && !mirror.isLoadingHistory {
                        ContentUnavailableView(
                            "No history entries",
                            systemImage: "clock.badge.questionmark"
                        )
                        .padding(.top, 80)
                    }
                    ForEach(Array(mirror.historyEntries.enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry)
                            .onAppear {
                                if index >= mirror.historyEntries.count - 3 {
                                    mirror.loadNextHistoryPage()
                                }
                            }
                        if index < mirror.historyEntries.count - 1 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                    if mirror.isLoadingHistory {
                        ProgressView()
                            .tint(DeckColor.cyan)
                            .frame(maxWidth: .infinity)
                            .padding(22)
                    }
                    if let error = mirror.historyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DeckColor.amber)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal, 14)
            }
            .background(DeckColor.screen.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        mirror.loadFirstHistoryPage(
                            includingHidden: !mirror.includingHiddenHistory
                        )
                    } label: {
                        Image(systemName: mirror.includingHiddenHistory ? "eye" : "eye.slash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func historyRow(_ entry: SnapshotHistoryEntry) -> some View {
        let expanded = expandedEventID == entry.eventID
        let content = expanded
            ? mirror.historyContents[entry.eventID] ?? entry.preview
            : entry.preview
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(historyTint(entry.providerID))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(entry.providerName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(historyTint(entry.providerID))
                    Text(entry.occurredAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(historyTint(entry.providerID))
                    Spacer()
                    if expanded && entry.hasFullContent && mirror.historyContents[entry.eventID] == nil {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(entry.isHidden ? 0.45 : 0.84))
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedEventID = expanded ? nil : entry.eventID
                }
                if !expanded && entry.hasFullContent {
                    mirror.loadHistoryDetail(eventID: entry.eventID)
                }
            }
            Button {
                mirror.setHistoryHidden(!entry.isHidden, eventID: entry.eventID)
            } label: {
                Image(systemName: entry.isHidden ? "eye" : "eye.slash")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(7)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .opacity(entry.isHidden ? 0.65 : 1)
    }

    private func historyTint(_ providerID: String) -> Color {
        switch providerID {
        case "claude": DeckColor.orange
        case "codex": DeckColor.cyan
        case "kimi": DeckColor.magenta
        default: DeckColor.purple
        }
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
        case .summary: String(localized: "All Agents")
        case .agent(let agent): agent.name
        case .usage(let usage): String(localized: "\(usage.name) Usage")
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
        guard total > 0 else { return String(localized: "Resets now") }
        let minutes = total / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return String(localized: "Resets in \(days)d \(hours % 24)h") }
        if hours > 0 { return String(localized: "Resets in \(hours)h \(minutes % 60)m") }
        return String(localized: "Resets in \(max(minutes, 1))m")
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
        case .working: String(localized: "WORKING")
        case .attention: String(localized: "NEED YOU")
        case .idle: String(localized: "IDLE")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(background, in: .rect(cornerRadius: 14))
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macbook.and.iphone")
                .font(.largeTitle)
                .foregroundStyle(DeckColor.gray)
            Text("No Mac server connection")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            Text("Download the Mac app from")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Link("https://aiia.li/apps/aginol",
                 destination: URL(string: "https://aiia.li/apps/aginol")!)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DeckColor.cyan)
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
}
