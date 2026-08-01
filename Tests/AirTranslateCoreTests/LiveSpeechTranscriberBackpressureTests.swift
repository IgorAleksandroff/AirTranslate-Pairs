import Foundation
import Testing
@testable import AirTranslate

private final class AppleSpeechBackpressureRecorder: LiveSpeechTranscriberDelegate {
    private let lock = NSLock()
    private var storedErrors: [LiveSpeechTranscriberError] = []

    var errors: [LiveSpeechTranscriberError] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {}

    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {
        guard let error = error as? LiveSpeechTranscriberError else { return }
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }
}

@Suite
struct LiveSpeechTranscriberBackpressureTests {
    @Test
    func suspendedAnalyzerReportsFirstDroppedInputAndTerminatesTheStream() async {
        let bufferLimit = 32
        let recorder = AppleSpeechBackpressureRecorder()
        let transcriber = LiveSpeechTranscriber(authorizationRequester: { false })
        transcriber.delegate = recorder
        let queue: SpeechAnalyzerInputQueue<Int> = transcriber.makeInputQueueForTesting(
            bufferLimit: bufferLimit
        )

        let accepted = (0..<bufferLimit).map { queue.yield($0) }
        #expect(accepted.allSatisfy { $0 == .enqueued })

        #expect(queue.yield(bufferLimit) == .dropped)
        #expect(queue.yield(bufferLimit + 1) == .terminated)
        #expect(
            recorder.errors == [
                .audioInputBackpressure(bufferLimit: bufferLimit)
            ]
        )

        var bufferedValues: [Int] = []
        for await value in queue.stream {
            bufferedValues.append(value)
        }
        #expect(bufferedValues == Array(1...bufferLimit))
    }

    @Test
    func consumedInputsRemainOrderedAndLosslessAcrossMoreThanTheBufferLimit() async {
        let recorder = AppleSpeechBackpressureRecorder()
        let transcriber = LiveSpeechTranscriber(authorizationRequester: { false })
        transcriber.delegate = recorder
        let queue: SpeechAnalyzerInputQueue<Int> = transcriber.makeInputQueueForTesting(
            bufferLimit: 32
        )
        var iterator = queue.stream.makeAsyncIterator()
        var consumed: [Int] = []

        for value in 0..<96 {
            #expect(queue.yield(value) == .enqueued)
            let next = await iterator.next()
            if let next {
                consumed.append(next)
            }
        }
        queue.finish()

        #expect(consumed == Array(0..<96))
        #expect(await iterator.next() == nil)
        #expect(recorder.errors.isEmpty)
    }

    @Test
    func finishedBackpressuredQueueDoesNotPoisonReplacementQueue() async {
        let recorder = AppleSpeechBackpressureRecorder()
        let transcriber = LiveSpeechTranscriber(authorizationRequester: { false })
        transcriber.delegate = recorder
        let firstQueue: SpeechAnalyzerInputQueue<Int> = transcriber.makeInputQueueForTesting(
            bufferLimit: 1
        )

        #expect(firstQueue.yield(1) == .enqueued)
        #expect(firstQueue.yield(2) == .dropped)
        #expect(firstQueue.yield(3) == .terminated)

        let replacementQueue: SpeechAnalyzerInputQueue<Int> = transcriber.makeInputQueueForTesting(
            bufferLimit: 1
        )
        var replacementIterator = replacementQueue.stream.makeAsyncIterator()
        #expect(replacementQueue.yield(4) == .enqueued)
        #expect(await replacementIterator.next() == 4)
        replacementQueue.finish()
        #expect(await replacementIterator.next() == nil)

        #expect(
            recorder.errors == [
                .audioInputBackpressure(bufferLimit: 1)
            ]
        )
    }
}
