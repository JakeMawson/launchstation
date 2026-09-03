import AppKit
import SwiftUI

/// Observes plain Escape for only the window containing this representable.
/// The event is returned unchanged so focused controls and native presentations
/// retain their ordinary cancel behavior after the sidebar is dismissed.
struct EscapeKeyMonitor: NSViewRepresentable {
    var onEscape: () -> Void

    func makeNSView(context: Context) -> EscapeMonitoringView {
        EscapeMonitoringView(onEscape: onEscape)
    }

    func updateNSView(_ view: EscapeMonitoringView, context: Context) {
        view.onEscape = onEscape
    }

    static func dismantleNSView(_ view: EscapeMonitoringView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class EscapeMonitoringView: NSView {
    var onEscape: () -> Void
    private var monitor: Any?

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    deinit {
        stopMonitoring()
    }

    func stopMonitoring() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }
            self.onEscape()
            return event
        }
    }
}
