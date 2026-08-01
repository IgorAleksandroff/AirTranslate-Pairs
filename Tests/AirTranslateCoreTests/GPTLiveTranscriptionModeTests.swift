import Foundation
import Testing
@testable import AirTranslate

private final class GPTLiveTranscriptionRecorder: LiveSpeechTranscriberDelegate {
    private(set) var transcripts: [String] = []
    private(set) var errors: [Error] = []

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        transcripts.append(text)
    }

    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {
        errors.append(error)
    }
}

private final class OpenAIAudioDegradationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RealtimeAudioTransportDegradation] = []

    var events: [RealtimeAudioTransportDegradation] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: RealtimeAudioTransportDegradation) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

@Suite(.serialized)
struct GPTLiveTranscriptionModeTests {
    @Test
    func liveTranscriptionModelHasCanonicalRawValue() {
        #expect(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue == "gpt-live-transcribe")
        #expect(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.isEnabled)
    }

    @Test
    func transcriptionSessionUsesCanonicalLiveTranscriptionContract() throws {
        let data = try OpenAIRealtimeTranscriber.transcriptionSessionUpdateData(
            language: .korean,
            modelID: OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(session["type"] as? String == "transcription")
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["languages"] as? [String] == ["ko"])
        #expect(transcription["language"] == nil)
        #expect(transcription["delay"] as? String == "low")
    }

