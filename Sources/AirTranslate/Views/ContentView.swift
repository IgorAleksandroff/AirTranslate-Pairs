import SwiftUI

struct ContentView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLibraryPresented = false
    @State private var isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                SidebarView(session: session)
                    .navigationSplitViewColumnWidth(
                        min: AirTranslateDesign.sidebarMinimum,
                        ideal: AirTranslateDesign.sidebarIdeal,
                        max: AirTranslateDesign.sidebarMaximum
                    )
            } detail: {
                CaptionBoardView(session: session)
            }

            if let toastMessage = session.toastMessage {
                ToastMessageView(message: toastMessage)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    requestCaptureToggle()
                } label: {
                    Label(captureButtonTitle, systemImage: captureButtonSystemImage)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle)
                .tint(session.isRunning || session.isStarting ? .red : .accentColor)
                .help(captureButtonTitle)
                .accessibilityLabel(captureButtonTitle)
                .accessibilityValue(captureStateDescription)

                Button {
                    togglePause()
                } label: {
                    Label(
                        session.isPaused ? AppText.resume : AppText.pause,
                        systemImage: session.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonBorderShape(.roundedRectangle)
                .disabled(!session.isRunning)
                .help(session.isPaused ? AppText.resume : AppText.pause)
                .accessibilityLabel(session.isPaused ? AppText.resume : AppText.pause)
            }

            ToolbarSpacer(.fixed)

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleFloatingCaptions()
                } label: {
                    Image(systemName: isFloatingCaptionVisible ? "captions.bubble.fill" : "captions.bubble")
                }
                .buttonBorderShape(.roundedRectangle)
                .help(AppText.floatingCaptions)
                .accessibilityLabel(AppText.floatingCaptions)
                .accessibilityValue(isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff)
                .accessibilityAddTraits(isFloatingCaptionVisible ? .isSelected : [])

                Button {
                    isLibraryPresented = true
                } label: {
                    Image(systemName: "tray.full")
                }
                .buttonBorderShape(.roundedRectangle)
                .help(AppText.manageSavedTranscripts)
                .accessibilityLabel(AppText.library)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonBorderShape(.roundedRectangle)
                .help(AppText.configureTranslationSettings)
                .accessibilityLabel(AppText.translationSettings)
            }
        }
        .controlSize(.regular)
        .sheet(isPresented: $isLibraryPresented) {
            TranscriptLibraryView(session: session)
        }
        .onAppear {
            syncFloatingCaptionVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingCaptionWindowController.visibilityDidChangeNotification)) { _ in
            syncFloatingCaptionVisibility()
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84), value: session.toastSequence)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.toastMessage)
        .confirmationDialog(
            AppText.autoDetectionLanguageChangeTitle,
            isPresented: autoDetectionLanguageChangeBinding,
            titleVisibility: .visible
        ) {
            Button(AppText.startNewAutoDetectionSession) {
                session.confirmAutoDetectionLanguageChange()
            }

            Button(AppText.keepCurrentAutoDetectionLanguage, role: .cancel) {
                session.keepCurrentAutoDetectionLanguage()
            }
        } message: {
            if let languageChange = session.pendingAutoDetectionLanguageChange {
                Text(
                    AppText.autoDetectionLanguageChangeMessage(
                        current: languageChange.currentLanguage.localizedTitle,
                        detected: languageChange.detectedLanguage.localizedTitle,
                        target: languageChange.targetLanguage.localizedTitle
                    )
                )
            }
        }
    }

    private var captureButtonTitle: String {
        session.isRunning || session.isStarting ? AppText.stop : AppText.start
    }

    private var captureStateDescription: String {
        if session.isStarting {
            return AppText.startingCapture(for: session.audioInputSource)
        }
        if session.isRunning {
            return session.isPaused ? AppText.paused : AppText.listening
        }
        return AppText.ready
    }

    private var captureButtonSystemImage: String {
        session.isRunning || session.isStarting ? "stop.fill" : "play.fill"
    }

    private func requestCaptureToggle() {
        if session.isRunning || session.isStarting {
            session.stop()
        } else {
            session.start()
        }
    }

    private func togglePause() {
        session.isPaused ? session.resume() : session.pause()
    }

    private func toggleFloatingCaptions() {
        FloatingCaptionWindowController.toggle(session: session)
        syncFloatingCaptionVisibility()
    }

    private func syncFloatingCaptionVisibility() {
        isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen
    }

    private var autoDetectionLanguageChangeBinding: Binding<Bool> {
        Binding(
            get: {
                session.pendingAutoDetectionLanguageChange != nil
            },
            set: { isPresented in
                if !isPresented {
                    session.keepCurrentAutoDetectionLanguage()
                }
            }
        )
    }
}

private struct ToastMessageView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous)
                    .strokeBorder(AirTranslateDesign.separator.opacity(0.55))
            }
            .shadow(color: Color.black.opacity(0.14), radius: 10, y: 6)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
