import AppKit
import SwiftUI

/// Gives a native SwiftUI scroll container an overlay-style, trackless scroller:
/// the draggable AppKit knob remains intact, while no gutter or rail takes layout
/// space beside the content. This is intentionally shared by the sidebar and the
/// main inspector so the two root panes feel like one application.
struct TracklessOverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerProbe {
        ScrollerProbe(frame: .zero)
    }

    func updateNSView(_ nsView: ScrollerProbe, context: Context) {
        nsView.scheduleInstall()
    }

    final class ScrollerProbe: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleInstall()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
        }

        func scheduleInstall() {
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        private func installIfNeeded() {
            guard let scrollView = enclosingScrollView,
                  let existingScroller = scrollView.verticalScroller else {
                return
            }

            // Force overlay metrics for these app-owned panes. The system's legacy scroller
            // setting otherwise reserves a visible gutter even when the rail itself is hidden.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true

            if existingScroller is TracklessOverlayScroller {
                existingScroller.scrollerStyle = .overlay
                return
            }

            let replacement = TracklessOverlayScroller(frame: existingScroller.frame)
            replacement.autoresizingMask = existingScroller.autoresizingMask
            replacement.controlSize = existingScroller.controlSize
            replacement.target = existingScroller.target
            replacement.action = existingScroller.action
            replacement.isEnabled = existingScroller.isEnabled
            replacement.doubleValue = existingScroller.doubleValue
            replacement.knobProportion = existingScroller.knobProportion
            replacement.scrollerStyle = .overlay
            replacement.knobStyle = existingScroller.knobStyle
            scrollView.verticalScroller = replacement
        }
    }
}

private final class TracklessOverlayScroller: NSScroller {
    /// Opt in to AppKit's normal overlay-scroller behavior when the person has
    /// selected it in System Settings. Without this, subclassing would force
    /// the scroll view back to the old permanent-gutter metrics.
    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    /// NSScroller draws the rail in this method. Leaving the knob and all hit
    /// testing untouched keeps its native draggable and accessible behavior.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

extension View {
    /// Applies Launcher’s trackless overlay scroller to a root scrolling pane.
    func tracklessOverlayScroller() -> some View {
        background(
            TracklessOverlayScrollerStyle()
                .allowsHitTesting(false)
        )
    }
}