    @Test
    func interleavedTranscriptionItemsKeepIndependentBuffers() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#
        )
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"Hello "}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"two","delta":"Good "}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Hello one"}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Good two"}"#)

        #expect(recorder.transcripts.suffix(2) == ["Hello one", "Good two"])
        #expect(!recorder.transcripts.contains(where: { $0.contains("Hello") && $0.contains("Good") }))
    }

    @Test
    func reverseCompletionUsesCommittedItemOrder() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.created","previous_item_id":"one","item":{"id":"assistant","role":"assistant","content":[{"type":"output_text"}]}}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"assistant"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Second"}"#
        )

        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"First"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
    }

    @Test
    func completionBeforeLifecycleMetadataWaitsForCausalOrder() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Second"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"First"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
    }

    @Test
    func orphanTerminalRecoversAfterBoundedMetadataGrace() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"orphan","transcript":"Recovered"}"#
        )
        for index in 0..<8 {
            transcriber.handleEventText(
                #"{"type":"conversation.item.created","item":{"id":"metadata-\#(index)","role":"assistant","content":[{"type":"output_text"}]}}"#
            )
        }

        #expect(recorder.transcripts == ["Recovered"])
        #expect(transcriber.trackedRealtimeTimelineItemCount == 0)
    }

    @Test
    func longTimelineKeepsOnlyBoundedPendingState() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        var previousItemID: String?
        for index in 0..<2_000 {
            let itemID = "item-\(index)"
            let previousJSON = previousItemID.map { "\"\($0)\"" } ?? "null"
            transcriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"\#(itemID)","previous_item_id":\#(previousJSON)}"#
            )
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(itemID)","transcript":"Transcript \#(index)"}"#
            )
            previousItemID = itemID
        }

        #expect(recorder.transcripts.count == 2_000)
        #expect(recorder.transcripts.first == "Transcript 0")
        #expect(recorder.transcripts.last == "Transcript 1999")
        #expect(
            transcriber.trackedRealtimeTimelineItemCount
                <= OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount
        )
    }

    @Test
    func pendingTimelineOverflowReportsSanitizedFailureInsteadOfSilentlyDroppingTranscript() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        for index in 0...OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount {
            transcriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"pending-\#(index)","previous_item_id":null}"#
            )
        }

        #expect(recorder.transcripts.isEmpty)
        #expect(recorder.errors.count == 1)
        #expect(recorder.errors.first?.localizedDescription == AppText.openAIInvalidResponse)
        #expect(
            transcriber.trackedRealtimeTimelineItemCount
                <= OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount
        )
    }

    @Test
    func failedItemReleasesItsPerItemThrottle() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"failed","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"failed","delta":"draft"}"#
        )
        #expect(transcriber.realtimeTranscriptionThrottleCount == 1)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"failed"}"#
        )

        #expect(transcriber.realtimeTranscriptionThrottleCount == 0)
        #expect(recorder.errors.count == 1)
    }

    @Test
    func stopRejectsEventsFromRetiredConnectionGeneration() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder
        let retiredGeneration = transcriber.currentConnectionGeneration

        transcriber.stop()
        transcriber.handleEventText(
            #"{"type":"error"}"#,
            generation: retiredGeneration
        )

        #expect(recorder.errors.isEmpty)
    }

    @Test
    func completionWithoutDeltaPublishesOnceAndIgnoresDelayedDelta() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Final text"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"late secret-bearing delta"}"#
        )
        try await Task.sleep(for: .milliseconds(80))

        #expect(recorder.transcripts == ["Final text"])
    }

    @Test
    func saturatedSendWindowReportsDroppedAudioDuration() {
        let transcriber = OpenAIRealtimeTranscriber()
        let callbackRecorder = OpenAIAudioDegradationRecorder()
        transcriber.onAudioTransportDegraded = { callbackRecorder.record($0) }
        let fortyMillisecondsOfPCM16 = 24_000 * 2 * 40 / 1_000

        for _ in 0..<48 {
            #expect(transcriber.reserveAudioSendSlot(audioByteCount: fortyMillisecondsOfPCM16))
        }
        #expect(!transcriber.reserveAudioSendSlot(audioByteCount: fortyMillisecondsOfPCM16))

        let degradation = transcriber.audioTransportDegradation
        #expect(callbackRecorder.events.count == 1)
        #expect(degradation?.provider == .openAI)
        #expect(degradation?.policy == .dropNewest)
        #expect(degradation?.phase == .sendWindow)
        #expect(degradation?.droppedChunkCount == 1)
        #expect(abs((degradation?.droppedAudioDuration ?? 0) - 0.04) < 0.000_1)
        #expect(degradation?.pendingSendCount == 48)
        #expect(degradation?.pendingSendLimit == 48)

        for _ in 0..<48 {
            transcriber.releaseAudioSendSlot()
        }
    }

    @Test
    func realtimeErrorsDoNotExposeSensitiveDiagnostics() {
        let secret = "test-secret-key"
        let authenticatedURL = URL(
            string: "wss://api.openai.com/v1/realtime?intent=transcription&key=\(secret)"
        )!
        let rawError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLErrorKey: authenticatedURL,
                NSLocalizedDescriptionKey: "Authorization: Bearer \(secret)"
            ]
        )

        let publicError = OpenAIRealtimeTranscriber.publicConnectionError(from: rawError)

        #expect(publicError.localizedDescription == AppText.openAIRealtimeConnectionFailed)
        #expect(!publicError.localizedDescription.contains(secret))
        #expect(!publicError.localizedDescription.contains("Bearer"))
    }

    @Test
    func serverErrorEventsDoNotExposeProviderMessages() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"error","error":{"message":"Authorization: Bearer test-secret-key"}}"#
        )

        #expect(recorder.errors.count == 1)
        #expect(recorder.errors.first?.localizedDescription == AppText.openAIRealtimeConnectionFailed)
        #expect(!recorder.errors.contains(where: { $0.localizedDescription.contains("test-secret-key") }))
    }

    @Test
    @MainActor
    func openAIProxyFailureStopsTheMatchingStoreGeneration() async {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        pipeline.openAITranscriber.handleEventText(#"{"type":"error"}"#)
        await Task.yield()

        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.openAIRealtimeConnectionFailed)
    }

    @Test
    @MainActor
    func pendingTimelineOverflowStopsTheActiveStoreGeneration() async {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        for index in 0...OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount {
            pipeline.openAITranscriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"pending-\#(index)","previous_item_id":null}"#
            )
        }
        await Task.yield()

        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.openAIInvalidResponse)
    }

    @Test
    @MainActor
    func staleProxyRecognitionCannotPolluteRestartedStoreGeneration() async {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        let firstPipeline = session.activateLiveCallbackPipelineForTesting()
        firstPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"queued-stale"}"#
        )
        session.stop()
        let secondPipeline = session.activateLiveCallbackPipelineForTesting()

        firstPipeline.openAITranscriber.delegate = session
        firstPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"retired-stale"}"#
        )
        secondPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"fresh"}"#
        )
        await Task.yield()

        #expect(!session.lines.contains(where: { $0.sourceText.contains("stale") }))
        #expect(session.lines.contains(where: { $0.sourceText.contains("fresh") }))
        session.stop()
    }

    @Test
    @MainActor
    func gptTranscriptionTransitionIsSourceOnlyAndRequiresOpenAIKey() {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        session.useGPTRealtimeMode()
        session.hasOpenAIAPIKey = false

        session.useGPTTranscriptionMode()

        #expect(session.openAITranscriptionModel == .gptLiveTranscribe)
        #expect(session.openAITranslationModel == .off)
        #expect(session.geminiTranslationModel == .off)
        #expect(session.isUsingOpenAIRealtime)
        #expect(!session.isUsingOpenAIRealtimeTranslation)
        #expect(session.isTranscribeOnlyMode)
        #expect(!session.shouldShowTranslationPane)
        #expect(session.floatingCaptionDisplayMode == .original)
        #expect(!session.isDubbingEnabled)
        #expect(session.startReadinessAssessment().issue == .openAIAPIKeyMissing)
    }

    @Test
    @MainActor
    func gptTranslationStillUsesTranslationModelAndWhisperSidecar() {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })

        session.useGPTRealtimeMode()

        #expect(session.openAITranslationModel == .gptRealtimeTranslate)
        #expect(session.openAITranscriptionModel == .off)
        #expect(OpenAIRealtimeTranscriptionModel.gptRealtimeWhisper.rawValue == "gpt-realtime-whisper")
    }

    @Test
    @MainActor
    func restorePreservesGPTTranscriptionMode() {
        let defaults = UserDefaults.standard
        let keys = ["selectedModelID", "openAITranscriptionModelID", "openAITranslationModelID", "geminiTranslationModelID"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(IntelligenceModel.appleSpeechOnly.rawValue, forKey: "selectedModelID")
        defaults.set(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue, forKey: "openAITranscriptionModelID")
        defaults.set(OpenAIRealtimeTranslationModel.gptRealtimeTranslate.rawValue, forKey: "openAITranslationModelID")
        defaults.set(GeminiTranslationModel.gemini35LiveTranslate.rawValue, forKey: "geminiTranslationModelID")

        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })

        #expect(session.isUsingGPTTranscriptionMode)
        #expect(session.openAITranslationModel == .off)
        #expect(session.geminiTranslationModel == .off)
        #expect(session.selectedModel == .appleSpeechOnly)
    }
}
