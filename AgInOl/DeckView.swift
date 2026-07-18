//
//  DeckView.swift
//  AgInOl
//
//  The AgInOl deck: a hardware-style panel with 4×2 colored key tiles,
//  an info-bar screen, and two round touch points.
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
    @State private var show = false

    var body: some View {
        VStack(spacing: 0) {
            keyGrid
            infoRow
                .padding(.top, 26)
                .staggered(show: show, delay: 0.48)
            Text("AGINOL")
                .font(.system(size: 9, weight: .semibold))
                .tracking(3.5)
                .foregroundStyle(.white.opacity(0.22))
                .padding(.top, 14)
                .staggered(show: show, delay: 0.54)
        }
        .padding(.horizontal, DeckMetrics.bezelPaddingH)
        .padding(.top, DeckMetrics.bezelPaddingTop)
        .padding(.bottom, DeckMetrics.bezelPaddingBottom)
        .background(bezel)
        .onAppear {
            model.start()
            show = true
        }
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
            HStack(spacing: DeckMetrics.keySpacing) {
                ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                    KeyView(background: agent.status.tileBackground,
                            appearDelay: Double(index) * 0.06, show: show) {
                        model.acknowledge(agent)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            model.infoPageIndex = index + 1
                        }
                    } content: {
                        AgentKeyContent(agent: agent)
                    }
                }
                KeyView(background: DeckColor.oliveTile, appearDelay: 0.18, show: show) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        model.showSummaryPage()
                    }
                } content: {
                    AllAgentsKeyContent(model: model)
                }
            }
            HStack(spacing: DeckMetrics.keySpacing) {
                ForEach(Array(model.usage.enumerated()), id: \.element.id) { index, entry in
                    KeyView(background: entry.tileBackground,
                            appearDelay: 0.24 + Double(index) * 0.06, show: show) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            model.infoPageIndex = model.agents.count + 1 + index
                        }
                    } content: {
                        UsageKeyContent(usage: entry)
                    }
                }
                KeyView(background: DeckColor.indigoTile, appearDelay: 0.42, show: show) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        model.advancePage(by: 1)
                    }
                } content: {
                    InfoKeyContent(model: model)
                }
            }
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

/// One physical key: colored card face, glass highlight, breathing press physics.
struct KeyView<Content: View>: View {
    var background: Color
    var appearDelay: Double
    var show: Bool
    var action: () -> Void
    @ViewBuilder var content: Content

    @GestureState private var isPressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                .fill(background)
            RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.08), .clear],
                        startPoint: .top, endPoint: .center
                    )
                )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RoundedRectangle(cornerRadius: DeckMetrics.keyCorner, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .frame(width: DeckMetrics.keySize, height: DeckMetrics.keySize)
        .compositingGroup()
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .saturation(isPressed ? 0.82 : 1.0)
        .shadow(color: .black.opacity(isPressed ? 0.12 : 0.35),
                radius: isPressed ? 2 : 7, y: isPressed ? 1 : 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { _ in action() }
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

            Spacer(minLength: 0)

            Text(agent.sessionCaption)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            Text(agent.hintCaption)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.top, 2)
                .padding(.bottom, 10)
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

            Text(usage.bigValue)
                .font(.system(size: 24, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(usage.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            if let fraction = usage.barFraction {
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
            Text(usage.caption)
                .font(.system(size: 8.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
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
            HStack(spacing: 10) {
                Circle()
                    .fill(agent.status.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: agent.status.tint.opacity(0.8), radius: 3)
                Text(agent.name)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.95))
                Text(agent.status.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(agent.status.tint)
                Spacer(minLength: 8)
                if agent.status == .working, let start = agent.startedAt {
                    Text(DeckModel.elapsed(since: start, now: model.now))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(agent.sessionCaption)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        case .usage(let entry):
            HStack(spacing: 10) {
                Circle()
                    .fill(entry.tint)
                    .frame(width: 8, height: 8)
                Text(entry.name)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.95))
                Text(entry.bigValue)
                    .font(.system(size: 14, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(entry.tint)
                Text(entry.caption)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                if let fraction = entry.barFraction {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(width: 70, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(entry.tint)
                                .frame(width: 70 * fraction)
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
    DeckView(model: .demo())
        .padding(40)
        .background(.blue.opacity(0.2))
}
