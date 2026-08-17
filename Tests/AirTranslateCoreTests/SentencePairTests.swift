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
