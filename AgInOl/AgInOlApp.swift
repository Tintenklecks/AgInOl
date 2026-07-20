//
//  AgInOlApp.swift
//  AgInOl
//
//  Agent Information system Overlay — a float-on-top, hardware-style
//  deck showing AI-agent status on macOS.
//

import SwiftUI
import AppKit

@main
struct AgInOlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("AgInOl", systemImage: "rectangle.grid.2x2.fill") {
            Button(delegate.isDeckVisible ? "Hide Deck" : "Show Deck") {
                delegate.toggleDeck()
            }
            .keyboardShortcut("d")
            Divider()
            Button("Quit AgInOl") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - App delegate: owns the floating panel

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DeckPanel?
    let model = DeckModel.initial()
    let controller = PanelController()
    private var hub: CollectorHub?

    var isDeckVisible: Bool { panel?.isVisible ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showDeck()
        let hub = CollectorHub(model: model)
        hub.start()
        self.hub = hub
    }

    func toggleDeck() {
        if isDeckVisible {
            panel?.orderOut(nil)
        } else {
            showDeck()
        }
    }

    private func showDeck() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
        // The hosting view gets its real size in a later layout pass; only
        // then can we trust fittingSize for sizing and positioning.
        DispatchQueue.main.async {
            self.controller.resizeToFit()
            self.ensureOnScreen()
        }
    }

    private func ensureOnScreen() {
        guard let panel,
              let screen = panel.screen ?? NSScreen.main else { return }
        if !screen.visibleFrame.contains(panel.frame) {
            positionTopTrailing(panel)
        }
    }

    private func makePanel() -> DeckPanel {
        // Extra padding gives the SwiftUI bezel shadow room to render.
        // fixedSize: always lay out at the ideal size, ignoring window
        // proposals — see the loop-detector note on DeckView's frame.
        let content = DeckView(model: model, controller: controller)
            .padding(36)
            .fixedSize()

        let hosting = NSHostingView(rootView: content)
        // No sizing constraints: .preferredContentSize couples the window
        // size to SwiftUI's ideal size with required constraints, and at
        // narrow grids the ideal oscillates with the proposal, tripping
        // AppKit's layout-loop detector (uncaught exception → crash).
        // PanelController.resizeToFit is the sole owner of window size.
        hosting.sizingOptions = []

        let panel = DeckPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the SwiftUI bezel draws its own shadow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            positionTopTrailing(panel)
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        controller.panel = panel

        return panel
    }

    private static let frameAutosaveName = "DeckPanel"

    private func positionTopTrailing(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 8,
            y: visible.maxY - size.height - 8
        ))
    }
}

// MARK: - Panel

/// Borderless, non-activating floating panel. Clicking it never steals
/// focus from the terminal running your agents.
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
