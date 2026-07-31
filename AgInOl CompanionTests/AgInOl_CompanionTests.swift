//
//  AgInOl_CompanionTests.swift
//  AgInOl CompanionTests
//
//  Created by puco on 20.07.2026.
//

import Foundation
import Testing
@testable import AgInOl_Companion

struct AgInOl_CompanionTests {
    @MainActor
    @Test func legacyAgentWithoutSessionDetailsStillDecodes() throws {
        let data = Data(#"{"id":"claude","name":"CLAUDE","status":"idle","sessions":1,"startedAt":null,"models":[]}"#.utf8)

        let agent = try JSONDecoder().decode(SnapshotAgent.self, from: data)

        #expect(agent.openSessions == nil)
    }

    @MainActor
    @Test func snapshotRoundTripPreservesTapDetails() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 12_345)
        let content = DeckSnapshotContent(
            agents: [SnapshotAgent(
                id: "codex",
                name: "CODEX",
                status: .working,
                sessions: 1,
                startedAt: timestamp,
                models: ["gpt-5.6-sol"],
                openSessions: [SnapshotAgentSession(
                    id: "codex:session",
                    title: "AgInOl",
                    state: .working,
                    since: timestamp
                )]
            )],
            usage: [SnapshotUsage(
                id: "codex-usage",
                name: "CODEX",
                palette: .codex,
                kind: .percent(fraction: 0.42, window: "7d"),
                secondaryText: "5h 10% used",
                resetsAt: timestamp
            )],
            layout: SnapshotDeckLayout(
                revision: 4,
                columns: 4,
                rows: 2,
                assignments: [.codexStatus, .codexUsed, .history, .spacer,
                              .allAgents, .clock, .info, .spacer]
            )
        )
        let snapshot = DeckSnapshot(capturedAt: timestamp, content: content)

        let decoded = try JSONDecoder().decode(
            DeckSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.content == content)
        #expect(decoded.content.layout?.assignments.last == .spacer)
    }

    @Test func historyCursorPreservesFractionalTimestamp() throws {
        let cursor = SnapshotHistoryCursor(
            occurredAt: Date(timeIntervalSince1970: 1_785_484_800.123456),
            sequence: 42
        )

        let decoded = try JSONDecoder().decode(
            SnapshotHistoryCursor.self,
            from: JSONEncoder().encode(cursor)
        )

        #expect(decoded == cursor)
    }

    @MainActor
    @Test func companionImportsMacLayoutOnceThenKeepsDeviceChoices() {
        let initial = companionSnapshot(assignments: [
            .claudeStatus, .codexStatus, .opencodeStatus, .kimiStatus,
            .claudeUsed, .codexUsed, .opencodeUsage, .kimiUsage,
        ])
        let sync = MemoryDeckSync(latest: initial)
        let store = MemoryCompanionDeckLayoutStore()
        let mirror = DeckMirror(sync: sync, layoutStore: store)

        mirror.start()
        mirror.configureSlotCount(10)

        #expect(mirror.tileAssignments.count == 10)
        #expect(mirror.tileAssignments[0] == .claudeStatus)
        #expect(mirror.tileAssignments[8] == .spacer)

        mirror.assign(.history, toSlot: 0)
        sync.deliver(companionSnapshot(assignments: [
            .clock, .clock, .clock, .clock, .clock, .clock, .clock, .clock,
        ]))

        #expect(mirror.tileAssignments[0] == .history)
        #expect(store.layout?.assignments[0] == .history)

        let restarted = DeckMirror(
            sync: MemoryDeckSync(latest: companionSnapshot(assignments: [.clock])),
            layoutStore: store
        )
        restarted.start()
        restarted.configureSlotCount(10)
        #expect(restarted.tileAssignments[0] == .history)
    }

    @MainActor
    @Test func companionLayoutGrowsWithoutLosingHiddenSlots() {
        let sync = MemoryDeckSync(latest: companionSnapshot(assignments: [
            .claudeStatus, .codexStatus, .history, .clock,
        ]))
        let store = MemoryCompanionDeckLayoutStore()
        let mirror = DeckMirror(sync: sync, layoutStore: store)

        mirror.start()
        mirror.configureSlotCount(6)
        mirror.assign(.allAgents, toSlot: 5)
        mirror.configureSlotCount(4)
        #expect(mirror.tileAssignments.count == 4)

        mirror.configureSlotCount(6)
        #expect(mirror.tileAssignments[5] == .allAgents)
    }

    @Test func companionGridUsesDisplaySizeAndKeepsMacLikeKeyProportions() {
        let phonePortrait = CompanionGridMetrics(size: CGSize(width: 393, height: 852))
        let padPortrait = CompanionGridMetrics(size: CGSize(width: 1_024, height: 1_366))
        let padLandscape = CompanionGridMetrics(size: CGSize(width: 1_366, height: 1_024))

        #expect(phonePortrait.columns == 2)
        #expect(phonePortrait.rows == 5)
        #expect(padPortrait.columns == 4)
        #expect(padPortrait.rows == 6)
        #expect(padLandscape.columns == 6)
        #expect(padLandscape.rows == 4)
    }
}

