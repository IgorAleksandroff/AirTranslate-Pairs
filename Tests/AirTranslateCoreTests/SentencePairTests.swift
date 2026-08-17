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
    func longClausesWithoutPunctuationSplitBeforeConjunctions() {
        let sentence = "A 2025 peer reviewed study in frontiers in psychology found that gamification feature richness follows an S shaped curb,"
        #expect(TranscriptTextProcessor.clauses(from: sentence) == [
            "A 2025 peer reviewed study in frontiers in psychology found",
            "that gamification feature richness follows an S shaped curb,"
        ])
        // Greedy: the split of the growing prefix matches the split of the full sentence.
        let prefix = "A 2025 peer reviewed study in frontiers in psychology found that gamification feature richness"
        #expect(TranscriptTextProcessor.clauses(from: prefix).first == "A 2025 peer reviewed study in frontiers in psychology found")
        // No conjunction at all: cut on a word boundary once the limit is passed.
        let plain = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
        #expect(TranscriptTextProcessor.clauses(from: plain) == [
            "one two three four five six seven eight nine ten",
            "eleven twelve thirteen fourteen"
        ])
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
    func stemMatchingToleratesInflectionButNotShortPrefixes() {
        #expect(WordTokens.stemsMatch("исследование", "исследования"))
        #expect(WordTokens.stemsMatch("показало", "показывает"))
        #expect(WordTokens.stemsMatch("studies", "study"))
        #expect(!WordTokens.stemsMatch("подход", "поднял"))
        #expect(!WordTokens.stemsMatch("found", "find"))
        #expect(WordTokens.normalized("(2025),") == "2025")
    }

    @Test
    func alignmentIsBidirectional() {
        let alignment = SentenceAlignment(pairs: [(0, 2), (0, 3), (4, 1)])
        #expect(alignment.sourceToTarget[0] == [2, 3])
        #expect(alignment.targetToSource[1] == [4])
        #expect(alignment.targetToSource[2] == [0])
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
