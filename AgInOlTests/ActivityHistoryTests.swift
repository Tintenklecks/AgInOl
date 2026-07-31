import Foundation
import Testing
@testable import AgInOl

struct ActivityHistoryTests {
    @Test func appendsOnceAndKeepsVisibilitySeparate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgInOl-History-\(UUID().uuidString)", isDirectory: true)
        let store = ActivityHistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let candidate = SessionStartCandidate(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 123),
            snippet: "Build the activity history",
            snippetSource: "firstPrompt"
        )

        try await store.append([candidate], providerID: "codex", providerName: "CODEX")
        try await store.append([candidate], providerID: "codex", providerName: "CODEX")

        var visible = try await store.entries(includingHidden: false)
        #expect(visible.count == 1)
        #expect(visible[0].snippet == "Build the activity history")

        try await store.setHidden(true, eventID: visible[0].eventID)
        visible = try await store.entries(includingHidden: false)
        let includingHidden = try await store.entries(includingHidden: true)
        #expect(visible.isEmpty)
        #expect(includingHidden.count == 1)
        #expect(includingHidden[0].isHidden)

        try await store.setHidden(false, eventID: includingHidden[0].eventID)
        visible = try await store.entries(includingHidden: false)
        #expect(visible.count == 1)
        #expect(!visible[0].isHidden)
    }

    @Test func contentSnippetRemovesInjectedContext() {
        let raw = """
        <system-reminder>
        Internal CLI context that should not become the memory cue.
        </system-reminder>
        Implement a chronological history with hideable entries.
        """
        #expect(CollectorFiles.contentSnippet(raw)
                == "Implement a chronological history with hideable entries.")
    }

    @Test func claudeStartUsesFirstUserPrompt() {
        let jsonl = """
        {"type":"system","timestamp":"2026-07-31T08:00:00Z"}
        {"type":"user","timestamp":"2026-07-31T08:01:00Z","message":{"role":"user","content":[{"type":"text","text":"Add a local history"}]}}
        {"type":"user","timestamp":"2026-07-31T08:02:00Z","message":{"role":"user","content":"Second prompt"}}
        """
        let result = ClaudeCollector.parseStart(
            jsonl, sessionID: "claude-1", fallback: .distantPast
        )
        #expect(result?.snippet == "Add a local history")
        #expect(result?.sessionID == "claude-1")
        #expect(result?.startedAt == Date(timeIntervalSince1970: 1_785_484_860))
    }

    @Test func codexStartUsesSessionTimestampAndUserMessage() {
        let jsonl = """
        {"type":"session_meta","payload":{"timestamp":"2026-07-31T08:00:00Z"}}
        {"type":"event_msg","timestamp":"2026-07-31T08:00:05Z","payload":{"type":"user_message","message":"Remember this task"}}
        """
        let result = CodexCollector.parseStart(
            jsonl, sessionID: "codex-1", fallback: .distantPast
        )
        #expect(result?.snippet == "Remember this task")
        #expect(result?.sessionID == "codex-1")
        #expect(result?.startedAt == Date(timeIntervalSince1970: 1_785_484_800))
    }
}
