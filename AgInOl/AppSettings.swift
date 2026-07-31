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

    /// Key-grid dimensions (columns × rows). 4×2 mirrors the Stream Deck
    /// Neo hardware; other combinations are picked in settings.
    var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: Self.gridColumnsKey) }
    }
    var gridRows: Int {
        didSet { UserDefaults.standard.set(gridRows, forKey: Self.gridRowsKey) }
    }

    static let columnOptions = Array(2...6)
    static let rowOptions = Array(1...4)
    var keyCount: Int { gridColumns * gridRows }

    /// Show the info-bar carousel and its arrow touch points below the
    /// keys (space permitting — grids under 3 columns hide it anyway).
    var showInfoBar: Bool {
        didSet { UserDefaults.standard.set(showInfoBar, forKey: Self.showInfoBarKey) }
    }

    /// Show the Did You Know dialog when AgInOl starts.
    var showTipsOnLaunch: Bool {
        didSet { UserDefaults.standard.set(showTipsOnLaunch, forKey: Self.showTipsOnLaunchKey) }
    }

    private static let onlineAccessKey = "OnlineAccessEnabled"
    private static let gridColumnsKey = "GridColumns"
    private static let gridRowsKey = "GridRows"
    private static let showInfoBarKey = "ShowInfoBar"
    private static let showTipsOnLaunchKey = "ShowTipsOnLaunch"

    private init() {
        onlineAccess = UserDefaults.standard.bool(forKey: Self.onlineAccessKey)
        showInfoBar = UserDefaults.standard.object(forKey: Self.showInfoBarKey) as? Bool ?? true
        showTipsOnLaunch = UserDefaults.standard.object(forKey: Self.showTipsOnLaunchKey) as? Bool ?? true
        let columns = UserDefaults.standard.integer(forKey: Self.gridColumnsKey)
        gridColumns = Self.columnOptions.contains(columns) ? columns : 4
        let rows = UserDefaults.standard.integer(forKey: Self.gridRowsKey)
        gridRows = Self.rowOptions.contains(rows) ? rows : 2
    }
}
