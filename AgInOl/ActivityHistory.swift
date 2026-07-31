//
//  ActivityHistory.swift
//  AgInOl
//
//  Append-only history of detected agent session starts. Visibility is
//  stored separately, so hiding an entry never mutates the source event.
//

import Foundation
import Observation
import SQLite3

nonisolated struct SessionStartCandidate: Sendable, Equatable {
    let sessionID: String
    let startedAt: Date
    let snippet: String
    let snippetSource: String
}

nonisolated struct ActivityHistoryEntry: Identifiable, Sendable, Equatable {
    let sequence: Int64
    let eventID: String
    let occurredAt: Date
    let observedAt: Date
    let providerID: String
    let providerName: String
    let sessionID: String
    let snippet: String
    let snippetSource: String
    let isHidden: Bool

    var id: String { eventID }
}

nonisolated struct ActivityHistoryError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// SQLite provides atomic appends and a uniqueness constraint across app
/// restarts. UPDATE and DELETE are rejected for the event table; the user's
/// hide/unhide preference lives in its own projection table.
actor ActivityHistoryStore {
    static let shared = ActivityHistoryStore()

    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func append(_ candidates: [SessionStartCandidate],
                providerID: String,
                providerName: String) throws {
        guard !candidates.isEmpty else { return }
        let db = try openDatabase()
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: db)
        do {
            let eventSQL = """
            INSERT OR IGNORE INTO activity_event
              (event_id, occurred_at, observed_at, provider_id, provider_name,
               session_id, snippet, snippet_source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            let contentSQL = """
            INSERT OR IGNORE INTO activity_event_content
              (event_id, observed_at, content)
            VALUES (?, ?, ?);
            """
            var eventStatement: OpaquePointer?
            var contentStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, eventSQL, -1, &eventStatement, nil) == SQLITE_OK else {
                throw error(for: db, fallback: "History insert could not be prepared")
            }
            defer { sqlite3_finalize(eventStatement) }
            guard sqlite3_prepare_v2(db, contentSQL, -1, &contentStatement, nil) == SQLITE_OK else {
                throw error(for: db, fallback: "History content insert could not be prepared")
            }
            defer { sqlite3_finalize(contentStatement) }

            for candidate in candidates {
                guard let fullContent = CollectorFiles.contentSnippet(candidate.snippet),
                      let snippet = CollectorFiles.contentSnippet(fullContent, limit: 160) else {
                    continue
                }
                let eventID = "session-start:\(providerID):\(candidate.sessionID)"
                let observedAt = Date().timeIntervalSince1970
                sqlite3_reset(eventStatement)
                sqlite3_clear_bindings(eventStatement)
                bind(eventID, at: 1, to: eventStatement)
                sqlite3_bind_double(eventStatement, 2, candidate.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(eventStatement, 3, observedAt)
                bind(providerID, at: 4, to: eventStatement)
                bind(providerName, at: 5, to: eventStatement)
                bind(candidate.sessionID, at: 6, to: eventStatement)
                bind(snippet, at: 7, to: eventStatement)
                bind(candidate.snippetSource, at: 8, to: eventStatement)
                guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                    throw error(for: db, fallback: "History entry could not be appended")
                }

                guard fullContent != snippet else { continue }
                sqlite3_reset(contentStatement)
                sqlite3_clear_bindings(contentStatement)
                bind(eventID, at: 1, to: contentStatement)
                sqlite3_bind_double(contentStatement, 2, observedAt)
                bind(fullContent, at: 3, to: contentStatement)
                guard sqlite3_step(contentStatement) == SQLITE_DONE else {
                    throw error(for: db, fallback: "History content could not be appended")
                }
            }
            try execute("COMMIT;", in: db)
        } catch {
            try? execute("ROLLBACK;", in: db)
            throw error
        }
    }

    func entries(includingHidden: Bool) throws -> [ActivityHistoryEntry] {
        let db = try openDatabase()
        let hiddenClause = includingHidden ? "" : "WHERE h.event_id IS NULL"
        let sql = """
        SELECT e.sequence, e.event_id, e.occurred_at, e.observed_at,
               e.provider_id, e.provider_name, e.session_id,
               COALESCE((
                 SELECT c.content FROM activity_event_content c
                 WHERE c.event_id = e.event_id
                 ORDER BY length(c.content) DESC, c.sequence DESC
                 LIMIT 1
               ), e.snippet),
               e.snippet_source, h.event_id IS NOT NULL
        FROM activity_event e
        LEFT JOIN hidden_activity_event h ON h.event_id = e.event_id
        \(hiddenClause)
        ORDER BY e.occurred_at DESC, e.sequence DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(for: db, fallback: "History query could not be prepared")
        }
        defer { sqlite3_finalize(statement) }

        var result: [ActivityHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(ActivityHistoryEntry(
                sequence: sqlite3_column_int64(statement, 0),
                eventID: text(at: 1, from: statement),
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                providerID: text(at: 4, from: statement),
                providerName: text(at: 5, from: statement),
                sessionID: text(at: 6, from: statement),
                snippet: text(at: 7, from: statement),
                snippetSource: text(at: 8, from: statement),
                isHidden: sqlite3_column_int(statement, 9) != 0
            ))
        }
        return result
    }

    func setHidden(_ hidden: Bool, eventID: String) throws {
        let db = try openDatabase()
        let sql = hidden
            ? "INSERT OR REPLACE INTO hidden_activity_event (event_id, hidden_at) VALUES (?, ?);"
            : "DELETE FROM hidden_activity_event WHERE event_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(for: db, fallback: "Visibility change could not be prepared")
        }
        defer { sqlite3_finalize(statement) }
        bind(eventID, at: 1, to: statement)
        if hidden { sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error(for: db, fallback: "Visibility change could not be saved")
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw ActivityHistoryError(message: "History database could not be opened")
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON;", in: handle)
        try execute(Self.schema, in: handle)
        return handle
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(for: database, fallback: "History database operation failed")
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(at index: Int32, from statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func error(for database: OpaquePointer, fallback: String) -> ActivityHistoryError {
        let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? fallback
        return ActivityHistoryError(message: message)
    }

    private nonisolated static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AgInOl", isDirectory: true)
            .appendingPathComponent("activity-history.sqlite3")
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS activity_event (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE,
      occurred_at REAL NOT NULL,
      observed_at REAL NOT NULL,
      provider_id TEXT NOT NULL,
      provider_name TEXT NOT NULL,
      session_id TEXT NOT NULL,
      snippet TEXT NOT NULL,
      snippet_source TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS activity_event_occurred_at
      ON activity_event(occurred_at DESC);
    CREATE TABLE IF NOT EXISTS activity_event_content (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL REFERENCES activity_event(event_id) ON DELETE RESTRICT,
      observed_at REAL NOT NULL,
      content TEXT NOT NULL,
      UNIQUE(event_id, content)
    );
    CREATE TABLE IF NOT EXISTS hidden_activity_event (
      event_id TEXT PRIMARY KEY REFERENCES activity_event(event_id) ON DELETE RESTRICT,
      hidden_at REAL NOT NULL
    );
    CREATE TRIGGER IF NOT EXISTS activity_event_no_update
      BEFORE UPDATE ON activity_event
      BEGIN SELECT RAISE(ABORT, 'activity history is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS activity_event_no_delete
      BEFORE DELETE ON activity_event
      BEGIN SELECT RAISE(ABORT, 'activity history is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS activity_event_content_no_update
      BEFORE UPDATE ON activity_event_content
      BEGIN SELECT RAISE(ABORT, 'activity history content is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS activity_event_content_no_delete
      BEFORE DELETE ON activity_event_content
      BEGIN SELECT RAISE(ABORT, 'activity history content is append-only'); END;
    """
}

@MainActor
@Observable
final class ActivityHistoryModel {
    private(set) var entries: [ActivityHistoryEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var includingHidden = false

    var visibleCount: Int {
        entries.lazy.filter { !$0.isHidden }.count
    }

    private let store: ActivityHistoryStore

    init(store: ActivityHistoryStore = .shared) {
        self.store = store
    }

    func refresh() {
        isLoading = true
        let includingHidden = includingHidden
        Task {
            do {
                entries = try await store.entries(includingHidden: includingHidden)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func setIncludingHidden(_ value: Bool) {
        includingHidden = value
        refresh()
    }

    func setHidden(_ hidden: Bool, entry: ActivityHistoryEntry) {
        Task {
            do {
                try await store.setHidden(hidden, eventID: entry.eventID)
                entries = try await store.entries(includingHidden: includingHidden)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
