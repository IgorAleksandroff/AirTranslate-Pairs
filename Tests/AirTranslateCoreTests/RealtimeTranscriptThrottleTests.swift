import Foundation
import Testing
@testable import AirTranslate

private final class TranscriptPublishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var publishedTexts: [String] = []

    func record(_ text: String) {
        lock.lock()
        publishedTexts.append(text)
        lock.unlock()
    }

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return publishedTexts
    }
}

@Suite
struct RealtimeTranscriptThrottleTests {
    @Test
    func firstDeltaPublishesImmediately() {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("Hello") { recorder.record($0) }

        #expect(recorder.texts == ["Hello"])
    }

    @Test
    func trailingFlushPublishesSuppressedTailAfterSilence() async throws {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("Hello") { recorder.record($0) }
        throttle.append(" wor") { recorder.record($0) }
        throttle.append("ld") { recorder.record($0) }

        try await Task.sleep(for: .seconds(0.3))

        #expect(recorder.texts.last == "Hello world")
    }

    @Test
    func resetCancelsPendingTrailingFlush() async throws {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("Hello") { recorder.record($0) }
        throttle.append(" world") { recorder.record($0) }
        throttle.reset()
        let publishedBeforeWait = recorder.texts

        try await Task.sleep(for: .seconds(0.3))

        #expect(recorder.texts == publishedBeforeWait)
    }

    @Test
    func resetClearsBufferAndThrottleWindowForNextUtterance() async throws {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("Hello") { recorder.record($0) }
        throttle.append(" world") { recorder.record($0) }
        throttle.reset()

        throttle.append("Next") { recorder.record($0) }

        #expect(recorder.texts.last == "Next")

        try await Task.sleep(for: .seconds(0.3))

        #expect(recorder.texts.last == "Next")
    }

    @Test
    func emptyCompletedTranscriptFlushesSuppressedTailImmediately() async throws {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("Hello") { recorder.record($0) }
        throttle.append(" world") { recorder.record($0) }
        throttle.finish(finalText: "") { recorder.record($0) }

        #expect(recorder.texts == ["Hello", "Hello world"])

        try await Task.sleep(for: .seconds(0.3))

        #expect(recorder.texts == ["Hello", "Hello world"])
    }

    @Test
    func nonemptyCompletedTranscriptReplacesBufferedDeltas() {
        let throttle = RealtimeTranscriptPublishThrottle(publishInterval: 0.05)
        let recorder = TranscriptPublishRecorder()

        throttle.append("rough") { recorder.record($0) }
        throttle.append(" draft") { recorder.record($0) }
        throttle.finish(finalText: "Final transcript") { recorder.record($0) }

        #expect(recorder.texts == ["rough", "Final transcript"])
    }
}
