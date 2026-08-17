import Foundation
import Testing
@testable import AirTranslate
@testable import AirTranslateCore

@Suite
struct SentencePairTests {
    @Test
    func sentenceGroupsSplitCommittedLinesAndRawPartialTheSameWay() {
        let text = "First sentence.\nSecond one!\n\nNew paragraph. still speaking here"
        let groups = TranscriptTextProcessor.sentenceGroups(from: text, languageID: "en-US")

        #expect(groups == [
            ["First sentence.", "Second one!"],
            ["New paragraph.", "still speaking here"]
        ])
    }

    @Test
    func longSentencesSplitAtClausesButShortFragmentsStayGlued() {
        #expect(TranscriptTextProcessor.clauses(from: "Yes, I agree with that.") == ["Yes, I agree with that."])
        #expect(TranscriptTextProcessor.clauses(
            from: "When we looked at the numbers last quarter, the churn was higher than expected, so we changed the plan."
        ) == [
            "When we looked at the numbers last quarter,",
            "the churn was higher than expected,",
            "so we changed the plan."
        ])
        #expect(TranscriptTextProcessor.clauses(
            from: "Well, honestly the roadmap for next year depends on the budget we get in January."
        ) == [
            "Well, honestly the roadmap for next year depends on the budget we get in January."
        ])
        #expect(TranscriptTextProcessor.clauses(
            from: "We shipped about 1,000 units in the first month and the customers were happy with it."
        ) == [
            "We shipped about 1,000 units in the first month and the customers were happy with it."
        ])
    }

    @Test
    func clauseThresholdCountsContentWordsOnly() {
        // 5 content words ("Yes I agree that plan") + function words → not long.
        #expect(TranscriptTextProcessor.clauses(from: "Yes, I agree with the plan.") == ["Yes, I agree with the plan."])
        // 6 content words → long, split at the comma; both clauses have ≥3 content words.
        #expect(TranscriptTextProcessor.clauses(from: "Yes I agree completely, we ship tomorrow morning.")
            == ["Yes I agree completely,", "we ship tomorrow morning."])
    }

    @Test
    func appendOnlyPartialKeepsShownWordsAndGrowsTail() {
        #expect(TranscriptTextProcessor.appendOnlyPartialText(current: "", incoming: "I think") == "I think")
        #expect(TranscriptTextProcessor.appendOnlyPartialText(current: "I think we sh", incoming: "I think we should")
            == "I think we should")
        #expect(TranscriptTextProcessor.appendOnlyPartialText(current: "I think we should", incoming: "I thing we shall go now")
            == "I think we shall go now")
        #expect(TranscriptTextProcessor.appendOnlyPartialText(current: "alpha bravo juliet", incoming: "alpha bravo kilogram")
            == "alpha bravo kilogram")
        #expect(TranscriptTextProcessor.appendOnlyPartialText(current: "I think we should go", incoming: "I think we")
            == "I think we should go")
    }

    @Test
    func sentencePairsLookUpTranslationsAndMarkParagraphStarts() {
        let line = CaptionLine(
            sourceText: "Hello there.\nHow are you?\n\nI am fine",
            translatedText: "Привет.\nКак дела?",
            translatedSourceText: "Hello there.\nHow are you?",
            translationsBySentence: [
                "Hello there.": "Привет.",
                "How are you?": "Как дела?"
            ],
            createdAt: Date(),
            isFinal: false
        )

        let pairs = line.sentencePairs(sourceLanguageID: "en-US")

        #expect(pairs.map(\.source) == ["Hello there.", "How are you?", "I am fine"])
        #expect(pairs.map(\.translated) == ["Привет.", "Как дела?", nil])
        #expect(pairs.map(\.startsParagraph) == [false, false, true])
        #expect(Set(pairs.map(\.id)).count == 3)
    }
}
