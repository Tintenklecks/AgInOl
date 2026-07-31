//
//  SoftwareUpdateController.swift
//  AgInOl
//
//  Thin wrapper around Sparkle's standard updater UI.
//

import Foundation
import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SoftwareUpdateController {
    static let shared = SoftwareUpdateController()

#if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
#else
    private init() {}

    var canCheckForUpdates: Bool {
        true
    }

    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Updater not configured"
        alert.informativeText = """
        Add the Sparkle package to the AgInOl macOS target, then set SUFeedURL and SUPublicEDKey in the generated Info.plist settings.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
#endif
}
