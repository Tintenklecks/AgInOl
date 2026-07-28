# Project Description

## App Name

**AgInOl** — *Agent Information Overlay*

The bezel of the macOS deck is labelled `AGINOL`, and the footer reads
"AGINOL · Agentic Information Overlay". The iOS target is named
**AgInOl Companion**.

Note: `AGENTS.md` expands the name as "**Ag**ent **In**formation system
**Ol**verlay", while the on-screen footer says "Agentic Information
Overlay". The two do not agree — see *Uncertain or Needs Verification*.

## Supported Platforms

| Target | Platform | Deployment target | Devices |
|---|---|---|---|
| AgInOl | macOS | 26.5 | Mac (menu-bar app, `LSUIElement = YES`) |
| AgInOl Companion | iOS / iPadOS | 26.5 | iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`) |

Both targets are at `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 2`.

The Mac app has no Dock icon and no main window; it lives in the menu bar
and manages a floating panel. The iPhone build supports portrait and both
landscape orientations; iPad adds upside-down portrait.

## Core Purpose

Show, at a glance and without switching windows, what every supported AI
coding agent on the user's Mac is doing right now, whether any agent is
waiting for input, and how much of each provider's usage allowance has been
consumed.

The Mac app reads the agents' on-disk session logs and renders them as a
hardware-style deck that floats above other windows. It also publishes a
read-only snapshot through iCloud. The iPhone and iPad companion mirrors that
snapshot, so the same status is available beside the Mac, elsewhere in the
building, or hundreds of kilometres away.

## User Pain Point

Someone running several coding agents at once (Claude Code, Codex,
OpenCode, Kimi Code) has no single place to see:

- which agent is mid-turn versus finished and waiting for a reply,
- how long the current turn has been running,
- how much of each provider's rate-limit window is already spent.

Answering those questions otherwise means cycling through terminal
windows, and an agent that finished and is silently waiting can go
unnoticed for a long time. Usage limits are worse: they are only visible
inside each vendor's own tooling, if at all.

## Main User Benefit

One clear answer to "is anything working or waiting for me?" and "how much
budget is left?" for every supported agent at once. On the Mac, the answer is
always visible without interrupting work. On iPhone or iPad, it remains
available from anywhere with internet access — whether the user is close to
the Mac or 500 km away.

## Feature Overview

- Floating, borderless, non-activating deck panel that stays above other
  windows and never steals keyboard focus.
- Live status for four providers: Claude Code, Codex, OpenCode, Kimi Code.
- Four session states per provider: WORKING, NEED YOU, IDLE, NOT FOUND.
- Elapsed-time readout for the active turn.
- Usage tiles in two forms: percent-of-plan-window and token counts
  (with cost where the provider reports it).
- Tap a NEED YOU tile to acknowledge it and silence that alert.
- Configurable key grid, from 2×1 up to 6×4.
- Per-key assignment picker — each key can show any provider metric,
  an all-agents summary, a clock, or the info pages.
- Auto-advancing info bar carousel with per-agent and per-metric detail.
- Menu-bar item to show and hide the deck.
- Double-click to tuck the panel to the screen edge; click the sliver to
  bring it back.
- Vendor usage endpoints are off by default; an explicit opt-in enables them.
  iCloud deck mirroring is a separate sync path and remains active.
- Read-only iPhone/iPad companion that shows Mac agent status over iCloud from
  nearby or far away, with an always-visible data-age indicator.

## Detailed Feature Discussion

### The deck panel (macOS)

`AgInOlApp.swift` hosts a `DeckPanel` (`NSPanel`, borderless and
`.nonactivatingPanel`) that overrides `canBecomeKey` and `canBecomeMain`
to return `false`. Clicking the deck never pulls focus from the terminal
running the agents. The panel is `.floating` level with
`[.canJoinAllSpaces, .fullScreenAuxiliary]`, so it follows the user across
Spaces and stays visible over full-screen apps. Its frame is autosaved
under `DeckPanel` and re-clamped on screen if it would otherwise open
off-screen.

`PanelController` owns sizing and the tuck animation (`toggleTuck`,
`tuck`, `untuck`, `resizeToFit`, `clampToScreen`). Window size is
recalculated when the grid dimensions change.

### Status collection

`CollectorHub` polls all collectors every 3 seconds off the main actor and
maps the results into the `@Observable` `DeckModel`. Each provider
implements the `AgentCollector` protocol.

Status derivation, per provider:

- **NOT FOUND** — the provider's directory does not exist.
- **WORKING** — a session has an active assistant turn.
- **NEED YOU** — a turn ended and the user has not acknowledged it.
- **IDLE** — a session is open but not active.

Acknowledgements are stored in `UserDefaults` under
`CollectorAcknowledged` and pruned to the last 14 days.

### Data sources

| Provider | Status source | Usage source |
|---|---|---|
| Claude Code | `~/.claude/sessions/*.json`, `projects/**/*.jsonl` | Anthropic usage endpoint (online) or local JSONL spend estimate (offline) |
| Codex | `~/.codex/sessions/**/*.jsonl` | Local rate-limit events, plus a ChatGPT endpoint (online) |
| OpenCode | `~/.local/share/opencode/opencode.db` | The same SQLite database |
| Kimi Code | `~/.kimi-code/session_index.jsonl`, `state.json` | `agents/main/wire.jsonl` `usage.record` events |

### Usage tiles

Two kinds, plus an unavailable state:

- **Percent** — fraction of a plan window used, with a progress bar
  (Claude 7d and 5h; Codex weekly and session).
- **Tokens** — a token count, with cost where the provider reports one.
  Where no cost is reported the tile says "7d tokens" rather than
  printing `$0.00`.
- **Unavailable** — captions distinguish "not installed", "loading",
  "no data" and "online off".

Claude additionally has a spend tile combining a 7-day token count and
cost with a 24-hour cost detail line.

### Configurable grid and keys

`AppSettings` persists grid columns (2–6) and rows (1–4) — 4×2 by default,
mirroring the Stream Deck Neo layout. Long-pressing a key opens a picker
to reassign it. `KeyAssignment` covers per-provider status, percent used,
percent left, session-window variants, token/spend tiles, an all-agents
summary, a clock, the info pages, and an empty spacer. Assignments persist
as raw strings in `UserDefaults` under `KeyAssignments`.

### Info bar

An optional carousel below the keys (`showInfoBar`, hidden automatically
below 3 columns) that advances every 4 seconds through a summary page,
one page per agent, and one page per usage metric.

### Privacy and network posture

`AppSettings.onlineAccess` defaults to **off**. With it off, collectors read
files under the user's home directory and make no network calls to AI vendors;
no Keychain prompt appears. Turning it on lets collectors call vendor usage
endpoints using credentials the CLIs have already stored.

That toggle does not disable companion sync. The Mac app publishes the reduced
deck snapshot to iCloud key-value storage independently, so "online access off"
means "vendor lookups off", not "all network traffic off".

The macOS target is built with `ENABLE_APP_SANDBOX = NO`, which is what
allows it to read the agent directories.

### iOS companion and Mac↔iOS mirroring

The Mac app is the single source of truth. `CollectorHub` flattens each
poll into a `DeckSnapshot` — a versioned, Codable, SwiftUI-free wire
format — and hands it to a transport behind the `DeckSyncPublishing`
protocol. The shipped transport, `KVSDeckSyncService`, writes a JSON blob
to `NSUbiquitousKeyValueStore`.

Because iCloud key-value storage coalesces and throttles rapid writes, the
transport drops unchanged payloads and enforces a 30-second minimum
interval, holding the newest snapshot and flushing when the window closes.
Realistic freshness on the phone is seconds to minutes, so the companion
keeps a data-age indicator on screen at all times and turns it amber past
five minutes.

The two apps ship under **different bundle IDs** (`de.IBMobile.AgInOl` and
`de.IBMobile.AgInOl-Companion`) but share one key-value store by both
declaring the Mac's identifier in
`com.apple.developer.ubiquity-kvstore-identifier`. Key-value storage is
scoped to the team, not the bundle ID.

The companion is read-only and renders its own adaptive grid rather than
copying the fixed key layout: an all-agents summary tile, one tile per
agent, and one per usage metric.

### Required setup and distribution

The iOS app is a companion, not a standalone agent monitor. It cannot inspect
coding-agent files on an iPhone or iPad and has no useful state until the Mac
app publishes a snapshot. Before the iOS app can work, the user must:

1. Download the notarized AgInOl Mac app directly from `https://aiia.li`.
2. Install and run AgInOl on the Mac where the supported coding agents run.
3. Sign in to iCloud on the Mac and the iPhone or iPad with the **same Apple
   Account**, with iCloud enabled for both apps.
