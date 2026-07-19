//
//  ClaudeSpendScanner.swift
//  AgInOl
//
//  Fully-offline token/cost estimation for Claude Code from the local
//  project JSONLs (~/.claude/projects/**/*.jsonl). Ports the semantics
//  of openusage's ClaudeLogUsageScanner / ccusage: a usage line is an
//  assistant event carrying message.usage; dedupe on message.id +
//  requestId; cost = line's costUSD when present, else tokens priced
//  by model. Per-file aggregates are cached by (size, mtime) and
//  bucketed per hour so rolling 24h/7d windows stay cheap.
//

import Foundation

nonisolated struct SpendSnapshot: Sendable {
    var tokens24h: Double = 0
    var cost24h: Double = 0
    var tokens7d: Double = 0
    var cost7d: Double = 0
    var updatedAt: Date?
}

nonisolated final class ClaudeSpendScanner: @unchecked Sendable {

    private struct HourBucket {
        var tokens: Double = 0
        var cost: Double = 0
    }

    private struct FileAggregate {
        var size: Int
        var mtime: Date
        var buckets: [Int: HourBucket]   // epoch-hour → totals
    }

    private let lock = NSLock()
    private var cache: [String: FileAggregate] = [:]

    func scan(files: [FileStamp]) -> SpendSnapshot {
        let now = Date()
        let cutoff7d = now.addingTimeInterval(-7 * 86_400)
        let cutoff24h = now.addingTimeInterval(-86_400)

        var snapshot = SpendSnapshot(updatedAt: now)
        var livePaths = Set<String>()

        for file in files where file.mtime > cutoff7d {
            livePaths.insert(file.path)
            let aggregate = self.aggregate(for: file)
            for (hour, bucket) in aggregate.buckets {
                let bucketDate = Date(timeIntervalSince1970: Double(hour) * 3600)
                guard bucketDate > cutoff7d else { continue }
                snapshot.tokens7d += bucket.tokens
                snapshot.cost7d += bucket.cost
                if bucketDate > cutoff24h {
                    snapshot.tokens24h += bucket.tokens
                    snapshot.cost24h += bucket.cost
                }
            }
        }

        lock.withLock {
            cache = cache.filter { livePaths.contains($0.key) }
        }
        return snapshot
    }

    private func aggregate(for file: FileStamp) -> FileAggregate {
        let cached = lock.withLock { cache[file.path] }
        if let cached, cached.size == file.size, cached.mtime == file.mtime {
            return cached
        }

        var buckets: [Int: HourBucket] = [:]
        var seen = Set<String>()

        if let handle = FileHandle(forReadingAtPath: file.path),
           let data = try? handle.readToEnd() {
            try? handle.close()
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                // Fast prefilter before paying for JSON parsing.
                guard line.contains("\"usage\"") else { continue }
                guard let lineData = line.data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                      event["type"] as? String == "assistant",
                      let message = event["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                // ccusage dedupe: identical message replayed across lines.
                if let messageID = message["id"] as? String {
                    let key = messageID + ":" + ((event["requestId"] as? String) ?? "")
                    if !seen.insert(key).inserted { continue }
                }

                let at = CollectorFiles.parseTimestamp(event["timestamp"], fallback: file.mtime)
                let input = (usage["input_tokens"] as? Double) ?? 0
                let output = (usage["output_tokens"] as? Double) ?? 0
                let cacheWrite = (usage["cache_creation_input_tokens"] as? Double) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Double) ?? 0

                let cost = (event["costUSD"] as? Double) ?? Self.price(
                    model: (message["model"] as? String) ?? "",
                    input: input, output: output,
                    cacheWrite: cacheWrite, cacheRead: cacheRead
                )

                let hour = Int(at.timeIntervalSince1970 / 3600)
                buckets[hour, default: HourBucket()].tokens += input + output + cacheWrite + cacheRead
                buckets[hour, default: HourBucket()].cost += cost
            }
        }

        let aggregate = FileAggregate(size: file.size, mtime: file.mtime, buckets: buckets)
        lock.withLock {
            cache[file.path] = aggregate
        }
        return aggregate
    }

    // MARK: - Pricing (USD per million tokens; cache write 1.25x input,
    // cache read 0.1x input)

    static func price(model: String, input: Double, output: Double,
                      cacheWrite: Double, cacheRead: Double) -> Double {
        let (inRate, outRate) = rates(for: model)
        return (input * inRate
            + output * outRate
            + cacheWrite * inRate * 1.25
            + cacheRead * inRate * 0.1) / 1_000_000
    }

    static func rates(for model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus-4-5") || m.contains("opus-4-6")
            || m.contains("opus-4-7") || m.contains("opus-4-8") { return (5, 25) }
        if m.contains("opus") { return (15, 75) }          // Opus 4.1 and older
        if m.contains("sonnet") { return (3, 15) }
        if m.contains("haiku-3-5") { return (0.8, 4) }
        if m.contains("haiku") { return (1, 5) }
        return (5, 25)                                      // unknown → Opus-tier
    }
}
