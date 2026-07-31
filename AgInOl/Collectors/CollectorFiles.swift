//
//  CollectorFiles.swift
//  AgInOl
//
//  File helpers shared by the collectors: recursive .jsonl listing with
//  stamps, bounded tail reads, and lenient JSON parsing.
//

import Foundation

nonisolated struct FileStamp: Sendable {
    var path: String
    var mtime: Date
    var size: Int
}

nonisolated enum CollectorFiles {

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// All *.jsonl under `directory`, recursively.
    static func listJSONL(in directory: String) -> [FileStamp] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var stamps: [FileStamp] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            stamps.append(FileStamp(
                path: url.path,
                mtime: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0
            ))
        }
        return stamps
    }

    /// Last `maxBytes` of a file as UTF-8 text (lossy at the cut).
    static func readTail(_ path: String, maxBytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// First `maxBytes` of a file. Session headers and initial prompts live
    /// near the front, so history discovery never needs to load whole logs.
    static func readHead(_ path: String, maxBytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse one JSONL blob into dictionaries, skipping bad lines.
    static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return obj as? [String: Any]
        }
    }

    static func parseTimestamp(_ value: Any?, fallback: Date) -> Date {
        guard let string = value as? String else { return fallback }
        return isoParser.date(from: string) ?? isoFractional.date(from: string) ?? fallback
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// First UUID embedded in a filename, e.g. Codex rollout files.
    static func extractUUID(from path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range]).lowercased()
    }

    /// A log-derived session title trimmed to one readable line, or nil
    /// when there is nothing worth showing. Providers that title a
    /// session from its first prompt can hand over whole sentences.
    static func shortTitle(_ text: String?, limit: Int = 60) -> String? {
        let clean = (text ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        // Placeholders the CLIs write before a session has a real name.
        guard !["new session", "untitled", "untitled session"].contains(clean.lowercased()) else {
            return nil
        }
        guard clean.count > limit else { return clean }
        return clean.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A compact memory cue suitable for permanent local history. Common
    /// CLI-injected XML context blocks are removed before whitespace folding.
    static func contentSnippet(_ text: String?, limit: Int = 160) -> String? {
        var clean = text ?? ""
        for tag in ["system-reminder", "environment_context", "recommended_plugins"] {
            clean = clean.replacingOccurrences(
                of: "<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        clean = clean
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard !["new session", "untitled", "untitled session"]
            .contains(clean.lowercased()) else { return nil }
        guard clean.count > limit else { return clean }
        return clean.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Text carried either directly or in the content arrays used by Claude,
    /// Codex and Kimi. Non-text attachments are intentionally ignored.
    static func textContent(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            return (object["text"] as? String) ?? (object["content"] as? String)
        }
        guard let items = value as? [Any] else { return nil }
        let parts = items.compactMap { item -> String? in
            guard let object = item as? [String: Any] else { return item as? String }
            let type = object["type"] as? String
            guard type == nil || type == "text" || type == "input_text" else { return nil }
            return (object["text"] as? String) ?? (object["content"] as? String)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func processAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