4. Keep the Mac app running and the Mac online while current status is needed
   remotely.

The iOS device does not need to be on the same Wi-Fi or local network as the
Mac. Distance is not the constraint: iCloud and internet availability are. A
user can check from next to the Mac or 500 km away. Delivery is not instant in
all conditions; iCloud key-value updates can take seconds to minutes, and the
companion displays the snapshot age so the user can judge freshness.

Per the product owner's distribution plan, the iOS/iPadOS companion is intended
for the Apple App Store. The macOS app is intended as a separately installed,
notarized direct download from `aiia.li`, outside the Mac App Store.

## Target Users

- Developers running two or more AI coding agents concurrently.
- Users on metered or rate-limited plans who need to see remaining
  allowance before starting expensive work.
- People who leave long agent turns running and want to notice
  immediately when one finishes and needs a reply.
- Privacy-conscious users who want vendor endpoint access disabled by default.

Practically it requires at least one supported CLI already installed and
configured; the app monitors those tools rather than replacing them.

## Current App Store Style Description

### iOS / iPadOS App Store description — AgInOl Companion

**Important: AgInOl Companion requires the AgInOl app for Mac. Before this
companion can work, download AgInOl for Mac from `aiia.li`, install it on the
Mac where your coding agents run, and keep it running. Your Mac and your iPhone
or iPad must use the same Apple Account with iCloud enabled.**

