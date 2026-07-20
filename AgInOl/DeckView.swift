//
//  DeckView.swift
//  AgInOl
//
//  The AgInOl deck: a hardware-style panel with a configurable grid of
//  colored key tiles, an info-bar screen, and two round touch points.
//

import SwiftUI

private enum DeckMetrics {
    static let keySize: CGFloat = 96
    static let keyCorner: CGFloat = 18
    static let keySpacing: CGFloat = 16
    static let bezelCorner: CGFloat = 36
    static let bezelPaddingH: CGFloat = 34
    static let bezelPaddingTop: CGFloat = 32
    static let bezelPaddingBottom: CGFloat = 18
    static let infoBarHeight: CGFloat = 62
    static let touchPointSize: CGFloat = 44
}

struct DeckView: View {
    @Bindable var model: DeckModel
    var controller: PanelController
    @Bindable var settings: AppSettings = .shared
    @State private var show = false
    @State private var showSettings = false
    @State private var editingSlot: Int?
    @State private var pickerProviderID: String?
    @State private var showOnlinePrompt = false
    @State private var showAgentList = false

    var body: some View {
        VStack(spacing: 0) {
            keyGrid
            // Below 3 columns the info bar has no usable width left
            // between the two touch points, so drop the whole row; the
            // settings toggle hides it at any width.
            if settings.showInfoBar && settings.gridColumns >= 3 {
                infoRow
                    .padding(.top, 26)
                    .staggered(show: show, delay: 0.48)
            }
            Text("AGINOL - Agentic Information Overlay")
                .font(.system(size: 9, weight: .semibold))
                .tracking(3.5)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(.white.opacity(0.22))
                .padding(.top, 14)
                .staggered(show: show, delay: 0.54)
        }
        // Fixed, grid-derived width: the deck's size must never depend on
        // what the window proposes, or NSHostingView's min/max-size probes
        // make the ideal size oscillate (wrapping/scaling text) and trip
        // AppKit's constraint-loop detector — an uncaught exception that
        // crashes the app at narrow grids.
        .frame(width: gridWidth)
        .padding(.horizontal, DeckMetrics.bezelPaddingH)
        .padding(.top, DeckMetrics.bezelPaddingTop)
        .padding(.bottom, DeckMetrics.bezelPaddingBottom)
        .background(
            bezel
                .contentShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                               style: .continuous))
                .onTapGesture(count: 2) { controller.toggleTuck() }
        )
        .overlay(alignment: .bottomTrailing) {
            GearButton {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showSettings = true
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 8)
            .opacity(showSettings ? 0 : 1)
        }
        .overlay {
            if showSettings {
                settingsOverlay
            }
        }
        .overlay {
            if let slot = editingSlot {
                keyPickerOverlay(slot: slot)
            }
        }
        .overlay {
            if showOnlinePrompt {
                onlinePromptOverlay
            }
        }
        .overlay {
            if showAgentList {
                agentListOverlay
            }
        }
        .overlay {
            // While tucked, any click on the visible sliver slides the
            // deck back instead of pressing whatever key is under it.
            if controller.isTucked {
                Color.black.opacity(0.001)
                    .contentShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                                   style: .continuous))
                    .onTapGesture { controller.untuck() }
            }
        }
        .onAppear {
            model.start()
            show = true
        }
        // The window is sized manually (no hosting constraints): grow
        // immediately, shrink after the spring animation settles.
        .onChange(of: settings.gridColumns) { _, _ in
            controller.gridDidChange()
        }
        .onChange(of: settings.gridRows) { _, _ in
            controller.gridDidChange()
        }
        .onChange(of: settings.showInfoBar) { _, _ in
            controller.gridDidChange()
        }
    }

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .clipShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                            style: .continuous))
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showSettings = false
                    }
                }
            SettingsCard(
                settings: settings,
                onClose: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showSettings = false
                    }
                },
                onQuit: { NSApp.terminate(nil) }
            )
            .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(settings.gridColumns) * DeckMetrics.keySize
            + CGFloat(settings.gridColumns - 1) * DeckMetrics.keySpacing
    }

    // MARK: - Bezel

    private var bezel: some View {
        RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.115), Color(white: 0.055)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
    }

    // MARK: - Keys

    private var keyGrid: some View {
        VStack(spacing: DeckMetrics.keySpacing) {
            ForEach(0..<settings.gridRows, id: \.self) { row in
                HStack(spacing: DeckMetrics.keySpacing) {
                    ForEach(0..<settings.gridColumns, id: \.self) { column in
                        keySlot(row * settings.gridColumns + column)
                    }
                }
            }
        }
    }

    private func keySlot(_ slot: Int) -> some View {
        let assignment = model.assignment(forSlot: slot)
        return KeyView(
            background: keyBackground(for: assignment),
            chromeless: assignment == .spacer,
            appearDelay: Double(slot) * 0.06,
            show: show,
            action: { keyAction(for: assignment) },
            longPressAction: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    editingSlot = slot
                }
            }
        ) {
            keyContent(for: assignment)
        }
    }

    private func keyBackground(for assignment: KeyAssignment) -> Color {
        switch assignment {
        case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus:
            model.agent(withID: assignment.providerID!)?.status.tileBackground
                ?? DeckColor.grayTile
        case .allAgents:
            DeckColor.oliveTile
        case .claudeUsed, .claudeLeft, .codexUsed, .codexLeft, .opencodeUsage, .kimiUsage:
            model.usageEntry(forProvider: assignment.providerID!)?.tileBackground
                ?? DeckColor.grayTile
        case .claudeSessionUsed, .claudeSessionLeft:
            model.usageEntry(withID: "claude-session")?.tileBackground ?? DeckColor.grayTile
        case .codexSessionUsed, .codexSessionLeft:
            model.usageEntry(withID: "codex-session")?.tileBackground ?? DeckColor.grayTile
        case .claudeSpend:
            model.usageEntry(withID: "claude-spend")?.tileBackground ?? DeckColor.grayTile
        case .info, .clock:
            DeckColor.indigoTile
        case .spacer:
            .clear
        }
    }

    @ViewBuilder
    private func keyContent(for assignment: KeyAssignment) -> some View {
        switch assignment {
        case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus:
            if let agent = model.agent(withID: assignment.providerID!) {
                AgentKeyContent(agent: agent)
            }
        case .allAgents:
            AllAgentsKeyContent(model: model)
        case .claudeUsed, .codexUsed, .opencodeUsage, .kimiUsage:
            if let entry = model.usageEntry(forProvider: assignment.providerID!) {
                UsageKeyContent(usage: entry)
            }
        case .claudeLeft, .codexLeft:
            if let entry = model.usageEntry(forProvider: assignment.providerID!) {
                UsageKeyContent(usage: entry, showRemaining: true)
            }
        case .claudeSessionUsed:
            UsageKeyContent(usage: sessionUsage(withID: "claude-session", name: "CLAUDE"))
        case .claudeSessionLeft:
            UsageKeyContent(usage: sessionUsage(withID: "claude-session", name: "CLAUDE"),
                            showRemaining: true)
        case .codexSessionUsed:
            UsageKeyContent(usage: sessionUsage(withID: "codex-session", name: "CODEX"))
        case .codexSessionLeft:
            UsageKeyContent(usage: sessionUsage(withID: "codex-session", name: "CODEX"),
                            showRemaining: true)
        case .claudeSpend:
            if let entry = model.usageEntry(withID: "claude-spend") {
                UsageKeyContent(usage: entry)
            } else {
                UsageKeyContent(usage: ProviderUsage(
                    id: "claude-spend", name: "CLAUDE", tint: DeckColor.gray,
                    tileBackground: DeckColor.grayTile, kind: .unavailable(caption: "loading")
                ))
            }
        case .info:
            InfoKeyContent(model: model)
        case .clock:
            ClockKeyContent(now: model.now)
        case .spacer:
            Color.clear
        }
    }

    /// Session entry for a key, or an honest placeholder when the
    /// provider reports no session window (e.g. newer Codex CLIs only
    /// log the weekly limit).
    private func sessionUsage(withID id: String, name: String) -> ProviderUsage {
        model.usageEntry(withID: id) ?? ProviderUsage(
            id: id, name: name, tint: DeckColor.gray,
            tileBackground: DeckColor.grayTile,
            kind: .unavailable(caption: "no session data")
        )
    }

    private func keyAction(for assignment: KeyAssignment) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            switch assignment {
            case .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus:
                if let agent = model.agent(withID: assignment.providerID!) {
                    model.acknowledge(agent)
                    if let page = model.pageIndex(forAgent: agent.id) {
                        model.infoPageIndex = page
                    }
                }
            case .allAgents:
                model.showSummaryPage()
                showAgentList = true
            case .claudeUsed, .claudeLeft, .codexUsed, .codexLeft, .opencodeUsage, .kimiUsage:
                if let entry = model.usageEntry(forProvider: assignment.providerID!),
                   case .unavailable(let caption) = entry.kind, caption == "online off" {
                    showOnlinePrompt = true
                } else if let page = model.pageIndex(forUsageProvider: assignment.providerID!) {
                    model.infoPageIndex = page
                }
            case .claudeSessionUsed, .claudeSessionLeft:
                if let page = model.pageIndex(forUsageID: "claude-session") {
                    model.infoPageIndex = page
                }
            case .codexSessionUsed, .codexSessionLeft:
                if let page = model.pageIndex(forUsageID: "codex-session") {
                    model.infoPageIndex = page
                }
            case .claudeSpend:
                if let page = model.pageIndex(forUsageID: "claude-spend") {
                    model.infoPageIndex = page
                }
            case .info:
                model.advancePage(by: 1)
            case .clock, .spacer:
                break
            }
        }
    }

    // MARK: - Key picker (long-press, two layers)

    private struct PickerProvider: Identifiable {
        let id: String
        let name: String
        let options: [KeyAssignment]
    }

    /// Layer 1 general entries; providers get a layer 2 each. New
    /// OpenUsage-ported providers slot into this list.
    private static let generalOptions: [KeyAssignment] = [.allAgents, .info, .clock, .spacer]
    private static let pickerProviders: [PickerProvider] = [
        PickerProvider(id: "claude", name: "Claude",
                       options: [.claudeStatus, .claudeUsed, .claudeLeft, .claudeSessionUsed, .claudeSessionLeft, .claudeSpend]),
        PickerProvider(id: "codex", name: "Codex",
                       options: [.codexStatus, .codexUsed, .codexLeft, .codexSessionUsed, .codexSessionLeft]),
        PickerProvider(id: "opencode", name: "OpenCode",
                       options: [.opencodeStatus, .opencodeUsage]),
        PickerProvider(id: "kimi", name: "Kimi",
                       options: [.kimiStatus, .kimiUsage]),
    ]

    private func keyPickerOverlay(slot: Int) -> some View {
        let close = {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                editingSlot = nil
                pickerProviderID = nil
            }
        }
        let currentAssignment: KeyAssignment? = model.assignment(forSlot: slot)

        return ZStack {
            Color.black.opacity(0.45)
                .clipShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                            style: .continuous))
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                if let providerID = pickerProviderID,
                   let provider = Self.pickerProviders.first(where: { $0.id == providerID }) {
                    // Layer 2: one provider's metrics
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(provider.name.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            pickerProviderID = nil
                        }
                    }
                    .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(provider.options) { option in
                            pickerRow(label: option.metricLabel,
                                      selected: currentAssignment == option) {
                                model.assign(option, toSlot: slot)
                                close()
                            }
                        }
                    }
                } else {
                    // Layer 1: general entries + provider list
                    Text("KEY \(slot + 1) SHOWS")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 8)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Self.generalOptions) { option in
                                pickerRow(label: option.metricLabel,
                                          selected: currentAssignment == option) {
                                    model.assign(option, toSlot: slot)
                                    close()
                                }
                            }
                            Text("PROVIDERS")
                                .font(.system(size: 8, weight: .heavy))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(Self.pickerProviders) { provider in
                                let holdsCurrent = currentAssignment.map {
                                    provider.options.contains($0)
                                } ?? false
                                pickerRow(label: provider.name,
                                          selected: holdsCurrent,
                                          chevron: true) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        pickerProviderID = provider.id
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(14)
            .frame(width: 250)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            )
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    private func pickerRow(label: String, selected: Bool, chevron: Bool = false,
                           action: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: selected ? .bold : .medium))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.7))
            Spacer()
            if selected && !chevron {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DeckColor.green)
            }
            if chevron {
                if selected {
                    Circle()
                        .fill(DeckColor.green)
                        .frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(selected ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: - Agents list (tap ALL AGENTS)

    private var agentListOverlay: some View {
        let close = {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showAgentList = false
            }
        }
        return ZStack {
            Color.black.opacity(0.45)
                .clipShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                            style: .continuous))
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("AGENTS")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    CardButton(systemImage: "xmark", action: close)
                }
                .padding(.bottom, 6)
                ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { HairlineSeparator() }
                    HStack(spacing: 10) {
                        Circle()
                            .fill(agent.status.tint)
                            .frame(width: 8, height: 8)
                            .shadow(color: agent.status.tint.opacity(0.8), radius: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.95))
                                Text(agent.status.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(agent.status.tint)
                            }
                            Text(agent.status == .offline ? "not installed"
                                 : agent.models.isEmpty ? "no recent model"
                                 : agent.models.joined(separator: " · "))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 8)
                        if agent.sessions > 0 {
                            Text("\(agent.sessions)")
                                .font(.system(size: 12, weight: .heavy))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(16)
            .frame(width: 270)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            )
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // MARK: - Online access prompt

    private var onlinePromptOverlay: some View {
        let close = {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showOnlinePrompt = false
            }
        }
        return ZStack {
            Color.black.opacity(0.45)
                .clipShape(RoundedRectangle(cornerRadius: DeckMetrics.bezelCorner,
                                            style: .continuous))
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                Text("ALLOW ONLINE ACCESS?")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 8)
                Text("Plan limits only exist on the vendors' servers. AgInOl would fetch them with the CLIs' own credentials — a one-time Keychain prompt may appear. Everything else stays local.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                HStack(spacing: 8) {
                    Text("Not now")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .contentShape(Capsule())
                        .onTapGesture(perform: close)
                    Spacer()
                    Text("Go online")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DeckColor.green))
                        .contentShape(Capsule())
                        .onTapGesture {
                            settings.onlineAccess = true
                            close()
                        }
                }
            }
            .padding(16)
            .frame(width: 250)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            )
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // MARK: - Info bar row

    private var infoRow: some View {
        HStack(spacing: 18) {
            TouchPoint(systemImage: "chevron.left") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    model.advancePage(by: -1)
                }
            }
            InfoBarView(model: model)
            TouchPoint(systemImage: "chevron.right") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    model.advancePage(by: 1)
                }
            }
        }
    }
}

