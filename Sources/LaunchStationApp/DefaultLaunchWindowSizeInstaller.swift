import AppKit
import SwiftUI

/// Restores the intended default content size when AppKit's scene restoration has retained a
/// smaller prior frame. Larger user-resized windows remain untouched.
struct DefaultLaunchWindowSizeInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }

    func updateNSView(_ nsView: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        private let defaultContentSize = NSSize(width: 1_040, height: 680)
        private var hasApplied = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasApplied else { return }
            hasApplied = true
            DispatchQueue.main.async { [weak self] in self?.restoreMinimumDefaultSize() }
        }

        private func restoreMinimumDefaultSize() {
            guard let window else { return }
            let currentSize = window.contentLayoutRect.size
            guard currentSize.width < defaultContentSize.width || currentSize.height < defaultContentSize.height else {
                return
            }
            window.setContentSize(NSSize(
                width: max(currentSize.width, defaultContentSize.width),
                height: max(currentSize.height, defaultContentSize.height)
            ))
        }
    }
}
