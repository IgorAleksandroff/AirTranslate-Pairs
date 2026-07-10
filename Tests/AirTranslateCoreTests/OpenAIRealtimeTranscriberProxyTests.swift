import Foundation
import Testing
@testable import AirTranslate

private final class OpenAIRealtimeProxyRecorder: LiveSpeechTranscriberDelegate {
    private(set) var transcriberIDs: [ObjectIdentifier] = []
    private(set) var transcripts: [String] = []

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        transcriberIDs.append(ObjectIdentifier(transcriber))
        transcripts.append(text)
    }

    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {}
}

@Suite
struct OpenAIRealtimeTranscriberProxyTests {
    @Test
    func completedEventsReuseDelegateProxy() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = OpenAIRealtimeProxyRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"First"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Second"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
        #expect(recorder.transcriberIDs.count == 2)
        #expect(Set(recorder.transcriberIDs).count == 1)
    }
}
