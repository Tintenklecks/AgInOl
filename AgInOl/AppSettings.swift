//
//  AppSettings.swift
//  AgInOl
//
//  User preferences, persisted in UserDefaults.
//

import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Allow the collectors to call the vendors' usage endpoints with the
    /// CLIs' stored credentials (Claude plan limits, live Codex limits).
    /// Off by default: a fresh install stays fully local and never shows
    /// a Keychain dialog until the user opts in.
    var onlineAccess: Bool {
        didSet { UserDefaults.standard.set(onlineAccess, forKey: Self.onlineAccessKey) }
    }

    private static let onlineAccessKey = "OnlineAccessEnabled"

    private init() {
        onlineAccess = UserDefaults.standard.bool(forKey: Self.onlineAccessKey)
    }
}
