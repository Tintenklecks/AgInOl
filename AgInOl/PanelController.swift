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

    private var pendingResize: DispatchWorkItem?

    /// The key grid changed shape. Grow the window right away so the new
    /// keys have room while they animate in; the debounced pass then
    /// settles the final size (shrinking early would clip keys that are
    /// still springing to their new positions).
    func gridDidChange() {
        if let panel, let hosting = panel.contentView {
            let size = hosting.fittingSize
            if size.width > panel.frame.width || size.height > panel.frame.height {
                resizeToFit()
            }
        }
        scheduleResizeToFit()
    }

    /// Fit the panel to the deck once the grid-change spring has settled.
    /// Debounced: picking several grid sizes in quick succession only
    /// resizes once, for the final layout.
    func scheduleResizeToFit() {
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resizeToFit() }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Match the panel to the deck's ideal size — the sole owner of the
    /// window's size, since the hosting view installs no sizing
    /// constraints (see makePanel). Keeps the top edge fixed: frames are
    /// anchored bottom-left, so a plain resize would drop the deck
    /// downward off its old top edge.
    func resizeToFit() {
        guard !isTucked, let panel, let hosting = panel.contentView else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if panel.frame.size != size {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
        clampToScreen()
    }

    /// Pull the panel back into the visible frame after it changes size
    /// (frames grow from the bottom-left origin, so a bigger grid can
    /// push the top edge past the screen). The 36pt transparent shadow
    /// margin is allowed to hang over the edge.
    func clampToScreen() {
        guard !isTucked, let panel,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x, visible.minX - 36),
                             visible.maxX - frame.width + 36)
        frame.origin.y = min(max(frame.origin.y, visible.minY - 36),
                             visible.maxY - frame.height + 36)
        guard frame.origin != panel.frame.origin else { return }
        animate(panel, to: frame)
    }

    private func animate(_ panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
