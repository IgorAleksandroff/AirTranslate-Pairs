import AppKit
import SwiftUI

@MainActor
final class FloatingCaptionWindowController: NSObject, NSWindowDelegate {
    static let visibilityDidChangeNotification = Notification.Name("AirTranslateFloatingCaptionVisibilityDidChange")

    static var isOpen: Bool {
        shared.window?.isVisible == true
    }

    static func toggle(session: TranslationSessionStore) {
        isOpen ? close() : open(session: session)
    }

    static func open(session: TranslationSessionStore) {
        shared.open(session: session)
    }

    static func close() {
        shared.close()
    }

    private static let shared = FloatingCaptionWindowController()
    private static let frameDefaultsKey = "floatingCaptionWindowFrame"

    private var window: NSPanel?

    private func open(session: TranslationSessionStore) {
        let isFirstOpen = window == nil
        let panel = window ?? makeWindow(session: session)
        configure(panel, session: session)
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let needsPlacement = isFirstOpen || !Self.frameIsReasonablyVisible(panel.frame, within: screenFrames)
        if needsPlacement, !restorePersistedFrame(panel) {
            positionForFirstOpen(panel)
        }
        window = panel
        panel.orderFrontRegardless()
        notifyVisibilityChanged()
    }

    private func close() {
        guard let panel = window else { return }
        persistFrame(of: panel)
        panel.orderOut(nil)
        notifyVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if let panel = window {
            persistFrame(of: panel)
        }
        window = nil
        Self.notifyVisibilityChanged()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrameIfCurrent(notification)
    }

    func windowDidResize(_ notification: Notification) {
        persistFrameIfCurrent(notification)
    }

    private func makeWindow(session: TranslationSessionStore) -> NSPanel {
        let size = NSSize(width: 720, height: 170)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: FloatingCaptionWindowView(session: session))
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func configure(_ panel: NSPanel, session: TranslationSessionStore) {
        panel.identifier = NSUserInterfaceItemIdentifier(AirTranslateWindowID.floatingCaptions)
        panel.title = AppText.floatingCaptions
        panel.level = session.keepsFloatingCaptionAboveOtherWindows ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
    }

    private func positionForFirstOpen(_ panel: NSPanel) {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }

        let frame = panel.frame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + min(180, visibleFrame.height * 0.18)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func persistFrameIfCurrent(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === window, panel.isVisible else { return }
        persistFrame(of: panel)
    }

    private func persistFrame(of panel: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
    }

    private func restorePersistedFrame(_ panel: NSPanel) -> Bool {
        guard let frameString = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else {
            return false
        }

        let frame = NSRectFromString(frameString)
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        guard Self.frameIsReasonablyVisible(frame, within: screenFrames) else {
            return false
        }

        panel.setFrame(frame, display: false)
        return true
    }

    nonisolated static func frameIsReasonablyVisible(_ frame: NSRect, within screenVisibleFrames: [NSRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }

        return screenVisibleFrames.contains { visibleFrame in
            let intersection = visibleFrame.intersection(frame)
            return intersection.width >= 160 && intersection.height >= 60
        }
    }

    private func notifyVisibilityChanged() {
        Self.notifyVisibilityChanged()
    }

    private static func notifyVisibilityChanged() {
        NotificationCenter.default.post(name: visibilityDidChangeNotification, object: nil)
    }
}
