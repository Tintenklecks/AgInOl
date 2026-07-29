//
//  AppReviewCoordinator.swift
//  AgInOl Companion
//

import Foundation
import StoreKit
import UIKit

struct AppReviewPromptState: Codable, Equatable {
    var trackedVersion: String?
    var detailPresentationCount = 0
    var requestedVersions: Set<String> = []
}

protocol AppReviewStateStoring: AnyObject {
    func load() -> AppReviewPromptState?
    func save(_ state: AppReviewPromptState)
}

final class UserDefaultsAppReviewStateStore: AppReviewStateStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "appReview.promptState"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppReviewPromptState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppReviewPromptState.self, from: data)
    }

    func save(_ state: AppReviewPromptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class AppReviewCoordinator {
    private let store: any AppReviewStateStoring
    private let currentVersion: () -> String?
    private let detailPresentationThreshold: Int
    private let requestReview: () -> Bool

    init(
        store: (any AppReviewStateStoring)? = nil,
        currentVersion: @escaping () -> String? = {
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        },
        detailPresentationThreshold: Int = 20,
        requestReview: (() -> Bool)? = nil
    ) {
        self.store = store ?? UserDefaultsAppReviewStateStore()
        self.currentVersion = currentVersion
        self.detailPresentationThreshold = max(detailPresentationThreshold, 1)
        self.requestReview = requestReview ?? { Self.requestSystemReview() }
    }

    func detailDidAppear() {
        guard let version = currentVersion(), !version.isEmpty else { return }

        var state = state(for: version)
        guard !state.requestedVersions.contains(version) else { return }

        state.detailPresentationCount += 1
        store.save(state)

        guard state.detailPresentationCount >= detailPresentationThreshold,
              requestReview() else {
            return
        }

        state.requestedVersions.insert(version)
        store.save(state)
    }

#if DEBUG
    @discardableResult
    func requestReviewForDebug() -> Bool {
        requestReview()
    }
#endif

    private func state(for version: String) -> AppReviewPromptState {
        var state = store.load() ?? AppReviewPromptState()
        guard state.trackedVersion != version else { return state }

        state.trackedVersion = version
        state.detailPresentationCount = 0
        store.save(state)
        return state
    }

    private static func requestSystemReview() -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return false
        }

        SKStoreReviewController.requestReview(in: windowScene)
        return true
    }
}
