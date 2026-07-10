import SwiftUI

struct MenuBarPanelInstaller: NSViewRepresentable {
    let session: TranslationSessionStore
    let controller: MenuBarPanelController

    func makeNSView(context _: Context) -> NSView {
        let session = session
        let controller = controller
        Task { @MainActor in
            controller.install(session: session)
        }
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context _: Context) {}
}
