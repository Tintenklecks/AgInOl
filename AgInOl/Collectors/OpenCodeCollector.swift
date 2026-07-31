//
//  OpenCodeCollector.swift
//  AgInOl
//
//  OpenCode status + token/cost usage from its local SQLite database.
//  Fully offline. Ported from neo-agent-deck's opencode.ts (MIT).
//

import Foundation
import SQLite3

nonisolated final class OpenCodeCollector: AgentCollector, @unchecked Sendable {
    let providerID = "opencode"
    let displayName = "OPENCODE"

    private static let activeMessageWindow: TimeInterval = 10 * 60

    private let databasePath: String
    private let lock = NSLock()
    private var cachedStarts: [SessionStartCandidate] = []
    private var startsScannedAt = Date.distantPast

    init() {
        let env = ProcessInfo.processInfo.environment
        let dataDir = env["OPENCODE_DATA_DIR"].map(CollectorFiles.expand)
            ?? env["XDG_DATA_HOME"].map { CollectorFiles.expand($0) + "/opencode" }
            ?? CollectorFiles.expand("~/.local/share/opencode")
        databasePath = dataDir + "/opencode.db"
    }

    func collect(context: CollectorContext) async -> ProviderReport {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return ProviderReport(installed: false)
        }
        do {
            let sessionRows = try query(Self.sessionsSQL)
            let usageRows = try query(Self.usageSQL)
            let now = Date()
            let startCandidates = historyStarts(now: now)

            let sessions = sessionRows.map { row -> SessionSnapshot in
                let id = (row["id"] as? String) ?? ""
                let key = "opencode:\(id)"
                let messageAt = (row["message_at"] as? Double) ?? (row["time_updated"] as? Double) ?? 0
                let activityAt = Date(timeIntervalSince1970: messageAt / 1000)
                let role = row["role"] as? String
                let finish = row["finish"] as? String
                let hasError = (row["error_type"] as? String) != nil

                var state = SessionState.idle
                var completionAt: Date?
                let recent = now.timeIntervalSince(activityAt) < Self.activeMessageWindow
                let incompleteAssistant = role == "assistant"
                    && (finish == nil || finish == "tool-calls") && !hasError
                if recent && (role == "user" || incompleteAssistant) {
                    state = .working
                } else if role == "assistant", finish == "stop" || hasError,
                          activityAt > context.attentionSince,
                          !context.isAcknowledged(key, at: activityAt) {
                    state = .attention
                    completionAt = activityAt
                }
                return SessionSnapshot(
                    key: key, id: id, state: state, isOpen: state != .idle,
                    activityAt: activityAt, completionAt: completionAt,
                    model: row["model_id"] as? String,
                    title: CollectorFiles.shortTitle(row["title"] as? String)
                        ?? String(localized: "session \(id.prefix(6))")
                )
            }

            var usage = UsageSnapshot(updatedAt: now)
            usage.windows = usageRows.map { row in
                UsageWindowSnapshot(
                    label: (row["period"] as? String) ?? "?",
                    tokens: row["tokens"] as? Double
                )
            }
            usage.costUSD = usageRows
                .first { ($0["period"] as? String) == "7d" }?["cost_usd"] as? Double

            return ProviderReport(installed: true, sessions: sessions,
                                  startCandidates: startCandidates, usage: usage)
        } catch {
            return ProviderReport(
                installed: true,
                usage: UsageSnapshot(updatedAt: Date(), error: error.localizedDescription)
            )
        }
    }

    // MARK: - Activity history

    private func historyStarts(now: Date) -> [SessionStartCandidate] {
        let cached = lock.withLock { (cachedStarts, startsScannedAt) }
        guard cached.0.isEmpty || now.timeIntervalSince(cached.1) > 30 else {
            return cached.0
        }
        guard let rows = try? query(Self.historySQL) else { return cached.0 }
        let starts = rows.compactMap { row -> SessionStartCandidate? in
            guard let sessionID = row["id"] as? String,
                  let created = row["time_created"] as? Double else { return nil }
            let title = CollectorFiles.contentSnippet(row["title"] as? String)
            let prompt = CollectorFiles.contentSnippet(row["first_prompt"] as? String)
            guard let snippet = title ?? prompt else { return nil }
            return SessionStartCandidate(
                sessionID: sessionID,
                startedAt: Date(timeIntervalSince1970: created / 1_000),
                snippet: snippet,
                snippetSource: title == nil ? "firstPrompt" : "title"
            )
        }
        lock.withLock {
            cachedStarts = starts
            startsScannedAt = now
        }
        return starts
    }

    // MARK: - SQLite (read-only)

    private func query(_ sql: String) throws -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw CollectorError(String(localized: "OpenCode database could not be opened"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CollectorError(String(localized: "OpenCode query failed: \(String(cString: sqlite3_errmsg(db)))"))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER, SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, index))
                default:
                    break   // NULL and BLOB stay absent
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static let sessionsSQL = """
    SELECT
      s.id,
      s.title,
      s.time_updated,
      s.time_archived,
      json_extract(m.data, '$.role') AS role,
      json_extract(m.data, '$.finish') AS finish,
      json_type(m.data, '$.error') AS error_type,
      coalesce(json_extract(m.data, '$.modelID'), json_extract(m.data, '$.model')) AS model_id,
      m.time_created AS message_at
    FROM session s
    LEFT JOIN message m ON m.id = (
      SELECT id FROM message
      WHERE session_id = s.id
      ORDER BY time_created DESC, id DESC
      LIMIT 1
    )
    WHERE s.time_archived IS NULL
    ORDER BY s.time_updated DESC
    LIMIT 50;
    """

    private static let historySQL = """
    SELECT
      s.id,
      s.title,
      s.time_created,
      (
        SELECT json_extract(p.data, '$.text')
        FROM message um
        JOIN part p ON p.message_id = um.id
        WHERE um.session_id = s.id
          AND json_extract(um.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
        ORDER BY um.time_created ASC, p.time_created ASC, p.id ASC
        LIMIT 1
      ) AS first_prompt
    FROM session s
    ORDER BY s.time_created ASC;
    """

    private static let usageSQL = """
    SELECT '24h' AS period,
      coalesce(sum(coalesce(json_extract(data, '$.tokens.total'),
        coalesce(json_extract(data, '$.tokens.input'), 0) +
        coalesce(json_extract(data, '$.tokens.output'), 0) +
        coalesce(json_extract(data, '$.tokens.reasoning'), 0))), 0) AS tokens,
      coalesce(sum(json_extract(data, '$.cost')), 0) AS cost_usd
    FROM message
    WHERE json_extract(data, '$.role') = 'assistant'
      AND time_created >= (strftime('%s', 'now') - 86400) * 1000
    UNION ALL
    SELECT '7d',
      coalesce(sum(coalesce(json_extract(data, '$.tokens.total'),
        coalesce(json_extract(data, '$.tokens.input'), 0) +
        coalesce(json_extract(data, '$.tokens.output'), 0) +
        coalesce(json_extract(data, '$.tokens.reasoning'), 0))), 0),
      coalesce(sum(json_extract(data, '$.cost')), 0)
    FROM message
    WHERE json_extract(data, '$.role') = 'assistant'
      AND time_created >= (strftime('%s', 'now') - 604800) * 1000;
    """
}