Know what your AI coding agents are doing even when you are away from your Mac.
AgInOl Companion shows the status collected by AgInOl for Mac on your iPhone or
iPad. Check from the next room, while away from the office, or 500 km away —
the devices do not have to share the same Wi-Fi network.

See Claude Code, Codex, OpenCode and Kimi Code together. At a glance, you can
identify which agents are WORKING, which are idle, and which have finished a
turn and NEED YOU to provide input. Open a provider to see its sessions,
project titles, models and elapsed time. Usage tiles show available token and
rate-limit information, including reset times when provided.

The Mac app remains the source of the data. It reads the local session files
created by supported coding tools and sends a read-only deck snapshot through
iCloud. The iOS app does not run or control agents and cannot work without the
Mac app.

Every screen shows how recently the Mac snapshot was captured. iCloud delivery
can take seconds to minutes, so you can always distinguish recent information
from an older update.

**Setup**

1. Download, install and open AgInOl for Mac from `aiia.li`.
2. Run at least one supported coding agent on that Mac.
3. Use the same Apple Account for iCloud on the Mac and iPhone or iPad.
4. Open AgInOl Companion to view the Mac's agent deck remotely.

### macOS website/download description — AgInOl for Mac

AgInOl is a floating status deck for AI coding agents on your Mac. It brings
Claude Code, Codex, OpenCode and Kimi Code together, showing which agents are
working, idle, not installed, or finished and waiting for your input.

The compact panel stays above other windows without taking keyboard focus from
your terminal. Each configurable key can show agent status, active time,
session details, token usage, plan-window usage or an all-agents summary. When
an agent needs you, AgInOl highlights it so a completed task does not sit
unnoticed.

