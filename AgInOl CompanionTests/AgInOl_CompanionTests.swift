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