// MARK: - Key chrome

/// One physical key: colored card face, glass highlight, breathing press
/// physics. Click fires `action`; holding ≥ 0.45 s or double-tapping
/// fires `longPressAction` on release (choose what the key displays).
struct KeyView<Content: View>: View {
    var background: Color
    /// Spacer keys: no face, highlight, border, or shadow — just an
    /// empty, still long-pressable slot in the grid.
    var chromeless = false
    var appearDelay: Double
    var show: Bool
    var action: () -> Void
    var longPressAction: () -> Void = {}
    @ViewBuilder var content: Content

    @GestureState private var isPressed = false
    @State private var pressBegan: Date?
    @State private var lastTapAt = Date.distantPast

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                .fill(background)
            if !chromeless {
                RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !chromeless {
                RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
        }
        .frame(width: DeckMetrics.keySize, height: DeckMetrics.keySize)
        .compositingGroup()
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .saturation(isPressed ? 0.82 : 1.0)
        .shadow(color: .black.opacity(chromeless ? 0 : isPressed ? 0.12 : 0.35),
                radius: isPressed ? 2 : 7, y: isPressed ? 1 : 4)
        .contentShape(RoundedRectangle(cornerRadius: DeckMetrics.keyCorner,
                                       style: .continuous))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onChanged { _ in
                    if pressBegan == nil { pressBegan = Date() }
                }
                .onEnded { _ in
                    let wasLong = pressBegan.map { Date().timeIntervalSince($0) >= 0.45 } ?? false
                    pressBegan = nil
                    if wasLong {
                        longPressAction()
                    } else if Date().timeIntervalSince(lastTapAt) < 0.35 {
                        // Double tap: the first tap already ran the normal
                        // action; the quick second one opens the key menu.
                        lastTapAt = .distantPast
                        longPressAction()
                    } else {
                        lastTapAt = Date()
                        action()
                    }
                }
        )
        .staggered(show: show, delay: appearDelay)
    }
}