@MainActor
private final class MemoryCompanionDeckLayoutStore: CompanionDeckLayoutStoring {
    var layout: CompanionDeckLayout?

    func load() -> CompanionDeckLayout? { layout }
    func save(_ layout: CompanionDeckLayout) { self.layout = layout }
}

@MainActor
private final class MemoryDeckSync: DeckSyncSubscribing {
    var latest: DeckSnapshot?
    var onChange: ((DeckSnapshot) -> Void)?

    init(latest: DeckSnapshot?) {
        self.latest = latest
    }

    func start() {}

    func deliver(_ snapshot: DeckSnapshot) {
        latest = snapshot
        onChange?(snapshot)
    }
}

private func companionSnapshot(assignments: [SnapshotTileAssignment]) -> DeckSnapshot {
    DeckSnapshot(
        capturedAt: Date(timeIntervalSinceReferenceDate: 1_000),
        content: DeckSnapshotContent(
            agents: [],
            usage: [],
            layout: SnapshotDeckLayout(
                revision: 1,
                columns: max(assignments.count, 1),
                rows: 1,
                assignments: assignments
            )
        )
    )
}

private final class MemoryAppReviewStateStore: AppReviewStateStoring {
    var state: AppReviewPromptState?

    func load() -> AppReviewPromptState? {
        state
    }

    func save(_ state: AppReviewPromptState) {
        self.state = state
    }
}

@MainActor
struct AppReviewCoordinatorTests {
    @Test func requestsAfterTwentyDetailAppearancesAcrossRestarts() {
        let store = MemoryAppReviewStateStore()
        var requestCount = 0
        let makeCoordinator = {
            AppReviewCoordinator(
                store: store,
                currentVersion: { "1.0" },
                requestReview: {
                    requestCount += 1
                    return true
                }
            )
        }

        let firstRun = makeCoordinator()
        for _ in 0..<19 {
            firstRun.detailDidAppear()
        }
        #expect(requestCount == 0)

        let restarted = makeCoordinator()
        restarted.detailDidAppear()
        #expect(requestCount == 1)

        restarted.detailDidAppear()
        #expect(requestCount == 1)
        #expect(store.state?.detailPresentationCount == 20)
        #expect(store.state?.requestedVersions == ["1.0"])
    }

    @Test func newMarketingVersionRequiresTwentyNewDetailAppearances() {
        let store = MemoryAppReviewStateStore()
        var version = "1.0"
        var requestCount = 0
        let coordinator = AppReviewCoordinator(
            store: store,
            currentVersion: { version },
            requestReview: {
                requestCount += 1
                return true
            }
        )

        for _ in 0..<20 {
            coordinator.detailDidAppear()
        }
        #expect(requestCount == 1)

        version = "1.1"
        for _ in 0..<19 {
            coordinator.detailDidAppear()
        }
        #expect(requestCount == 1)

        coordinator.detailDidAppear()
        #expect(requestCount == 2)
        #expect(store.state?.requestedVersions == ["1.0", "1.1"])
    }

    @Test func failedSystemRequestRemainsEligibleForRetry() {
        let store = MemoryAppReviewStateStore()
        var canRequest = false
        var requestCount = 0
        let coordinator = AppReviewCoordinator(
            store: store,
            currentVersion: { "1.0" },
            detailPresentationThreshold: 1,
            requestReview: {
                requestCount += 1
                return canRequest
            }
        )

        coordinator.detailDidAppear()
        #expect(requestCount == 1)
        #expect(store.state?.requestedVersions.isEmpty == true)

        canRequest = true
        coordinator.detailDidAppear()
        #expect(requestCount == 2)
        #expect(store.state?.requestedVersions == ["1.0"])
    }

#if DEBUG
    @Test func debugGestureBypassesEngagementThresholdWithoutConsumingVersion() {
        let store = MemoryAppReviewStateStore()
        var requestCount = 0
        let coordinator = AppReviewCoordinator(
            store: store,
            currentVersion: { "1.0" },
            requestReview: {
                requestCount += 1
                return true
            }
        )

        coordinator.requestReviewForDebug()

        #expect(requestCount == 1)
        #expect(store.state == nil)
    }
#endif
}
