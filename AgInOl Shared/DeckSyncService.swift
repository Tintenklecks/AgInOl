//
//  DeckSyncService.swift
//  AgInOl — shared by the Mac app and the companion
//
//  Transport-agnostic seam for mirroring the deck. The iCloud KVS
//  implementation is the cheap starting point; a CloudKit (or socket)
//  transport can replace it without touching CollectorHub or the
//  companion UI.
//

import Foundation

/// Mac side: pushes deck state outward.
///
/// `publish` is fire-and-forget by design — callers hand over every
/// snapshot they produce and the transport decides what is worth
/// sending. Coalescing, rate limiting and retries are transport
/// concerns, because what counts as "too often" differs wildly between
/// KVS (minutes) and CloudKit (seconds).
@MainActor
protocol DeckSyncPublishing: AnyObject {
    func publish(_ snapshot: DeckSnapshot)
}

/// Companion side: observes snapshots published by the Mac.
@MainActor
protocol DeckSyncSubscribing: AnyObject {
    /// Locally cached snapshot, so the UI can paint before the first
    /// remote change arrives.
    var latest: DeckSnapshot? { get }
    var onChange: ((DeckSnapshot) -> Void)? { get set }
    func start()
}
