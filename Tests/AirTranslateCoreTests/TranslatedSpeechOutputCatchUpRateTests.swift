import AVFAudio
import Foundation
import Testing
@testable import AirTranslate

@Suite
struct TranslatedSpeechOutputCatchUpRateTests {
    @Test
    func emptyBacklogUsesDefaultSpeechRate() {
        let rate = TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: 0)

        #expect(rate == AVSpeechUtteranceDefaultSpeechRate)
    }

    @Test
    func rateAcceleratesAsBacklogGrows() {
        let shallowBacklogRate = TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: 1)
        let deeperBacklogRate = TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: 2)

        #expect(shallowBacklogRate > AVSpeechUtteranceDefaultSpeechRate)
        #expect(deeperBacklogRate > shallowBacklogRate)
    }

    @Test
    func rateIsCappedForDeepBacklogs() {
        let cappedRate = TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: 100)

        #expect(cappedRate == TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: 3))
        #expect(cappedRate <= AVSpeechUtteranceDefaultSpeechRate + 0.12)
        #expect(cappedRate < AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test
    func negativeBacklogDoesNotSlowSpeech() {
        let rate = TranslatedSpeechOutput.catchUpSpeechRate(backlogDepth: -1)

        #expect(rate == AVSpeechUtteranceDefaultSpeechRate)
    }
}