AgInOl reads the session data the supported tools already store on your Mac.
Vendor network lookups are off by default and only run when you explicitly
enable online usage data.

Pair AgInOl with the iPhone and iPad companion to check your agents when you
leave the desk. The Mac publishes a read-only status snapshot through iCloud,
so you can see what is running or waiting whether you are nearby or hundreds of
kilometres away. Both devices must use the same Apple Account with iCloud
enabled, and the Mac app must remain running and online for current updates.

AgInOl for Mac will be distributed as a separately installed, notarized direct
download from `https://aiia.li`, outside the Mac App Store. The iPhone/iPad
companion is distributed through the Apple App Store.

## Short Description

**iOS / iPadOS:** A read-only iCloud companion for checking which AI coding
agents on your Mac are working or waiting for you, wherever you are.

**macOS:** A floating agent-status and usage deck for Claude Code, Codex,
OpenCode and Kimi Code, with remote iPhone/iPad viewing through iCloud.

## Keywords and Search Terms

**iOS / iPadOS:** `AI agent monitor`, `remote agent status`, `Claude Code`,
`Codex`, `OpenCode`, `Kimi Code`, `agent waiting`, `coding assistant`,
`developer dashboard`, `iCloud sync`, `Mac companion`, `session monitor`

**macOS / website:** `AI agent monitor`, `Claude Code`, `Codex`, `OpenCode`,
`Kimi Code`, `agent status`, `token usage`, `rate limit`, `usage tracker`,
`menu bar`, `floating overlay`, `always on top`, `developer tools`, `coding
assistant dashboard`, `session monitor`, `iCloud sync`, `local first`,
`privacy`, `macOS utility`

## Confirmed Facts

Verified against source in this repository:

- Two targets: macOS `AgInOl` and iOS/iPadOS `AgInOl Companion`.
- Bundle IDs `de.IBMobile.AgInOl` and `de.IBMobile.AgInOl-Companion`;
  team `KT43342F9W`; both at version 1.0 (build 2).
- Deployment targets 26.5 on both platforms; iPad supported.
- `INFOPLIST_KEY_LSUIElement = YES` — no Dock icon on macOS.
- `MenuBarExtra` with Show/Hide Deck (⌘D) and Quit (⌘Q).
- Four collectors registered in `CollectorHub`: Claude, Codex, OpenCode,
  Kimi Code.
- 3-second poll interval; `DeckModel` clock ticks at 1s, info bar
  advances every 4s.
- Four statuses: `working`, `needsYou`, `idle`, `offline`.
- Usage kinds: `percent`, `tokens`, `unavailable`.
- Grid configurable 2–6 columns × 1–4 rows, default 4×2.
- `onlineAccess` defaults to `false`.
- `ENABLE_APP_SANDBOX = NO` on the macOS target.
- Acknowledgement state persisted and pruned to 14 days.
- Mirroring is one-way, Mac → iOS, over `NSUbiquitousKeyValueStore`,
  behind `DeckSyncPublishing` / `DeckSyncSubscribing`.
- Both targets declare
  `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)de.IBMobile.AgInOl`.
- 30-second minimum write interval with change-detection in
  `KVSDeckSyncService`.
- Companion is read-only; it never writes to the store.
- The Mac app is the only publisher; it must run to collect and publish new
  status. Both devices must use the same Apple Account in iCloud to access the
  shared snapshot.
- App icon PNGs are configured for both the macOS and iOS targets.
- `DeckSnapshot.currentVersion = 1`; unknown newer versions are ignored.
- No StoreKit configuration, no in-app purchases, no localisation
  resources — English strings are hard-coded.
- No `Info.plist` files on disk; Info.plist keys are generated from build
  settings.

## Uncertain or Needs Verification

- **The app name expansion is inconsistent.** `AGENTS.md` says "Agent
  Information system Olverlay"; the UI footer says "Agentic Information
  Overlay"; `AgInOlApp.swift` says "Agent Information system Overlay".
  Pick one before writing store metadata.
