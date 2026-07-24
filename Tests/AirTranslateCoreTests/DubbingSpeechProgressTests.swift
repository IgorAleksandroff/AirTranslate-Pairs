import Foundation
import Testing
@testable import AirTranslateCore

@Suite
struct DubbingSpeechProgressTests {
    @Test
    func shorterStreamingRewriteDoesNotMakeRestoredSentenceSpeakTail() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "We will focus on real-time translation.",
            languageID: "en-US",
            isFinal: true
        ) == "We will focus on real-time translation.")
        #expect(progress.unspokenText(from: "We will focus", languageID: "en-US") == nil)
        #expect(progress.unspokenText(
            from: "We will focus on real-time translation.",
            languageID: "en-US"
        ) == nil)
        #expect(progress.unspokenText(
            from: "We will focus on real-time translation. Next sentence.",
            languageID: "en-US",
            isFinal: true
        ) == "Next sentence.")
    }

    @Test
    func streamingTextRequiresTerminatorAndStabilityBeforeSpeech() {
        var currentDate = Date(timeIntervalSinceReferenceDate: 100)
        var progress = DubbingSpeechProgress(now: { currentDate })

        #expect(progress.unspokenText(
            from: "We will focus on real-time translation",
            languageID: "en-US"
        ) == nil)

        currentDate = currentDate.addingTimeInterval(0.3)
        #expect(progress.unspokenText(
            from: "We will focus on real-time translation.",
            languageID: "en-US"
        ) == nil)

        currentDate = currentDate.addingTimeInterval(0.91)
        #expect(progress.unspokenText(
            from: "We will focus on real-time translation.",
            languageID: "en-US"
        ) == "We will focus on real-time translation.")
    }

    @Test
    func finalUnterminatedTranslationSpeaksImmediately() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "Final translation without punctuation",
            languageID: "en-US",
            isFinal: true
        ) == "Final translation without punctuation")
    }

    @Test
    func sameSentenceRefinalizationRevisionIsAdoptedWithoutRepeating() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "We're going to focus on real-time translation.",
            languageID: "en-US",
            isFinal: true
        ) == "We're going to focus on real-time translation.")
        #expect(progress.unspokenText(
            from: "We are going to focus on real-time translation.",
            languageID: "en-US",
            isFinal: true
        ) == nil)
        #expect(progress.unspokenText(
            from: "We are going to focus on real-time translation. Please watch the captions.",
            languageID: "en-US",
            isFinal: true
        ) == "Please watch the captions.")
    }

    @Test
    func nearDuplicateFinalizationVariantIsSuppressed() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "今天我们关注实时翻译的发展。",
            languageID: "zh-CN",
            isFinal: true
        ) != nil)
        #expect(progress.unspokenText(
            from: "今天我们关注实时翻译技术的发展。",
            languageID: "zh-CN",
            isFinal: true
        ) == nil)
    }

    @Test
    func appendedShortSentenceIsNotMistakenForRevision() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "The presentation is ready.",
            languageID: "en-US",
            isFinal: true
        ) == "The presentation is ready.")
        #expect(progress.unspokenText(
            from: "The presentation is ready. Go.",
            languageID: "en-US",
            isFinal: true
        ) == "Go.")
    }

    @Test
    func shortSuffixTailReplayIsSuppressedAfterSpokenSentence() {
        var progress = DubbingSpeechProgress()

        #expect(progress.unspokenText(
            from: "The meeting will start now.",
            languageID: "en-US",
            isFinal: true
        ) == "The meeting will start now.")
        #expect(progress.unspokenText(
            from: "The meeting will start now. start now.",
            languageID: "en-US",
            isFinal: true
        ) == nil)
        #expect(progress.unspokenText(
            from: "The meeting will start now. Please take your seats.",
            languageID: "en-US",
            isFinal: true
        ) == "Please take your seats.")
    }

    @Test
    func spokenMemoryExpiresSoLegitimateLaterRepeatsCanSpeak() {
        var currentDate = Date(timeIntervalSinceReferenceDate: 200)
        var progress = DubbingSpeechProgress(now: { currentDate })

        #expect(progress.unspokenText(
            from: "Please join the meeting.",
            languageID: "en-US",
            isFinal: true
        ) == "Please join the meeting.")
        #expect(progress.unspokenText(
            from: "Please join the meeting. Please join the meeting.",
            languageID: "en-US",
            isFinal: true
        ) == nil)

        currentDate = currentDate.addingTimeInterval(46)
        #expect(progress.unspokenText(
            from: "Please join the meeting. Please join the meeting. Please join the meeting.",
            languageID: "en-US",
            isFinal: true
        ) == "Please join the meeting.")
    }

    @Test
    func primedExistingTranslationDoesNotSpeakWhenDubbingTurnsOn() {
        var progress = DubbingSpeechProgress()

        progress.prime(with: "Already visible translation.", languageID: "en-US")

        #expect(progress.unspokenText(
            from: "Already visible translation.",
            languageID: "en-US"
        ) == nil)
        #expect(progress.unspokenText(
            from: "Already visible translation. Newly translated sentence.",
            languageID: "en-US",
            isFinal: true
        ) == "Newly translated sentence.")
    }
}
