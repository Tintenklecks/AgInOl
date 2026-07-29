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
            )]
        )
        let snapshot = DeckSnapshot(capturedAt: timestamp, content: content)

        let decoded = try JSONDecoder().decode(
            DeckSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.content == content)
    }
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
