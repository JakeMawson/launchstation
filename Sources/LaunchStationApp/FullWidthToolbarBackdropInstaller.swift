import AppKit
import SwiftUI

/// Adds the fixed title label to the unified window toolbar without altering its
/// AppKit-owned background.
///
/// The standard close button's direct superview is the title-bar container. A
/// title-bar container is used only as the title label's host. Its title label is
/// positioned after the native sidebar toggle (or the traffic lights when AppKit
/// does not expose that view), keeping the title fixed as the split-view sidebar
/// appears and disappears.
struct FullWidthToolbarBackdropInstaller: NSViewRepresentable {
    let configurationToken: String

    func makeNSView(context: Context) -> InstallerView {
        InstallerView(configurationToken: configurationToken)
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        nsView.apply(configurationToken: configurationToken)
    }

    static func dismantleNSView(_ nsView: InstallerView, coordinator: Void) {
        nsView.cancelInstallation()
    }

    final class InstallerView: NSView {
        private static let titleIdentifier = NSUserInterfaceItemIdentifier(
            "com.jakemawson.launchstation.fixed-toolbar-title"
        )
        private var pendingInstallation: DispatchWorkItem?
        private var configurationToken: String

        init(configurationToken: String) {
            self.configurationToken = configurationToken
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            configurationToken = "initial"
            super.init(coder: coder)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstallation()
        }

        func apply(configurationToken: String) {
            guard self.configurationToken != configurationToken else { return }
            self.configurationToken = configurationToken
            scheduleInstallation()
        }

        private func installIfPossible(retriesRemaining: Int) {
            guard let window,
                  let titlebarContainer = window.standardWindowButton(.closeButton)?.superview else {
                retryIfNeeded(retriesRemaining)
                return
            }

            window.titlebarAppearsTransparent = true
            installTitle(in: titlebarContainer, window: window)
            retryIfNeeded(retriesRemaining)
        }

        func cancelInstallation() {
            pendingInstallation?.cancel()
            pendingInstallation = nil
        }

        private func scheduleInstallation() {
            pendingInstallation?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.installIfPossible(retriesRemaining: 8)
            }
            pendingInstallation = work
            DispatchQueue.main.async(execute: work)
        }

        private func retryIfNeeded(_ retriesRemaining: Int) {
            guard retriesRemaining > 0 else {
                pendingInstallation = nil
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.installIfPossible(retriesRemaining: retriesRemaining - 1)
            }
            pendingInstallation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        private func installTitle(
            in titlebarContainer: NSView,
            window: NSWindow
        ) {
            let title: NSTextField
            if let existing = titlebarContainer.subviews.first(where: {
                $0.identifier == Self.titleIdentifier
            }) as? NSTextField {
                title = existing
            } else {
                title = NSTextField(labelWithString: "Launch Station")
                title.identifier = Self.titleIdentifier
                title.font = .systemFont(ofSize: 13, weight: .semibold)
                title.textColor = NSColor(name: "LaunchStation.ToolbarTitle") { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return .white
                    }
                    return .labelColor
                }
                title.lineBreakMode = .byTruncatingTail
                title.setContentHuggingPriority(.required, for: .horizontal)
                title.sizeToFit()
                title.setAccessibilityLabel("Launch Station")
                titlebarContainer.addSubview(title)
            }

            let sidebarToggleEdge = window.toolbar?.items.first(where: {
                $0.itemIdentifier == .toggleSidebar
            })?.view.map {
                titlebarContainer.convert($0.bounds, from: $0).maxX
            }
            let trafficLightEdge = [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ]
            .compactMap { window.standardWindowButton($0) }
            .map { titlebarContainer.convert($0.bounds, from: $0).maxX }
            .max() ?? 0
            let leadingEdge = (sidebarToggleEdge ?? trafficLightEdge + 78) + 16

            title.frame.origin = CGPoint(
                x: leadingEdge,
                y: (titlebarContainer.bounds.height - title.frame.height) / 2
            )
            title.autoresizingMask = [.maxXMargin]
            titlebarContainer.addSubview(title, positioned: .above, relativeTo: nil)
        }

    }
}
