//
//  DeckMirror.swift
//  AgInOl Companion
//
//  Read-only view of the Mac deck. The companion never writes: the Mac
//  is the single source of truth, so there is no conflict resolution to
//  get wrong. Commands back to the Mac will need their own channel.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class DeckMirror {
    private(set) var snapshot: DeckSnapshot?
    /// Ticks so elapsed-time labels stay live between snapshots.
    private(set) var now = Date()

    @ObservationIgnored private let sync: any DeckSyncSubscribing
    @ObservationIgnored private var clock: Timer?

    /// Defaults to the iCloud KVS transport. Built in the body rather
    /// than as a default argument, which would be evaluated off the actor.
    init(sync: (any DeckSyncSubscribing)? = nil) {
        self.sync = sync ?? KVSDeckSyncService()
    }

    func start() {
        sync.onChange = { [weak self] snapshot in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                self?.snapshot = snapshot
            }
        }
        sync.start()
        snapshot = sync.latest

        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
    }

    var agents: [SnapshotAgent] { snapshot?.content.agents ?? [] }
    var usage: [SnapshotUsage] { snapshot?.content.usage ?? [] }

    /// iCloud KVS delivers in seconds-to-minutes, so the age of the data
    /// is part of the data — never render a stale deck as if it were live.
    var age: TimeInterval? {
        snapshot.map { now.timeIntervalSince($0.capturedAt) }
    }

    var ageCaption: String {
        guard let age else { return String(localized: "waiting for Mac…") }
        let seconds = max(0, Int(age))
        return switch seconds {
        case ..<45:    String(localized: "just now")
        case ..<3600:  String(localized: "\(seconds / 60) min ago")
        default:       String(localized: "\(seconds / 3600) h ago")
        }
    }

    var isStale: Bool { (age ?? .infinity) > 300 }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60, s = seconds % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }
}
