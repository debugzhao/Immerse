import AppKit
import SwiftUI

/// Keeps the moment at the middle of the time grid's viewport in the middle while the viewport changes height
/// (window resized, moved to a screen of another size, the all-day row or goal ribbon growing).
///
/// AppKit keeps the top edge of a resized scroll view fixed, so the current-time line drifted up and down. Fixing it
/// in SwiftUI (onChange of the size, then scrollTo) lands a frame late and visibly jumps; this corrects the clip
/// view's origin inside the same bounds change, before anything is drawn.
///
/// Place it in the scroll view's content (e.g. as a background); it finds the enclosing NSScrollView itself.
struct ScrollCenterKeeper: NSViewRepresentable {
    /// Off until the grid has scrolled to its initial position; the first layout also changes the viewport height
    /// (from nothing to its real size), which must not be "corrected" back to where the scroll started
    var isActive: Bool
    /// Document y to hold in the middle until active (the current time on opening). The viewport only reaches its
    /// final height after a few layout passes, so a one-off initial offset computed from an early height misses
    var initialCenterY: CGFloat?

    func makeNSView(context: Context) -> KeeperView {
        KeeperView()
    }

    func updateNSView(_ view: KeeperView, context: Context) {
        if !isActive { view.targetCenterY = initialCenterY }
        view.isActive = isActive
    }

    final class KeeperView: NSView {
        private weak var clipView: NSClipView?
        /// Document y at the middle of the viewport, as of the last scroll
        private var centerY: CGFloat?
        private var viewportHeight: CGFloat = 0
        private var isAdjusting = false
        var targetCenterY: CGFloat? {
            didSet { if targetCenterY != oldValue { holdTarget() } }
        }
        var isActive = false {
            didSet {
                // Start from wherever the initial positioning left the grid
                if isActive && !oldValue, let clip = clipView {
                    targetCenterY = nil
                    viewportHeight = clip.bounds.height
                    centerY = clip.bounds.midY
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clipView = clip
            viewportHeight = clip.bounds.height
            centerY = clip.bounds.midY
            // Scrolling changes the clip view's bounds; resizing changes its frame, which does NOT post a
            // bounds notification (bounds that follow the frame don't count), so both are needed
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange),
                                                   name: NSView.frameDidChangeNotification, object: clip)
            holdTarget()
        }

        /// Before activation: keep `targetCenterY` in the middle of whatever height the viewport has right now
        private func holdTarget() {
            guard !isActive, let targetCenterY, let clip = clipView, clip.bounds.height > 0 else { return }
            setMiddle(targetCenterY, in: clip)
        }

        private func setMiddle(_ middleY: CGFloat, in clip: NSClipView) {
            guard let document = enclosingScrollView?.documentView else { return }
            let bounds = clip.bounds
            let maxY = max(document.frame.height - bounds.height, 0)
            let originY = min(max(middleY - bounds.height / 2, 0), maxY)
            guard abs(originY - bounds.origin.y) >= 0.5 else { return }
            isAdjusting = true
            clip.scroll(to: NSPoint(x: bounds.origin.x, y: originY))
            enclosingScrollView?.reflectScrolledClipView(clip)
            isAdjusting = false
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            guard !isAdjusting, let clip = clipView else { return }
            let bounds = clip.bounds
            guard bounds.height > 0 else { return }
            if !isActive {
                viewportHeight = bounds.height
                if targetCenterY != nil { holdTarget() } else { centerY = bounds.midY }
                return
            }
            if abs(bounds.height - viewportHeight) < 0.5 {
                // A scroll: remember where the middle is now
                centerY = bounds.midY
                return
            }
            // A resize: put the remembered middle back in the middle
            viewportHeight = bounds.height
            if let centerY { setMiddle(centerY, in: clip) }
        }
    }
}
