import AppKit
import SwiftUI

@main
struct AirTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = TranslationSessionStore()
    @State private var menuBarPanelController = MenuBarPanelController()

    init() {
        appDelegate.session = session
    }

    var body: some Scene {
        WindowGroup("AirTranslate", id: AirTranslateWindowID.main) {
            ContentView(session: session)
                .frame(minWidth: 900, minHeight: 560)
                .background(MenuBarPanelInstaller(session: session, controller: menuBarPanelController))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CaptureCommands(session: session)
        }

        Settings {
            SettingsView(session: session)
        }
    }
}

@MainActor
private struct CaptureCommands: Commands {
    @Bindable var session: TranslationSessionStore

    var body: some Commands {
        CommandMenu(AppText.capture) {
            Button(session.isRunning || session.isStarting ? AppText.stop : AppText.start) {
                if session.isRunning || session.isStarting {
                    session.stop()
                } else {
                    session.start()
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button(session.isPaused ? AppText.resume : AppText.pause) {
                session.isPaused ? session.resume() : session.pause()
            }
            .keyboardShortcut(.space, modifiers: [.command, .shift])
            .disabled(!session.isRunning)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: TranslationSessionStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.prepareForTermination()
    }
}