- **Distribution is confirmed by the product owner, not encoded in source.**
  The iOS/iPadOS companion is intended for the Apple App Store. The Mac app
  will be a separately installed, notarized direct download from `aiia.li`,
  outside the Mac App Store.
- **Support and privacy-policy URLs remain unspecified.** The product owner has
  identified `aiia.li` as the Mac download site, but the repository does not
  contain final support or privacy-policy URLs required for App Store
  submission.
- **Live-endpoint behaviour is unverified here.** The Claude and Codex
  online paths depend on vendor endpoints and stored CLI credentials, and
  were not exercised.
- **Provider version compatibility is unstated.** Collectors parse
  undocumented on-disk formats that vendors may change without notice.
  `CodexCollector` already contains a comment about newer CLIs logging
  only the weekly limit.
- **iCloud capability enablement.** The entitlements files are present and
  wired, but the App IDs must carry the iCloud capability for signed
  builds to work; this cannot be confirmed from the repository.
- **Test coverage is unknown.** `AgInOlTests`, `AgInOlUITests`,
  `AgInOl CompanionTests` and `AgInOl CompanionUITests` exist; the
  companion test targets appear to hold template stubs. `AGENTS.md` notes
  UI tests fail without Xcode automation permission.

## Recently Added or Newly Detected Features

Not described in `AGENTS.md`, which predates them:

- **`AgInOl Companion`, the iOS/iPadOS target** — entire app.
- **`AgInOl Shared/`, a third synchronized group** belonging to both app
  targets: `DeckSnapshot.swift`, `DeckSyncService.swift`,
  `KVSDeckSyncService.swift`, `DeckPalette.swift`.
- **iCloud key-value mirroring**, including the shared-store entitlement
  arrangement across two bundle IDs.
- **`DeckColor` moved** out of `DeckModel.swift` into the shared
  `DeckPalette.swift` so both platforms draw from one palette.
- **Session-usage tiles** for Claude and Codex short windows
  (`claude-session`, `codex-session`) and the corresponding
  `claudeSessionUsed` / `claudeSessionLeft` / `codexSessionUsed` /
  `codexSessionLeft` key assignments.
- **Claude spend tile** (`claude-spend`) with 7-day tokens and cost plus a
  24-hour cost detail.
- **Zero-cost captions** now read "7d tokens" instead of asserting
  `$0.00`.
- **Data-age indicator** on the companion.

## Outdated or Removed Claims

Corrections to `AGENTS.md`:

- It describes AgInOl as a macOS-only app with "eight colored key tiles".
  The project is now two platforms, and the grid is configurable from 2 to
  24 keys — eight is only the default.
- Its **Project Structure** tree omits `AgInOl Shared/`,
  `AgInOl Companion/` and the two companion test targets.
- Its **Git History** section ends at `3db1bb5` and does not mention the
  later commits (`8b8df9e` KimiCodeCollector, `6830e3b` session tiles,
  `5bb9448`, `909e077`, `b81d78d`).
- Its **Adding a New Provider** checklist is now incomplete: a new
  provider also needs a `SnapshotPalette` case and a mapping in
  `DeckSnapshotBuilder.swift`, or its companion tiles fall back to the
  OpenCode purple.
- It states "**Data:** Local files only". Still true by default, but the
  app now also writes deck state to iCloud key-value storage — local-only
  is no longer unconditional.
- The **Build & Test** section lists only the macOS scheme; there is now
  an `AgInOl Companion` scheme requiring an iOS destination.

### Known defect visible in the current UI

Not a documentation issue, recorded here because it affects any
screenshot used for store metadata: the OPENCODE tile renders its model
name as a raw JSON fragment (`{"providerID":"opencode-g…`), and the KIMI
tile shows what appears to be a session title (`add mcp for IBKR`) where a
model name belongs. Both appear on the Mac and are therefore in the
collectors, not the mirroring.
