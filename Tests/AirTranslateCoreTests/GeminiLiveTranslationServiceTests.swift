import Foundation
import Testing
@testable import AirTranslate

@Suite
struct GeminiLiveTranslationServiceTests {
    @Test
    func serverEventPublishesTranscriptsAndTranslatedAudio() {
        let service = GeminiLiveTranslationService()
        let delegate = GeminiLiveTranslationProbe()
        service.delegate = delegate

        service.handleEventText("""
        {
          "serverContent": {
            "inputTranscription": {
              "text": "hello",
              "languageCode": "en"
            },
            "outputTranscription": {
              "text": "안녕하세요",
              "languageCode": "ko"
            },
            "modelTurn": {
              "parts": [
                {
                  "inlineData": {
                    "data": "AQIDBA==",
                    "mimeType": "audio/pcm;rate=24000"
                  }
                }
              ]
            }
          }
        }
        """)

        #expect(delegate.inputTranscript == "hello")
        #expect(delegate.outputTranscript == "안녕하세요")
        #expect(delegate.audio == "AQIDBA==")
        #expect(delegate.sampleRate == 24_000)
    }

    @Test
    func outputAudioSampleRateFallsBackToGeminiLiveDefault() {
        #expect(GeminiLiveTranslationService.outputAudioSampleRate(from: nil) == 24_000)
        #expect(GeminiLiveTranslationService.outputAudioSampleRate(from: "audio/pcm") == 24_000)
        #expect(GeminiLiveTranslationService.outputAudioSampleRate(from: "audio/pcm;rate=22050") == 22_050)
    }