// MARK: - Key contents

struct AgentKeyContent: View {
    let agent: Agent
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(agent.status.tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: agent.status.tint.opacity(0.9), radius: pulse ? 6 : 2)
                    .opacity(agent.status == .needsYou && pulse ? 0.5 : 1)
                Text(agent.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, 12)

            Spacer(minLength: 0)

            Text(agent.status.label)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(agent.status.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if agent.status != .offline, let model = agent.models.first {
                Text(model)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Text(agent.sessionCaption)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, agent.status == .needsYou || agent.status == .offline ? 0 : 10)
            if agent.status == .needsYou || agent.status == .offline {
                Text(agent.hintCaption)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 6)
        .onAppear {
            guard agent.status == .needsYou else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct AllAgentsKeyContent: View {
    let model: DeckModel

    var body: some View {
        VStack(spacing: 0) {
            Text("ALL AGENTS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, 12)

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("\(model.openSessions)")
                        .font(.system(size: 24, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(DeckColor.cyan)
                    Text("OPEN")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                VStack(spacing: 2) {
                    Text("\(model.attentionCount)")
                        .font(.system(size: 24, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(DeckColor.amber)
                    Text("NEED YOU")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 0)

            Text("tap overview")
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
    }
}

struct UsageKeyContent: View {
    let usage: ProviderUsage
    /// Show the unused remainder ("83% · 7d left") instead of consumption.
    var showRemaining = false

    private var displayValue: String {
        guard showRemaining, case .percent(let fraction, _) = usage.kind else {
            return usage.bigValue
        }
        return "\(Int(((1 - fraction) * 100).rounded()))%"
    }

    private var displayCaption: String {
        guard showRemaining, case .percent(_, let window) = usage.kind else {
            return usage.caption
        }
        return "\(window) left"
    }

    private var displayBarFraction: Double? {
        guard let fraction = usage.barFraction else { return nil }
        return showRemaining ? 1 - fraction : fraction
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(usage.tint)
                    .frame(width: 7, height: 7)
                Text(usage.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, 12)

            Spacer(minLength: 0)

            Text(displayValue)
                .font(.system(size: 24, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(usage.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            if let fraction = displayBarFraction {
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(width: 62, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(usage.tint)
                            .frame(width: 62 * fraction)
                    }
                    .padding(.bottom, 6)
            } else {
                Capsule()
                    .fill(usage.tint.opacity(0.55))
                    .frame(width: 62, height: 4)
                    .padding(.bottom, 6)
            }
            Text(displayCaption)
                .font(.system(size: 8.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
    }
}

struct ClockKeyContent: View {
    let now: Date

    var body: some View {
        VStack(spacing: 5) {
            Text(now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 22, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
            Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

struct InfoKeyContent: View {
    let model: DeckModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "info.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DeckColor.purple)
            Spacer(minLength: 0)
            Text("INFO \(model.infoPageIndex + 1)/\(model.infoPages.count)")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Info bar

struct InfoBarView: View {
    @Bindable var model: DeckModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DeckColor.screen)
            if let page = model.currentPage {
                pageView(page)
                    .padding(.horizontal, 18)
                    .id(page.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
        .frame(height: DeckMetrics.infoBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func pageView(_ page: DeckModel.InfoPage) -> some View {
        switch page.content {
        case .summary:
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ALL AGENTS")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.95))
                    HStack(spacing: 12) {
                        CountUnit(value: model.openSessions, label: "OPEN", tint: DeckColor.cyan)
                        CountUnit(value: model.workingCount, label: "WORK", tint: DeckColor.green)
                        CountUnit(value: model.attentionCount, label: "NEED YOU", tint: DeckColor.amber)
                    }
                }
                Spacer(minLength: 8)
                Text(model.agents.map { $0.name.capitalized }.joined(separator: " · "))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(-1)
            }
        case .agent(let agent):
            // Same two-row shape as the summary page: heading line on
            // top, details underneath — fits the narrow 3-column bar.
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(agent.status.tint)
                            .frame(width: 8, height: 8)
                            .shadow(color: agent.status.tint.opacity(0.8), radius: 3)
                        Text(agent.name)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Text(agent.status.label)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(agent.status.tint)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if agent.status == .working, let start = agent.startedAt {
                            Text(DeckModel.elapsed(since: start, now: model.now))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(agent.sessionCaption)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        case .usage(let entry):
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(entry.tint)
                            .frame(width: 8, height: 8)
                        Text(entry.name)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Text(entry.bigValue)
                            .font(.system(size: 14, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(entry.tint)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(entry.caption)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let secondary = entry.secondaryText {
                            Text(secondary)
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let fraction = entry.barFraction {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(width: 54, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(entry.tint)
                                .frame(width: 54 * fraction)
                        }
                }
            }
        }
    }
}

/// Big colored number + tiny label, as in the ALL AGENTS summary bar.
struct CountUnit: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(.system(size: 17, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Borderless gear in the bezel corner opening the settings card.
struct GearButton: View {
    let action: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isPressed ? 0.85 : 0.28))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { _ in action() }
            )
    }
}

/// Settings card: online access toggle + Quit. More (launch at login,
/// opacity, providers) arrives with Phase 4.
struct SettingsCard: View {
    @Bindable var settings: AppSettings
    let onClose: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AGINOL")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Agentic Information Overlay")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                CardButton(systemImage: "xmark", action: onClose)
            }
            .padding(.bottom, 12)

            HairlineSeparator()

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.onlineAccess) {
                    Text("Online plan limits")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .toggleStyle(DeckToggleStyle())
                Text("Fetch Claude/Codex limits with the CLIs' own credentials. May show a one-time Keychain prompt. Off = fully local.")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)

            HairlineSeparator()

            VStack(alignment: .leading, spacing: 8) {
                Text("Key grid")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                gridOptionRow(label: "Columns", options: AppSettings.columnOptions,
                              selection: $settings.gridColumns)
                gridOptionRow(label: "Rows", options: AppSettings.rowOptions,
                              selection: $settings.gridRows)
                Toggle(isOn: Binding(
                    get: { settings.showInfoBar },
                    set: { value in
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            settings.showInfoBar = value
                        }
                    }
                )) {
                    Text("Info bar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .toggleStyle(DeckToggleStyle())
                .padding(.top, 4)
            }
            .padding(.vertical, 12)

            HairlineSeparator()

            Text("Double-tap or long-press any key to choose what it displays")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 12)

            HairlineSeparator()

            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                Text("Quit AgInOl")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color(red: 1.00, green: 0.42, blue: 0.38))
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onQuit)
        }
        .padding(16)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        )
    }

    private func gridOptionRow(label: String, options: [Int],
                               selection: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { value in
                    let isSelected = selection.wrappedValue == value
                    Text("\(value)")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.black.opacity(0.85)
                                                    : Color.white.opacity(0.65))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? DeckColor.green : Color.white.opacity(0.08))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                selection.wrappedValue = value
                            }
                        }
                }
            }
        }
    }
}

/// Dark-card switch: macOS's .switch style renders an invisible track on
/// our near-black background, so draw the capsule ourselves.
struct DeckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? DeckColor.green : .white.opacity(0.18))
                .frame(width: 36, height: 21)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .padding(2.5)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7),
                           value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// Small circular ghost button used inside the settings card.
struct CardButton: View {
    let systemImage: String
    let action: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(isPressed ? 0.9 : 0.45))
            .frame(width: 24, height: 24)
            .background(Circle().fill(.white.opacity(0.08)))
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onEnded { _ in action() }
            )
    }
}

/// Sub-pixel hairline that adapts to the dark card.
struct HairlineSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 0.33)
    }
}

/// Round capacitive touch point flanking the info bar.
struct TouchPoint: View {
    let systemImage: String
    let action: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.10))
            Circle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(isPressed ? 0.95 : 0.55))
        }
        .frame(width: DeckMetrics.touchPointSize, height: DeckMetrics.touchPointSize)
        .scaleEffect(isPressed ? 0.9 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { _ in action() }
        )
    }
}

// MARK: - Helpers

extension View {
    /// Staggered appear: fade-in + 8pt upward drift with spring physics.
    func staggered(show: Bool, delay: Double) -> some View {
        self
            .opacity(show ? 1 : 0)
            .offset(y: show ? 0 : 8)
            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(delay), value: show)
    }
}

#Preview {
    DeckView(model: .demo(), controller: PanelController())
        .padding(40)
        .background(.blue.opacity(0.2))
}
