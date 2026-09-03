import AppKit
import SwiftUI

/// Backports the flexible toolbar separation provided by newer SwiftUI releases.
///
/// macOS 13 SwiftUI lays out custom toolbar items consecutively, even when the
/// final item uses `primaryAction`. Inserting AppKit's standard flexible-space
/// item keeps the button native, accessible, and pinned to the window's trailing
/// edge without deriving a width from the current window size.
struct ToolbarTrailingActionSpacerInstaller: NSViewRepresentable {
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

        func scheduleInstallation() {
            pendingInstallation?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.installFlexibleSpace(retriesRemaining: 8)
            }
            pendingInstallation = work
            DispatchQueue.main.async(execute: work)
        }

        func cancelInstallation() {
            pendingInstallation?.cancel()
            pendingInstallation = nil
        }

        private func installFlexibleSpace(retriesRemaining: Int) {
            guard let toolbar = window?.toolbar,
                  !toolbar.items.isEmpty else {
                retryIfNeeded(retriesRemaining)
                return
            }

            // A contextual primary action can be removed and recreated after a sidebar
            // selection change. Normalize all previously injected flexible spaces, then put one
            // immediately before the current trailing toolbar item. This avoids stale spaces
            // sitting before an earlier contextual incarnation while the rebuilt group falls
            // back beside the title.
            let flexibleIndexes = toolbar.items.indices.filter {
                toolbar.items[$0].itemIdentifier == .flexibleSpace
            }
            let desiredFlexibleIndex = toolbar.items.count - 2
            if flexibleIndexes.count != 1 || flexibleIndexes.first != desiredFlexibleIndex {
                for index in flexibleIndexes.reversed() {
                    toolbar.removeItem(at: index)
                }
                let insertionIndex = max(0, toolbar.items.count - 1)
                toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: insertionIndex)
            }

            // AppKit often applies SwiftUI's contextual-toolbar diff one run-loop later. A small,
            // bounded sequence closes that timing gap without relying on a permanent timer.
            retryIfNeeded(retriesRemaining)
        }

        private func retryIfNeeded(_ retriesRemaining: Int) {
            guard retriesRemaining > 0 else {
                pendingInstallation = nil
                return
            }

            let work = DispatchWorkItem { [weak self] in
                self?.installFlexibleSpace(retriesRemaining: retriesRemaining - 1)
            }
            pendingInstallation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
}
