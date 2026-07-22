//
//  KVSDeckSyncService.swift
//  AgInOl — shared by the Mac app and the companion
//
//  iCloud key-value store transport. No backend, ~30 lines of setup —
//  but KVS is built for preferences, not feeds: it coalesces and
//  throttles rapid writes, so hammering it makes delivery *slower*.
//  This service therefore rate-limits itself and only writes when the
//  deck content actually changed. Expect seconds-to-minutes freshness
//  on the receiving device; swap in a CloudKit transport when that
//  stops being good enough.
//

import Foundation

@MainActor
final class KVSDeckSyncService: DeckSyncPublishing, DeckSyncSubscribing {
    /// Single key holding the whole snapshot. KVS allows 1 MB per key
    /// and 1 MB total, which a deck of tiles is nowhere near.
    private nonisolated static let snapshotKey = "deck.snapshot.v1"
    private static let maxPayloadBytes = 900_000

    private let store: NSUbiquitousKeyValueStore
    private let minimumWriteInterval: TimeInterval

    private var lastPublishedContent: DeckSnapshotContent?
    private var lastWriteAt: Date?
    private var pendingSnapshot: DeckSnapshot?
    private var flushTask: Task<Void, Never>?

    private var lastReceivedAt: Date?
    var onChange: ((DeckSnapshot) -> Void)?

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(store: NSUbiquitousKeyValueStore = .default,
         minimumWriteInterval: TimeInterval = 30) {
        self.store = store
        self.minimumWriteInterval = minimumWriteInterval
    }

    deinit {
        flushTask?.cancel()
    }

    // MARK: - Publishing (Mac)

    func publish(_ snapshot: DeckSnapshot) {
        // Nothing meaningful changed — a new timestamp alone is not
        // worth a write, and needless writes cost us latency later.
        guard snapshot.content != lastPublishedContent else { return }

        pendingSnapshot = snapshot

        let waited = lastWriteAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard waited < minimumWriteInterval else {
            flush()
            return
        }

        // Inside the cooling-off window: hold the newest snapshot and
        // write it when the window closes, so a change is delayed but
        // never dropped.
        guard flushTask == nil else { return }
        let delay = minimumWriteInterval - waited
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    /// Cheap "is iCloud usable at all" probe. A nil token means no
    /// signed-in account or an entitlement that never took effect —
    /// both of which otherwise fail completely silently.
    private func warnIfUnavailable() {
        guard FileManager.default.ubiquityIdentityToken == nil else { return }
        print("[DeckSync] no iCloud identity token — check the iCloud capability and that this device is signed in")
    }

    private func flush() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        warnIfUnavailable()

        do {
            let data = try encoder.encode(snapshot)
            guard data.count <= Self.maxPayloadBytes else {
                assertionFailure("Deck snapshot of \(data.count) B exceeds the KVS budget")
                return
            }
            store.set(data, forKey: Self.snapshotKey)
            store.synchronize()
            lastPublishedContent = snapshot.content
            lastWriteAt = Date()
            print("[DeckSync] published \(data.count) B")
        } catch {
            // Leave lastPublishedContent untouched so the next tick retries.
            print("[DeckSync] encode failed: \(error)")
        }
    }

    // MARK: - Subscribing (companion)

    var latest: DeckSnapshot? {
        guard let data = store.data(forKey: Self.snapshotKey) else { return nil }
        return decode(data)
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChangedExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        warnIfUnavailable()
        store.synchronize()
        if let snapshot = latest { deliver(snapshot) }
    }

    /// KVS posts this on its own serial queue (`com.apple.kvs.client.callback`),
    /// never the main thread, so this has to hop rather than assume.
    @objc private nonisolated func storeChangedExternally(_ note: Notification) {
        // Read what we need here: `Notification` can't cross into the Task.
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        // A nil key list means "everything may have changed" (initial
        // sync, quota); only bail when we're told our key was untouched.
        if let changedKeys, !changedKeys.contains(Self.snapshotKey) { return }

        Task { @MainActor [weak self] in
            guard let self, let snapshot = latest else { return }
            deliver(snapshot)
        }
    }

    private func deliver(_ snapshot: DeckSnapshot) {
        // KVS gives no ordering guarantee; never let a stale snapshot
        // overwrite a newer one we already showed.
        if let lastReceivedAt, snapshot.capturedAt <= lastReceivedAt { return }
        lastReceivedAt = snapshot.capturedAt
        onChange?(snapshot)
    }

    private func decode(_ data: Data) -> DeckSnapshot? {
        do {
            let snapshot = try decoder.decode(DeckSnapshot.self, from: data)
            guard snapshot.version <= DeckSnapshot.currentVersion else {
                print("[DeckSync] ignoring snapshot v\(snapshot.version); this build speaks v\(DeckSnapshot.currentVersion)")
                return nil
            }
            return snapshot
        } catch {
            print("[DeckSync] decode failed: \(error)")
            return nil
        }
    }
}
