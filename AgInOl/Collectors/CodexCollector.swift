//
//  CodexCollector.swift
//  AgInOl
//
//  Codex status + rate limits from ~/.codex/sessions rollout JSONLs.
//  Ported from neo-agent-deck's codex.ts (MIT).
//

import Foundation

nonisolated final class CodexCollector: AgentCollector, @unchecked Sendable {
    let providerID = "codex"
    let displayName = "CODEX"

    /// A crashed session leaves task_started as its final event forever;
    /// bound "working" by file recency so dead sessions decay to idle.
    private static let workingWindow: TimeInterval = 10 * 60

    private let sessionsDirectory: String
    private let authFilePath: String
    private let lock = NSLock()
    private var files: [FileStamp] = []
    private var scannedAt = Date.distantPast
    private var tailCache: [String: (size: Int, mtime: Date, info: Tail)] = [:]
    private var usage = UsageSnapshot()
    private var liveUsage: UsageSnapshot?
    private var liveFetchedAt = Date.distantPast
    private var startCache: [String: (size: Int, candidate: SessionStartCandidate?)] = [:]

    init() {
        let env = ProcessInfo.processInfo.environment
        let home = env["CODEX_HOME"].map(CollectorFiles.expand) ?? CollectorFiles.expand("~/.codex")
        sessionsDirectory = home + "/sessions"
        authFilePath = home + "/auth.json"
    }

    func collect(context: CollectorContext) async -> ProviderReport {
        guard FileManager.default.fileExists(atPath: sessionsDirectory) else {
            return ProviderReport(installed: false)
        }

        let now = Date()
        let allFiles = lock.withLock {
            if files.isEmpty || now.timeIntervalSince(scannedAt) > 30 {
                files = CollectorFiles.listJSONL(in: sessionsDirectory)
                scannedAt = now
            }
            return files
        }
        let recent = allFiles.sorted { $0.mtime > $1.mtime }.prefix(40)
        let startCandidates = historyStarts(from: allFiles)

        var sessions: [SessionSnapshot] = []
        var rateLimits: [String: Any]?
        for file in recent {
            guard let id = CollectorFiles.extractUUID(from: file.path) else { continue }
            let info = tailInfo(for: file)
            let key = "codex:\(id)"

            var state = SessionState.idle
            var completionAt: Date?
            switch info.life {
            case "task_started" where now.timeIntervalSince(file.mtime) < Self.workingWindow:
                state = .working
            case "task_complete", "turn_aborted":
                if info.lifeAt > context.attentionSince, !context.isAcknowledged(key, at: info.lifeAt) {
                    state = .attention
                    completionAt = info.lifeAt
                }
            default:
                break
            }

            sessions.append(SessionSnapshot(
                key: key, id: id, state: state, isOpen: state != .idle,
                activityAt: file.mtime, completionAt: completionAt,
                model: info.model,
                title: info.cwd.map { ($0 as NSString).lastPathComponent }
                    ?? String(localized: "session \(id.prefix(6))")
            ))
            if rateLimits == nil, let limits = info.rateLimits { rateLimits = limits }
        }

        let needsLive = lock.withLock {
            if let rateLimits {
                usage = Self.usageFrom(rateLimits: rateLimits)
            } else if usage.updatedAt == nil {
                usage = UsageSnapshot(updatedAt: now, error: String(localized: "No Codex usage event found"))
            }
            let needsLive = context.allowNetwork && now.timeIntervalSince(liveFetchedAt) > 300
            if needsLive { liveFetchedAt = now }
            if !context.allowNetwork { liveUsage = nil }   // fall back to local logs
            return needsLive
        }

        if needsLive {
            await fetchLiveUsage()
        }

        // Live endpoint data beats point-in-time log data (logs freeze at
        // the last local Codex session and miss usage from other surfaces).
        let currentUsage = lock.withLock { liveUsage ?? usage }

        return ProviderReport(installed: true, sessions: sessions,
                              startCandidates: startCandidates, usage: currentUsage)
    }

    // MARK: - Activity history

    private func historyStarts(from files: [FileStamp]) -> [SessionStartCandidate] {
        files.compactMap { file in
            if let cached = lock.withLock({ startCache[file.path] }),
               cached.candidate != nil || cached.size == file.size {
                return cached.candidate
            }
            guard let sessionID = CollectorFiles.extractUUID(from: file.path) else { return nil }
            let candidate = Self.parseStart(
                CollectorFiles.readHead(file.path, maxBytes: 1024 * 1024),
                sessionID: sessionID,
                fallback: file.mtime
            )
            lock.withLock {
                startCache[file.path] = (file.size, candidate)
                if startCache.count > 4_096 { startCache.removeAll() }
            }
            return candidate
        }
    }

    static func parseStart(_ text: String, sessionID: String,
                           fallback: Date) -> SessionStartCandidate? {
        var startedAt: Date?
        for event in CollectorFiles.jsonLines(text) {
            if event["type"] as? String == "session_meta",
               let payload = event["payload"] as? [String: Any] {
                startedAt = CollectorFiles.parseTimestamp(
                    payload["timestamp"] ?? event["timestamp"],
                    fallback: fallback
                )
            }
            guard event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let snippet = CollectorFiles.contentSnippet(
                    CollectorFiles.textContent(payload["message"])
                  ) else { continue }
            return SessionStartCandidate(
                sessionID: sessionID,
                startedAt: startedAt ?? CollectorFiles.parseTimestamp(
                    event["timestamp"], fallback: fallback
                ),
                snippet: snippet,
                snippetSource: "firstPrompt"
            )
        }
        return nil
    }

    // MARK: - Tail parsing

    struct Tail {
        var life: String?
        var lifeAt = Date.distantPast
        var rateLimits: [String: Any]?
        var model: String?
        /// Working directory from the rollout's session_meta header.
        var cwd: String?
    }

    private func tailInfo(for file: FileStamp) -> Tail {
        let cached = lock.withLock { tailCache[file.path] }
        if let cached, cached.size == file.size, cached.mtime == file.mtime {
            return cached.info
        }

        var info = Self.parseTail(
            CollectorFiles.readTail(file.path, maxBytes: 1024 * 1024),
            fallback: file.mtime
        )
        // Growing file: carry forward what scrolled out of the tail window.
        if let cached, file.size >= cached.size {
            if info.life == nil {
                info.life = cached.info.life
                info.lifeAt = cached.info.lifeAt
            }
            if info.rateLimits == nil { info.rateLimits = cached.info.rateLimits }
            if info.model == nil { info.model = cached.info.model }
            if info.cwd == nil { info.cwd = cached.info.cwd }
        }
        lock.withLock {
            tailCache[file.path] = (file.size, file.mtime, info)
            if tailCache.count > 128 { tailCache.removeAll() }
        }
        return info
    }

    static func parseTail(_ text: String, fallback: Date) -> Tail {
        var tail = Tail()
        for event in CollectorFiles.jsonLines(text) {
            // Model rides on several event shapes (turn_context, session
            // meta) — take it from any payload that carries one.
            if let anyPayload = event["payload"] as? [String: Any],
               let model = anyPayload["model"] as? String, !model.isEmpty {
                tail.model = model
            }
            if event["type"] as? String == "session_meta",
               let payload = event["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                tail.cwd = cwd
            }
            guard event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if type == "task_started" || type == "task_complete" || type == "turn_aborted" {
                tail.life = type
                tail.lifeAt = CollectorFiles.parseTimestamp(event["timestamp"], fallback: fallback)
            }
            if type == "token_count", let limits = payload["rate_limits"] as? [String: Any] {
                tail.rateLimits = limits
            }
        }
        return tail
    }

    // MARK: - Usage from logs (fallback)

    static func usageFrom(rateLimits: [String: Any]) -> UsageSnapshot {
        var windows: [UsageWindowSnapshot] = []
        for slot in ["primary", "secondary"] {
            guard let window = rateLimits[slot] as? [String: Any] else { continue }
            let minutes = window["window_minutes"] as? Double
            let percent = (window["used_percent"] as? Double).map { min(max($0 / 100, 0), 1) }
            let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            windows.append(UsageWindowSnapshot(
                label: label(minutes: minutes),
                percent: percent,
                resetsAt: resets,
                periodSeconds: minutes.map { $0 * 60 }
            ))
        }
        return UsageSnapshot(windows: windows, updatedAt: Date())
    }

    // MARK: - Live usage (chatgpt.com wham endpoint)

    /// Same call OpenUsage makes, but v1 deliberately never touches the
    /// refresh token: OpenAI rotates refresh tokens, and consuming the
    /// CLI's one from a second app can log the CLI out. If the access
    /// token is expired we simply keep the log-derived numbers until the
    /// user runs codex again (which refreshes auth.json).
    private func fetchLiveUsage() async {
        guard let auth = FileManager.default.contents(atPath: authFilePath),
              let root = (try? JSONSerialization.jsonObject(with: auth)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else { return }

        if let expiry = Self.jwtExpiry(accessToken), expiry < Date() { return }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgInOl/0.1", forHTTPHeaderField: "User-Agent")
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimit = body["rate_limit"] as? [String: Any]
        else { return }

        var windows: [UsageWindowSnapshot] = []
        for slot in ["primary_window", "secondary_window"] {
            guard let window = rateLimit[slot] as? [String: Any] else { continue }
            let seconds = window["limit_window_seconds"] as? Double
            let percent = (window["used_percent"] as? Double).map { min(max($0 / 100, 0), 1) }
            let resets = (window["reset_after_seconds"] as? Double).map { Date().addingTimeInterval($0) }
            windows.append(UsageWindowSnapshot(
                label: Self.label(minutes: seconds.map { $0 / 60 }),
                percent: percent,
                resetsAt: resets,
                periodSeconds: seconds
            ))
        }
        guard !windows.isEmpty else { return }

        lock.withLock { liveUsage = UsageSnapshot(windows: windows, updatedAt: Date()) }
    }

    /// exp claim of a JWT, or nil if unreadable.
    static func jwtExpiry(_ jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func label(minutes: Double?) -> String {
        guard let minutes, minutes.isFinite else { return String(localized: "limit") }
        let value = Int(minutes)
        if value % 10_080 == 0 { return "\(value / 10_080)w" }
        if value % 1_440 == 0 { return "\(value / 1_440)d" }
        if value % 60 == 0 { return "\(value / 60)h" }
        return "\(value)m"
    }
}
