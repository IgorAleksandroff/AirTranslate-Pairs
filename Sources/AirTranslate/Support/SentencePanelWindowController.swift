import AppKit
import SwiftUI

@MainActor
final class SentencePanelWindowController: NSObject, NSWindowDelegate {
    static let visibilityDidChangeNotification = Notification.Name("AirTranslateSentencePanelVisibilityDidChange")

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

    private static let shared = SentencePanelWindowController()
    private static let frameDefaultsKey = "sentencePanelWindowFrame"
    private static let minimumSize = NSSize(width: 300, height: 180)

    private var window: NSPanel?

    private func open(session: TranslationSessionStore) {
        let isFirstOpen = window == nil
        let panel = window ?? makeWindow(session: session)
        configure(panel, session: session)
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let needsPlacement = isFirstOpen
            || !FloatingCaptionWindowController.frameIsReasonablyVisible(panel.frame, within: screenFrames)
        if needsPlacement, !restorePersistedFrame(panel) {
            positionForFirstOpen(panel)
        }
        window = panel
        panel.orderFrontRegardless()
        Self.notifyVisibilityChanged()
    }

    private func close() {
        guard let panel = window else { return }
        persistFrame(of: panel)
        panel.orderOut(nil)
        Self.notifyVisibilityChanged()
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
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 520)),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: SentencePanelView(session: session))
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func configure(_ panel: NSPanel, session: TranslationSessionStore) {
        panel.identifier = NSUserInterfaceItemIdentifier(AirTranslateWindowID.sentencePanel)
        panel.title = AppText.sentencePanel
        panel.level = session.keepsFloatingCaptionAboveOtherWindows ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = Self.minimumSize
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
    }

    private func positionForFirstOpen(_ panel: NSPanel) {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }

        let frame = panel.frame
        let x = visibleFrame.maxX - frame.width - 24
        let y = visibleFrame.maxY - frame.height - 24
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
        guard FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: screenFrames) else {
            return false
        }

        panel.setFrame(frame, display: false)
        return true
    }

    private static func notifyVisibilityChanged() {
        NotificationCenter.default.post(name: visibilityDidChangeNotification, object: nil)
    }
}
