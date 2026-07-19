//
//  PanelController.swift
//  AgInOl
//
//  Slides the floating panel mostly off the nearest screen edge
//  (double-click) and back (click on the visible sliver).
//

import AppKit
import Observation

@Observable
final class PanelController {
    weak var panel: NSPanel?
    private(set) var isTucked = false
    private var restoreFrame: NSRect?

    /// How much of the window stays visible when tucked: the transparent
    /// shadow margin (36) plus a strip of actual bezel.
    private let sliver: CGFloat = 36 + 30

    func toggleTuck() {
        isTucked ? untuck() : tuck()
    }

    func tuck() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        restoreFrame = panel.frame
        let visible = screen.visibleFrame
        var target = panel.frame
        if panel.frame.midX < visible.midX {
            target.origin.x = visible.minX - target.width + sliver
        } else {
            target.origin.x = visible.maxX - sliver
        }
        isTucked = true
        animate(panel, to: target)
    }

    func untuck() {
        guard let panel else { return }
        isTucked = false
        var target = restoreFrame ?? panel.frame
        // If the remembered spot is gone (display changed), keep it reachable.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            target.origin.x = min(max(target.origin.x, visible.minX - 36),
                                  visible.maxX - target.width + 36)
        }
        animate(panel, to: target)
    }

    private func animate(_ panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
