//
//  ClaudeCollector.swift
//  AgInOl
//
//  Claude Code status from ~/.claude/sessions + projects JSONLs, and
//  plan limits from the oauth/usage endpoint using the CLI's own
//  credentials. Ported from neo-agent-deck's claude.ts (MIT).
//

import Foundation
import Security

nonisolated final class ClaudeCollector: AgentCollector, @unchecked Sendable {
    let providerID = "claude"
    let displayName = "CLAUDE"

    private let configDirectory: String
    private let lock = NSLock()

    // Cached between polls (guarded by `lock`).
    private var projectFiles: [FileStamp] = []
    private var projectsScannedAt = Date.distantPast
    private var usage = UsageSnapshot()
    private var usageFetchedAt = Date.distantPast
    private var cachedToken: String?
    private let spendScanner = ClaudeSpendScanner()
    private var spend = SpendSnapshot()
    private var spendScannedAt = Date.distantPast

    init() {
        let env = ProcessInfo.processInfo.environment
        configDirectory = env["CLAUDE_CONFIG_DIR"].map(CollectorFiles.expand)
            ?? CollectorFiles.expand("~/.claude")
    }

    func collect(context: CollectorContext) async -> ProviderReport {
        let sessionsDir = configDirectory + "/sessions"
        guard FileManager.default.fileExists(atPath: configDirectory) else {
            return ProviderReport(installed: false)
        }

        let now = Date()
        lock.lock()
        if projectFiles.isEmpty || now.timeIntervalSince(projectsScannedAt) > 30 {
            projectFiles = CollectorFiles.listJSONL(in: configDirectory + "/projects")
            projectsScannedAt = now
        }
        let projects = projectFiles
        let needsUsage = context.allowNetwork && now.timeIntervalSince(usageFetchedAt) > 300
        if needsUsage { usageFetchedAt = now }
        if !context.allowNetwork {
            // Claude's plan limits only exist server-side; without online
            // access there is nothing to show (and no Keychain access).
            usage = UsageSnapshot(updatedAt: now, error: "online access disabled")
            usageFetchedAt = .distantPast
        }
        lock.unlock()

        if needsUsage {
            await fetchUsage()
        }

        let sessions = readSessions(sessionsDir: sessionsDir, projects: projects, context: context)

        lock.lock()
        let needsSpend = now.timeIntervalSince(spendScannedAt) > 60
        if needsSpend { spendScannedAt = now }
        lock.unlock()
        if needsSpend {
            let result = spendScanner.scan(files: projects)
            lock.lock()
            spend = result
            lock.unlock()
        }

        lock.lock()
        let currentUsage = usage
        let currentSpend = spend
        lock.unlock()
        return ProviderReport(installed: true, sessions: sessions,
                              usage: currentUsage, spend: currentSpend)
    }

    // MARK: - Sessions

    private func readSessions(sessionsDir: String,
                              projects: [FileStamp],
                              context: CollectorContext) -> [SessionSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        // Newest project JSONL per session id.
        var projectsBySession: [String: FileStamp] = [:]
        for file in projects {
            let id = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if let existing = projectsBySession[id], existing.mtime >= file.mtime { continue }
            projectsBySession[id] = file
        }

        var sessions: [SessionSnapshot] = []
        for name in names where name.hasSuffix(".json") {
            let path = sessionsDir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionID = raw["sessionId"] as? String,
                  let pid = raw["pid"] as? Int,
                  CollectorFiles.processAlive(pid: pid) else { continue }

            let project = projectsBySession[sessionID]
            let tail = project.map {
                Self.parseTail(CollectorFiles.readTail($0.path, maxBytes: 768 * 1024), fallback: $0.mtime)
            } ?? Tail()

            let status = ((raw["status"] as? String) ?? "idle").lowercased()
            let updatedAt = (raw["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let statusUpdatedAt = (raw["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let activityAt = [updatedAt, tail.activityAt, project?.mtime]
                .compactMap { $0 }.max() ?? .distantPast
            let key = "claude:\(sessionID)"

            var state = SessionState.idle
            var completionAt: Date?

            // Working when the newest turn hasn't reached a terminal
            // stop_reason yet (covers both "user just asked" and long
            // agentic turns streaming tool_use events), bounded by file
            // recency so an aborted turn decays to idle.
            let latestTurnEvent = max(tail.lastUser, tail.lastAssistant)
            let tailWorking = tail.lastEnd < latestTurnEvent
                && Date().timeIntervalSince(activityAt) < 5 * 60
            let statusAttentionAt = max(statusUpdatedAt ?? .distantPast, activityAt)

            if status.contains(anyOf: ["working", "running", "busy", "processing"]) || tailWorking {
                state = .working
            } else if status.contains(anyOf: ["attention", "waiting", "permission", "blocked", "input"]),
                      !context.isAcknowledged(key, at: statusAttentionAt) {
                state = .attention
                completionAt = statusAttentionAt
            } else if tail.lastEnd > context.attentionSince,
                      !context.isAcknowledged(key, at: tail.lastEnd) {
                state = .attention
                completionAt = tail.lastEnd
            }

            sessions.append(SessionSnapshot(
                key: key, id: sessionID, state: state, isOpen: true,
                activityAt: activityAt, completionAt: completionAt,
                model: tail.lastModel
            ))
        }
        return sessions
    }

    // MARK: - Tail parsing

    struct Tail {
        var lastUser = Date.distantPast
        var lastEnd = Date.distantPast
        var lastAssistant = Date.distantPast
        var activityAt: Date?
        var lastModel: String?
    }

    static func parseTail(_ text: String, fallback: Date) -> Tail {
        var tail = Tail()
        for event in CollectorFiles.jsonLines(text) {
            let at = CollectorFiles.parseTimestamp(event["timestamp"], fallback: fallback)
            tail.activityAt = max(tail.activityAt ?? .distantPast, at)
            let type = event["type"] as? String
            if type == "user", event["toolUseResult"] == nil {
                tail.lastUser = max(tail.lastUser, at)
            }
            if type == "assistant" {
                tail.lastAssistant = max(tail.lastAssistant, at)
                let message = event["message"] as? [String: Any]
                if let model = message?["model"] as? String, !model.isEmpty {
                    tail.lastModel = model
                }
                // Any terminal stop reason ends the turn; tool_use does not.
                if let stop = message?["stop_reason"] as? String, stop != "tool_use" {
                    tail.lastEnd = max(tail.lastEnd, at)
                }
            }
        }
        return tail
    }

    // MARK: - Usage (plan limits)

    private func fetchUsage() async {
        var result = UsageSnapshot(updatedAt: Date())
        do {
            let token = try accessToken()
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.timeoutInterval = 10
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("AgInOl/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 401 || code == 403 { invalidateToken() }
                throw CollectorError("Claude usage HTTP \(code)")
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let limits = (body?["limits"] as? [[String: Any]]) ?? []
            func window(_ label: String, kind: String) -> UsageWindowSnapshot? {
                guard let limit = limits.first(where: { $0["kind"] as? String == kind }) else { return nil }
                let percent = (limit["percent"] as? Double).map { min(max($0 / 100, 0), 1) }
                let resets = (limit["resets_at"] as? String).map {
                    CollectorFiles.parseTimestamp($0, fallback: Date())
                }
                return UsageWindowSnapshot(label: label, percent: percent, resetsAt: resets)
            }
            result.windows = [window("5h", kind: "session"), window("7d", kind: "weekly_all")]
                .compactMap { $0 }
        } catch {
            result.error = error.localizedDescription
            lock.lock()
            result.windows = usage.windows   // keep serving stale data on failure
            lock.unlock()
        }
        lock.lock()
        usage = result
        lock.unlock()
    }

    /// Same resolution order as the Claude Code CLI's other consumers:
    /// env var → macOS Keychain item → ~/.claude/.credentials.json.
    ///
    /// The Keychain read shells out to /usr/bin/security (like
    /// neo-agent-deck) instead of SecItemCopyMatching: the ACL entry then
    /// belongs to that stable system binary, so the user approves once —
    /// a rebuilt debug app would otherwise re-prompt on every build.
    /// The token is cached in memory; a 401 clears the cache.
    private func accessToken() throws -> String {
        lock.lock()
        let cached = cachedToken
        lock.unlock()
        if let cached { return cached }

        var token: String?
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            token = env.trimmingCharacters(in: .whitespaces)
        }
        if token == nil,
           let data = securityCLIPassword(service: "Claude Code-credentials") {
            token = Self.extractToken(from: data)
        }
        if token == nil,
           let data = FileManager.default.contents(atPath: configDirectory + "/.credentials.json") {
            token = Self.extractToken(from: data)
        }
        guard let token else { throw CollectorError("Claude Code OAuth token not found") }
        lock.lock()
        cachedToken = token
        lock.unlock()
        return token
    }

    func invalidateToken() {
        lock.lock()
        cachedToken = nil
        lock.unlock()
    }

    private func securityCLIPassword(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    static func extractToken(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let oauth = obj["claudeAiOauth"] as? [String: Any]
        let token = (oauth?["accessToken"] as? String) ?? (obj["accessToken"] as? String)
        guard let token, !token.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return token.trimmingCharacters(in: .whitespaces)
    }
}

nonisolated struct CollectorError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    func contains(anyOf needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}
