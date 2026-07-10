import Foundation
import Testing
@testable import AirTranslate

@Suite
struct FloatingCaptionWindowFrameVisibilityTests {
    private let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondaryScreen = NSRect(x: 1920, y: 0, width: 1440, height: 900)

    @Test
    func frameInsideScreenIsVisible() {
        let frame = NSRect(x: 600, y: 120, width: 720, height: 170)

        #expect(FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: [mainScreen]))
    }

    @Test
    func frameOnSecondaryScreenIsVisible() {
        let frame = NSRect(x: 2200, y: 200, width: 720, height: 170)

        #expect(FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: [mainScreen, secondaryScreen]))
    }

    @Test
    func frameFromDisconnectedDisplayIsNotVisible() {
        let frame = NSRect(x: 2200, y: 200, width: 720, height: 170)

        #expect(!FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: [mainScreen]))
    }

    @Test
    func frameBarelyOverlappingScreenEdgeIsNotVisible() {
        let frame = NSRect(x: 1920 - 40, y: 120, width: 720, height: 170)

        #expect(!FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: [mainScreen]))
    }

    @Test
    func sufficientOverlapAtScreenEdgeIsVisible() {
        let frame = NSRect(x: 1920 - 200, y: 120, width: 720, height: 170)

        #expect(FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: [mainScreen]))
    }

    @Test
    func corruptZeroFrameIsNotVisible() {
        #expect(!FloatingCaptionWindowController.frameIsReasonablyVisible(.zero, within: [mainScreen]))
    }

    @Test
    func frameIsNotVisibleWithoutScreens() {
        let frame = NSRect(x: 600, y: 120, width: 720, height: 170)

        #expect(!FloatingCaptionWindowController.frameIsReasonablyVisible(frame, within: []))
    }
}
