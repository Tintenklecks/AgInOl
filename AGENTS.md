# AGENTS.md — AgInOl

## Project Overview

AgInOl (**A**gent **In**formation system **Ol**verlay) is a macOS menu-bar app that shows a floating, hardware-style status deck for AI coding agents. It renders a Stream Deck-like bezel with eight colored key tiles plus a small info bar, and reports live status and token usage for:

- Claude Code (`~/.claude`)
- Codex / ChatGPT (`~/.codex`)
- OpenCode (`~/.local/share/opencode`)
- Kimi Code (`~/.kimi-code`)

The panel is borderless, non-activating, and floats above other windows. Double-click tucks it to the screen edge; clicking the visible sliver brings it back.

## Tech Stack

- **Language:** Swift 5.9+ (Swift 6 compatible concurrency)
- **UI:** SwiftUI + AppKit (`NSPanel`, `NSHostingView`)
- **Concurrency:** Swift structured concurrency (`async/await`, `@MainActor`, `nonisolated`)
- **Data:** Local files only — JSONL session logs, SQLite, Keychain (optional)
- **Build:** Xcode 26.6+, macOS 26.5+ deployment target

## Project Structure

```
AgInOl/
├── AgInOl/
│   ├── AgInOlApp.swift          # App entry point; owns the floating DeckPanel
│   ├── PanelController.swift    # Tuck/untuck animation logic
│   ├── DeckModel.swift          # @Observable state, KeyAssignment enum, demo data
│   ├── DeckView.swift           # All SwiftUI views (keys, info bar, pickers, settings)
│   ├── CollectorHub.swift       # Polls collectors every 3s; maps reports into DeckModel
│   ├── AppSettings.swift        # UserDefaults-backed settings (online access toggle)
│   └── Collectors/
│       ├── CollectorTypes.swift # AgentCollector protocol, snapshots, shared types
│       ├── CollectorFiles.swift # File helpers (JSONL listing, tail reads, timestamps)
│       ├── ClaudeCollector.swift    # Claude status + plan limits + token spend
│       ├── ClaudeSpendScanner.swift # Offline token/cost estimation from Claude JSONLs
│       ├── CodexCollector.swift     # Codex status + rate limits + live usage endpoint
│       ├── OpenCodeCollector.swift  # OpenCode status + usage from SQLite
│       └── KimiCodeCollector.swift  # Kimi Code status + usage from wire.jsonl
├── AgInOlTests/                 # Unit tests (Swift Testing)
├── AgInOlUITests/               # UI tests
└── AgInOl.xcodeproj/
```

## Key Architecture

### Collectors

Each provider has a collector conforming to `AgentCollector`:

```swift
nonisolated protocol AgentCollector: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    func collect(context: CollectorContext) async -> ProviderReport
}
```

`CollectorHub` instantiates them, calls `collect(context:)` every 3 seconds, and merges the results into `DeckModel.agents` and `DeckModel.usage`.

### Session States

- **WORKING** — active assistant turn or recent activity
- **NEED YOU** — turn ended and user hasn't acknowledged it
- **IDLE** — session open but not active
- **NOT FOUND** — provider not installed

### Usage Tiles

- **Percent** — plan-limit style (Claude, Codex live)
- **Tokens** — token-count style (OpenCode, Kimi, Claude spend estimate)

## Build & Test

```bash
# Build
xcodebuild -project AgInOl.xcodeproj -scheme AgInOl \
  -destination 'platform=macOS' build

# Run tests (unit tests only; UI tests need automation permission)
xcodebuild -project AgInOl.xcodeproj -scheme AgInOl \
  -destination 'platform=macOS' test
```

Note: UI tests currently fail with "Timed out while enabling automation mode" unless Xcode automation is enabled in System Settings.

## Coding Conventions

- **Concurrency:** Use `nonisolated` for pure helpers and file-scanning code. Use `lock.withLock { ... }` instead of manual `lock.lock()` / `lock.unlock()` (Swift 6 requires async-safe scoped locking).
- **State:** `DeckModel` is `@Observable`; `AppSettings` uses `didSet` → `UserDefaults`.
- **File access:** Everything reads from user home directories (`~/.claude`, `~/.codex`, etc.). No network calls unless `AppSettings.shared.onlineAccess` is true.
- **Key assignments:** Persisted as `KeyAssignment.rawValue` array in UserDefaults.

## Adding a New Provider

1. Create `AgInOl/Collectors/<Name>Collector.swift` conforming to `AgentCollector`.
2. Register it in `CollectorHub.swift` (`collectors` array).
3. Add `KeyAssignment` cases in `DeckModel.swift` (`<name>Status`, `<name>Usage`).
4. Add tint/tile colors in `DeckColor` and map them in `CollectorHub.usageTile()`.
5. Wire the new cases into `DeckView.swift` (`keyBackground`, `keyContent`, `keyAction`, `pickerProviders`).
6. Update `DeckModel.initial()` and `DeckModel.demo()` with placeholder entries.

## Data Sources by Provider

| Provider | Status Source | Usage Source |
|----------|---------------|--------------|
| Claude | `~/.claude/sessions/*.json` + `projects/**/*.jsonl` | Anthropic oauth/usage endpoint (online) + local JSONL spend estimate (offline) |
| Codex | `~/.codex/sessions/**/*.jsonl` | Local rate-limit events + ChatGPT wham endpoint (online) |
| OpenCode | `~/.local/share/opencode/opencode.db` | Same SQLite DB |
| Kimi Code | `~/.kimi-code/session_index.jsonl` + `state.json` | `agents/main/wire.jsonl` `usage.record` events |

## Git History

- `624e559` — Initial Commit
- `89317df` — Phase 1 shell: floating Stream Deck replica with demo data
- `3edbdfa` — Replace trademarked bezel label with AGINOL; add permission allowlist
- `427c7f7` — Phase 2 live collectors, online-access toggle, configurable keys
- `3db1bb5` — (uncommitted/latest work: Kimi Code provider, Swift 6 concurrency fixes)
