import Foundation
import AirTranslateCore

struct SentencePair: Identifiable, Equatable {
    let id: String
    let source: String
    let translated: String?
    let startsParagraph: Bool
}

struct CaptionLine: Identifiable, Equatable {
    private static let maxDisplayCharacters = 4_000

    let id: UUID
    let sourceText: String
    let sourceDisplayText: String
    let translatedText: String
    let translatedDisplayText: String
    let translatedSourceText: String
    let translationsBySentence: [String: String]
    let createdAt: Date
    let isFinal: Bool
    let revision: Int

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        translatedSourceText: String = "",
        translationsBySentence: [String: String] = [:],
        createdAt: Date,
        isFinal: Bool,
        revision: Int = 0,
        usesLongSessionDisplay: Bool = false
    ) {
        self.id = id
        self.sourceText = sourceText
        self.sourceDisplayText = Self.displayText(for: sourceText, usesLongSessionDisplay: usesLongSessionDisplay)
        self.translatedText = translatedText
        self.translatedDisplayText = Self.displayText(for: translatedText, usesLongSessionDisplay: usesLongSessionDisplay)
        self.translatedSourceText = translatedSourceText
        self.translationsBySentence = translationsBySentence
        self.createdAt = createdAt
        self.isFinal = isFinal
        self.revision = revision
    }

    func sentencePairs(sourceLanguageID: String) -> [SentencePair] {
        var pairs: [SentencePair] = []
        for (paragraphIndex, sentences) in TranscriptTextProcessor.sentenceGroups(from: sourceText, languageID: sourceLanguageID).enumerated() {
            for (sentenceIndex, sentence) in sentences.enumerated() {
                pairs.append(
                    SentencePair(
                        id: "\(id.uuidString)-\(pairs.count)",
                        source: sentence,
                        translated: translationsBySentence[sentence],
                        startsParagraph: paragraphIndex > 0 && sentenceIndex == 0
                    )
                )
            }
        }
        return pairs
    }

    private static func displayText(for text: String, usesLongSessionDisplay: Bool) -> String {
        guard usesLongSessionDisplay || text.count > Self.maxDisplayCharacters else { return text }

        return TranscriptTextProcessor.displayTail(
            from: text,
            maxCharacters: Self.maxDisplayCharacters
        )
    }
}
