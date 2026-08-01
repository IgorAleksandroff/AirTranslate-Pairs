import Testing
@testable import AirTranslate

@Suite
struct SessionConfigurationUIStateTests {
    @Test
    func menuBarStartingPhaseOffersCancellationAndReportsCurrentStatus() {
        let phase = MenuBarCapturePhase(
            isRunning: false,
            isStarting: true,
            isPaused: false
        )
        let status = AppText.connectingGeminiLiveTranslation

        #expect(phase == .starting)
        #expect(phase.actionSystemImage == "xmark")
        #expect(phase.actionTitle == AppText.cancel)
        #expect(phase.actionSubtitle(statusMessage: status) == status)
    }

    @Test
    func menuBarIdleAndRunningPhasesPreserveStartStopActions() {
        let idle = MenuBarCapturePhase(
            isRunning: false,
            isStarting: false,
            isPaused: false
        )
        let running = MenuBarCapturePhase(
            isRunning: true,
            isStarting: false,
            isPaused: false
        )

        #expect(idle.actionTitle == AppText.start)
        #expect(idle.actionSystemImage == "play.fill")
        #expect(running.actionTitle == AppText.stop)
        #expect(running.actionSystemImage == "stop.fill")

        let paused = MenuBarCapturePhase(
            isRunning: true,
            isStarting: false,
            isPaused: true
        )

        #expect(paused == .paused)
        #expect(paused.actionTitle == AppText.stop)
        #expect(paused.actionSystemImage == "stop.fill")
        #expect(paused.actionSubtitle(statusMessage: "ignored") == AppText.paused)
    }

    @Test
    func sidebarConfigurationIsLockedForRunningOrStartingSessions() {
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: false,
                isStarting: false
            ) == false
        )
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: true,
                isStarting: false
            )
        )
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: false,
                isStarting: true
            )
        )
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: true,
                isStarting: true
            )
        )
    }
}