    @Test
    func setupCompleteMarksRealtimeInputReady() {
        let service = GeminiLiveTranslationService()

        #expect(!service.isReadyForRealtimeInput)

        service.handleEventText(#"{"setupComplete":{}}"#)

        #expect(service.isReadyForRealtimeInput)
    }

    @Test
    func setupMessageConfiguresAutomaticActivityDetection() throws {
        let data = try GeminiLiveTranslationService.encodedSetupMessage(
            model: .gemini35LiveTranslate,
            targetLanguage: .korean
        )

        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try #require(root["setup"] as? [String: Any])
        let realtimeInputConfig = try #require(setup["realtimeInputConfig"] as? [String: Any])
        let detection = try #require(realtimeInputConfig["automaticActivityDetection"] as? [String: Any])

        #expect(detection["startOfSpeechSensitivity"] as? String == "START_SENSITIVITY_HIGH")
        #expect(detection["endOfSpeechSensitivity"] as? String == "END_SENSITIVITY_HIGH")
        #expect(detection["silenceDurationMs"] as? Int == 250)
        #expect(detection["prefixPaddingMs"] as? Int == 120)
        #expect(setup["model"] as? String == "models/gemini-3.5-live-translate-preview")
    }

    @Test
    func preSetupAudioIsBufferedUntilSetupCompletes() {
        let service = GeminiLiveTranslationService()

        service.sendOrBufferAudioChunks(["Zmlyc3Q=", "c2Vjb25k"])

        #expect(!service.isReadyForRealtimeInput)
        #expect(service.bufferedPreSetupAudioChunks == ["Zmlyc3Q=", "c2Vjb25k"])

        service.handleEventText(#"{"setupComplete":{}}"#)

        #expect(service.isReadyForRealtimeInput)
        #expect(service.bufferedPreSetupAudioChunks.isEmpty)

        service.sendOrBufferAudioChunks(["dGhpcmQ="])

        #expect(service.bufferedPreSetupAudioChunks.isEmpty)
    }

    @Test
    func preSetupAudioBufferDropsOldestChunksBeyondCap() {
        let service = GeminiLiveTranslationService()
        let chunkCharacterCount = 40_000
        let chunks = ["A", "B", "C", "D"].map { String(repeating: $0, count: chunkCharacterCount) }

        for chunk in chunks {
            service.sendOrBufferAudioChunks([chunk])
        }

        #expect(service.bufferedPreSetupAudioChunks == Array(chunks.dropFirst()))
    }

    @Test
    func coalescedAudioChunksRechunkBufferedAudioInOrder() {
        let service = GeminiLiveTranslationService()
        let first = Data((0..<5_000).map { UInt8($0 % 251) })
        let second = Data(repeating: 0x7F, count: 3_000)

        let chunks = service.coalescedAudioChunks([
            first.base64EncodedString(),
            second.base64EncodedString()
        ])

        #expect(chunks.count == 3)
        let reassembled = chunks.compactMap { Data(base64Encoded: $0) }.reduce(Data(), +)
        #expect(reassembled == first + second)
    }

    @Test
    func socketNotConnectedErrorsAreDetectedByErrorCode() {
        let posixNotConnected = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOTCONN),
            userInfo: [NSLocalizedDescriptionKey: "소켓이 연결되어 있지 않습니다"]
        )
        let connectionLost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        let wrapped = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnknown,
            userInfo: [NSUnderlyingErrorKey: posixNotConnected]
        )
        let unrelated = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        #expect(GeminiLiveTranslationService.isSocketNotConnectedError(posixNotConnected))
        #expect(GeminiLiveTranslationService.isSocketNotConnectedError(connectionLost))
        #expect(GeminiLiveTranslationService.isSocketNotConnectedError(wrapped))
        #expect(!GeminiLiveTranslationService.isSocketNotConnectedError(unrelated))
    }

    @Test
    func connectionErrorsDoNotExposeAuthenticatedWebSocketURL() {
        let secret = "test-secret-key"
        let authenticatedURL = URL(
            string: "wss://generativelanguage.googleapis.com/ws/example?key=\(secret)"
        )!
        let rawError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLErrorKey: authenticatedURL,
                NSLocalizedDescriptionKey: "Failed to connect to \(authenticatedURL.absoluteString)"
            ]
        )

        let publicError = GeminiLiveTranslationService.publicConnectionError(from: rawError)

        #expect(publicError.localizedDescription == AppText.geminiConnectionFailed)
        #expect(!publicError.localizedDescription.contains(secret))
        #expect(!publicError.localizedDescription.contains("?key="))
    }

    @Test
    func connectionObserverResumesAfterSocketOpens() async throws {
        let observer = GeminiLiveWebSocketConnectionObserver()
        let session = URLSession.shared
        let task = session.webSocketTask(with: URL(string: "wss://localhost")!)
        defer { task.cancel() }

        observer.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)

        try await observer.waitForOpen(timeoutMilliseconds: 1_000)
    }

    @Test
    func connectionObserverTimesOutWithoutOpenCallback() async {
        let observer = GeminiLiveWebSocketConnectionObserver()

        do {
            try await observer.waitForOpen(timeoutMilliseconds: 50)
            Issue.record("expected waitForOpen to time out")
        } catch GeminiLiveTranslationError.setupTimedOut {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func connectionObserverPropagatesTaskCompletionFailure() async {
        let observer = GeminiLiveWebSocketConnectionObserver()
        let session = URLSession.shared
        let task = session.webSocketTask(with: URL(string: "wss://localhost")!)
        defer { task.cancel() }
        let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))

        observer.urlSession(session, task: task, didCompleteWithError: failure)

        do {
            try await observer.waitForOpen(timeoutMilliseconds: 1_000)
            Issue.record("expected waitForOpen to rethrow the completion failure")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSPOSIXErrorDomain)
            #expect(nsError.code == Int(ECONNREFUSED))
        }
    }
}

private final class GeminiLiveTranslationProbe: GeminiLiveTranslationServiceDelegate {
    var inputTranscript = ""
    var outputTranscript = ""
    var audio = ""
    var sampleRate = 0.0
    var didInterrupt = false
    var error: Error?

    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveInputTranscript text: String,
        languageCode _: String?
    ) {
        inputTranscript = text
    }

    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveOutputTranscript text: String,
        languageCode _: String?
    ) {
        outputTranscript = text
    }

    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    ) {
        self.audio = audio
        self.sampleRate = sampleRate
    }

    func geminiLiveTranslationServiceDidInterruptOutputAudio(_ service: GeminiLiveTranslationService) {
        didInterrupt = true
    }

    func geminiLiveTranslationService(_ service: GeminiLiveTranslationService, didFail error: Error) {
        self.error = error
    }
}
