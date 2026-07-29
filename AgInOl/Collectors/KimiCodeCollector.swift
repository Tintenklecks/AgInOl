//
//  KimiCodeCollector.swift
//  AgInOl
//
//  Kimi Code status + token usage from its local session store.
//  Fully offline: reads ~/.kimi-code/session_index.jsonl, state.json
//  and the per-agent wire.jsonl.
//

import Foundation

nonisolated final class KimiCodeCollector: AgentCollector, @unchecked Sendable {
    let providerID = "kimi"
    let displayName = "KIMI"

    /// A session is considered active while it has been touched recently.
    private static let activeWindow: TimeInterval = 90

    private let dataDirectory: String

    init() {
        let env = ProcessInfo.processInfo.environment
        dataDirectory = env["KIMI_CODE_DATA_DIR"].map(CollectorFiles.expand)
            ?? CollectorFiles.expand("~/.kimi-code")
    }

    func collect(context: CollectorContext) async -> ProviderReport {
        let indexPath = dataDirectory + "/session_index.jsonl"
        guard FileManager.default.fileExists(atPath: indexPath) else {
            return ProviderReport(installed: false)
        }

        do {
            let indexURL = URL(fileURLWithPath: indexPath)
            let indexData = try Data(contentsOf: indexURL, options: .mappedIfSafe)
            guard let indexText = String(data: indexData, encoding: .utf8) else {
                return ProviderReport(installed: true,
                                      usage: UsageSnapshot(updatedAt: Date(),
                                                           error: String(localized: "bad session index encoding")))
            }

            let sessionEntries = indexText
                .split(separator: "\n")
                .compactMap { line -> [String: Any]? in
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
                    return obj as? [String: Any]
                }

            let now = Date()
            var sessions: [SessionSnapshot] = []
            var totalTokens24h: Double = 0
            var totalTokens7d: Double = 0

            for entry in sessionEntries {
                guard let sessionDir = entry["sessionDir"] as? String,
                      let sessionID = entry["sessionId"] as? String else { continue }

                let stateURL = URL(fileURLWithPath: sessionDir + "/state.json")
                let state: [String: Any]
                if let data = try? Data(contentsOf: stateURL, options: .mappedIfSafe),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let dict = obj as? [String: Any] {
                    state = dict
                } else {
                    state = [:]
                }

                let updatedAt = CollectorFiles.parseTimestamp(state["updatedAt"], fallback: .distantPast)
                let recent = now.timeIntervalSince(updatedAt) < Self.activeWindow
                let key = "kimi:\(sessionID)"

                sessions.append(SessionSnapshot(
                    key: key,
                    id: sessionID,
                    state: recent ? .working : .idle,
                    isOpen: true,
                    activityAt: updatedAt,
                    completionAt: nil,
                    model: modelHint(from: state),
                    title: sessionTitle(from: state, sessionID: sessionID)
                ))

                let wirePath = sessionDir + "/agents/main/wire.jsonl"
                let (t24, t7) = tokenTotals(from: wirePath, now: now)
                totalTokens24h += t24
                totalTokens7d += t7
            }

            var usage = UsageSnapshot(updatedAt: now)
            usage.windows = [
                UsageWindowSnapshot(label: "24h", tokens: totalTokens24h),
                UsageWindowSnapshot(label: "7d", tokens: totalTokens7d),
            ]

            return ProviderReport(installed: true, sessions: sessions, usage: usage)
        } catch {
            return ProviderReport(installed: true,
                                  usage: UsageSnapshot(updatedAt: Date(),
                                                       error: error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private func modelHint(from state: [String: Any]) -> String? {
        // Prefer the custom title, fall back to the last prompt text.
        if let title = state["title"] as? String, !title.isEmpty {
            return title
        }
        if let prompt = state["lastPrompt"] as? String, !prompt.isEmpty {
            return String(prompt.prefix(40))
        }
        return nil
    }

    /// Session label: Kimi's own title, else the last prompt, else the
    /// work directory it was started in. Kimi writes "New Session" until
    /// a session has a real name, which `shortTitle` filters out.
    private func sessionTitle(from state: [String: Any], sessionID: String) -> String {
        if let title = CollectorFiles.shortTitle(state["title"] as? String) {
            return title
        }
        if let prompt = CollectorFiles.shortTitle(state["lastPrompt"] as? String) {
            return prompt
        }
        if let dir = state["workDir"] as? String, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        return "session \(sessionID.prefix(6))"
    }

    private func tokenTotals(from path: String, now: Date) -> (Double, Double) {
        let text = CollectorFiles.readTail(path, maxBytes: 4 * 1024 * 1024)
        let lines = CollectorFiles.jsonLines(text)

        let cutoff24h = now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
        let cutoff7d = now.addingTimeInterval(-7 * 86400).timeIntervalSince1970 * 1000

        var total24h: Double = 0
        var total7d: Double = 0

        for event in lines {
            guard event["type"] as? String == "usage.record" else { continue }
            guard let time = event["time"] as? Double else { continue }
            guard let usage = event["usage"] as? [String: Any] else { continue }

            let tokens = (usage["inputOther"] as? Double ?? 0)
                + (usage["output"] as? Double ?? 0)
                + (usage["inputCacheRead"] as? Double ?? 0)
                + (usage["inputCacheCreation"] as? Double ?? 0)

            if time >= cutoff24h {
                total24h += tokens
            }
            if time >= cutoff7d {
                total7d += tokens
            }
        }

        return (total24h, total7d)
    }
}
