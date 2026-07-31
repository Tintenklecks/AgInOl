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
final class KVSDeckSyncService: DeckSyncPublishing, DeckSyncSubscribing,
                                CompanionRequesting, CompanionRequestServing {
    /// Single key holding the whole snapshot. KVS allows 1 MB per key
    /// and 1 MB total, which a deck of tiles is nowhere near.
    private nonisolated static let snapshotKey = "deck.snapshot.v1"
    private nonisolated static let requestPrefix = "companion.request.v1."
    private nonisolated static let responsePrefix = "companion.response.v1."
    private static let maxPayloadBytes = 900_000
    private static let deviceIDDefaultsKey = "CompanionDeviceID"

    private let store: NSUbiquitousKeyValueStore
    private let minimumWriteInterval: TimeInterval

    private var lastPublishedContent: DeckSnapshotContent?
    private var lastWriteAt: Date?
    private var pendingSnapshot: DeckSnapshot?
    private var flushTask: Task<Void, Never>?

    private var lastReceivedAt: Date?
    var onChange: ((DeckSnapshot) -> Void)?
    var onResponse: ((CompanionResponse) -> Void)?
    var onRequest: ((CompanionRequest) -> Void)?
    let deviceID: String
    private var isObserving = false

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
         minimumWriteInterval: TimeInterval = 30,
         deviceID: String? = nil) {
        self.store = store
        self.minimumWriteInterval = minimumWriteInterval
        if let deviceID {
            self.deviceID = deviceID
        } else if let stored = UserDefaults.standard.string(forKey: Self.deviceIDDefaultsKey) {
            self.deviceID = stored
        } else {
            let generated = UUID().uuidString.lowercased()
            UserDefaults.standard.set(generated, forKey: Self.deviceIDDefaultsKey)
            self.deviceID = generated
        }
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
        beginObserving()
        warnIfUnavailable()
        store.synchronize()
        if let snapshot = latest { deliver(snapshot) }
    }

    // MARK: - Companion request/response mailbox

    func send(_ request: CompanionRequest) {
        write(request, key: Self.requestPrefix + request.deviceID)
    }

    func respond(_ response: CompanionResponse) {
        write(response, key: Self.responsePrefix + response.deviceID)
    }

    func startServingRequests() {
        beginObserving()
        warnIfUnavailable()
        store.synchronize()
        deliverRequests(for: store.dictionaryRepresentation.keys.filter {
            $0.hasPrefix(Self.requestPrefix)
        })
    }

    private func beginObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChangedExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        do {
            let data = try encoder.encode(value)
            guard data.count <= Self.maxPayloadBytes else {
                assertionFailure("KVS payload of \(data.count) B exceeds the budget")
                return
            }
            store.set(data, forKey: key)
            store.synchronize()
        } catch {
            print("[DeckSync] mailbox encode failed: \(error)")
        }
    }

    /// KVS posts this on its own serial queue (`com.apple.kvs.client.callback`),
    /// never the main thread, so this has to hop rather than assume.
    @objc private nonisolated func storeChangedExternally(_ note: Notification) {
        // Read what we need here: `Notification` can't cross into the Task.
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let keys = changedKeys ?? Array(store.dictionaryRepresentation.keys)
            if keys.contains(Self.snapshotKey), let snapshot = latest {
                deliver(snapshot)
            }
            let responseKey = Self.responsePrefix + deviceID
            if keys.contains(responseKey),
               let response: CompanionResponse = decodedValue(forKey: responseKey),
               response.deviceID == deviceID {
                onResponse?(response)
            }
            deliverRequests(for: keys.filter { $0.hasPrefix(Self.requestPrefix) })
        }
    }

    private func deliverRequests<S: Sequence>(for keys: S) where S.Element == String {
        for key in keys {
            guard let request: CompanionRequest = decodedValue(forKey: key) else { continue }
            onRequest?(request)
        }
    }

    private func decodedValue<T: Decodable>(forKey key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("[DeckSync] mailbox decode failed: \(error)")
            return nil
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
