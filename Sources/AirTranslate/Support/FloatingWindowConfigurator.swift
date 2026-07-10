import AppKit
import SwiftUI

struct FloatingWindowConfigurator: NSViewRepresentable {
    let preferredContentHeight: CGFloat
    let keepsAboveOtherWindows: Bool

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.identifier = NSUserInterfaceItemIdentifier(AirTranslateWindowID.floatingCaptions)
            window.level = keepsAboveOtherWindows ? .floating : .normal
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false

            let minimumSize = NSSize(width: 420, height: preferredContentHeight)
            window.minSize = minimumSize
            if window.contentLayoutRect.height + 1 < preferredContentHeight {
                window.setContentSize(
                    NSSize(
                        width: max(window.contentLayoutRect.width, minimumSize.width),
                        height: preferredContentHeight
                    )
                )
            }
            keepWindowVisible(window)
        }
    }

    private func keepWindowVisible(_ window: NSWindow) {
        guard window.isVisible else { return }
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let inset: CGFloat = 16
        var frame = window.frame
        let maximumWidth = max(window.minSize.width, visibleFrame.width - inset * 2)
        let maximumHeight = max(window.minSize.height, visibleFrame.height - inset * 2)
        frame.size.width = min(max(frame.width, window.minSize.width), maximumWidth)
        frame.size.height = min(max(frame.height, window.minSize.height), maximumHeight)
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX + inset),
            visibleFrame.maxX - frame.width - inset
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY + inset),
            visibleFrame.maxY - frame.height - inset
        )

        if !NSEqualRects(frame, window.frame) {
            window.setFrame(frame, display: true)
        }
    }
}
