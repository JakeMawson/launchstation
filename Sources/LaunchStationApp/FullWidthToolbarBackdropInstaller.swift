import AppKit
import SwiftUI

/// Gives the unified window toolbar one AppKit-owned backdrop and title instead
/// of letting `NavigationSplitView` paint and position independent sidebar and
/// detail title-bar regions.
///
/// The standard close button's direct superview is the title-bar container. A
/// visual-effect view inserted behind its existing controls therefore covers the
/// complete toolbar width. Its title label is positioned after the native sidebar
/// toggle (or the traffic lights when AppKit does not expose that view), keeping
/// the title fixed as the split-view sidebar appears and disappears.
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
        private static let backdropIdentifier = NSUserInterfaceItemIdentifier(
            "com.jakemawson.launchstation.full-width-toolbar-backdrop"
        )
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

            let backdrop: ToolbarBackgroundView
            if let existing = titlebarContainer.subviews.first(where: {
                $0.identifier == Self.backdropIdentifier
            }) as? ToolbarBackgroundView {
                backdrop = existing
            } else {
                backdrop = ToolbarBackgroundView(frame: titlebarContainer.bounds)
                backdrop.identifier = Self.backdropIdentifier
                backdrop.autoresizingMask = [.width, .height]
            }

            backdrop.frame = titlebarContainer.bounds
            titlebarContainer.addSubview(backdrop, positioned: .below, relativeTo: nil)
            installTitle(in: titlebarContainer, window: window, behind: backdrop)
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
            window: NSWindow,
            behind backdrop: NSView
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
                titlebarContainer.addSubview(title, positioned: .above, relativeTo: backdrop)
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

        /// Keep the native title-bar controls, but paint their shared container with the same
        /// adaptive porcelain colour used by the window content instead of a separate toolbar
        /// material.
        private final class ToolbarBackgroundView: NSView {
            override var isOpaque: Bool { true }

            override func draw(_ dirtyRect: NSRect) {
                let colour: NSColor
                if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    colour = NSColor(srgbRed: 0x15 / 255, green: 0x1D / 255, blue: 0x20 / 255, alpha: 1)
                } else {
                    colour = NSColor(srgbRed: 0xFB / 255, green: 0xFC / 255, blue: 0xFC / 255, alpha: 1)
                }
                colour.setFill()
                dirtyRect.fill()
            }

            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                needsDisplay = true
            }
        }
    }
}
