import Foundation
import Observation
import os

/// Heuristic bidirectional word alignment: every content word is translated on its own with
/// Apple Translation (both directions, cached per word) and matched against the other side by stem.
@MainActor
@Observable
final class WordAlignmentStore {
    private static let logger = Logger(subsystem: "com.igor.AirTranslatePairs", category: "WordAlignment")
    private static let functionWords: Set<String> = [
        // English
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "by", "with", "from", "into", "onto", "over",
        "under", "about", "as", "and", "or", "but", "so", "nor", "if", "than", "up", "out", "off", "is", "are",
        "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those", "i", "we", "you", "he",
        "she", "they", "my", "our", "your", "his", "her", "their", "do", "does", "did", "not", "no", "yes",
        "will", "would", "can", "could", "should", "have", "has", "had", "there", "here", "just", "very",
        // Russian
        "и", "в", "во", "на", "с", "со", "к", "ко", "о", "об", "от", "до", "по", "за", "из", "у", "не", "ни",
        "что", "это", "как", "для", "а", "но", "или", "же", "бы", "ли", "то", "так", "чтобы", "при", "без",
        "над", "под", "про", "он", "она", "они", "оно", "мы", "вы", "я", "ты", "его", "её", "их", "мой", "наш",
        "ваш", "этот", "эта", "эти", "тот", "та", "те", "да", "нет", "есть", "был", "была", "было", "были",
        "будет", "быть", "уже", "ещё", "очень", "там", "тут", "здесь", "вот"
    ]

    private(set) var alignments: [String: SentenceAlignment] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var wordCandidates: [String: [String]] = [:]
    @ObservationIgnored private let translator = AppleTranslationService()

    func alignment(source: String, target: String) -> SentenceAlignment? {
        alignments[Self.key(source, target)]
    }

    func requestAlignment(
        source: String,
        target: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption
    ) async {
        let key = Self.key(source, target)
        guard alignments[key] == nil, !inFlight.contains(key), !failed.contains(key) else { return }
        guard sourceLanguage.id != targetLanguage.id else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let sourceTokens = WordTokens.split(source).map(WordTokens.normalized)
        let targetTokens = WordTokens.split(target).map(WordTokens.normalized)
        let sourceContent = sourceTokens.indices.filter { Self.isContentWord(sourceTokens[$0]) }
        let targetContent = targetTokens.indices.filter { Self.isContentWord(targetTokens[$0]) }

        do {
            try await cacheCandidates(for: sourceContent.map { sourceTokens[$0] }, from: sourceLanguage, to: targetLanguage)
            try await cacheCandidates(for: targetContent.map { targetTokens[$0] }, from: targetLanguage, to: sourceLanguage)
        } catch {
            failed.insert(key)
            Self.logger.error("word alignment failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }

        var pairs: [(Int, Int)] = []
        for i in sourceContent {
            let candidates = wordCandidates[Self.candidateKey(sourceTokens[i], sourceLanguage, targetLanguage)] ?? []
            for j in targetContent {
                let target = targetTokens[j]
                if sourceTokens[i] == target || candidates.contains(where: { WordTokens.stemsMatch($0, target) }) {
                    pairs.append((i, j))
                }
            }
        }
        for j in targetContent {
            let candidates = wordCandidates[Self.candidateKey(targetTokens[j], targetLanguage, sourceLanguage)] ?? []
            for i in sourceContent where candidates.contains(where: { WordTokens.stemsMatch($0, sourceTokens[i]) }) {
                pairs.append((i, j))
            }
        }
        alignments[key] = SentenceAlignment(pairs: pairs)
    }

    private func cacheCandidates(for words: [String], from source: LanguageOption, to target: LanguageOption) async throws {
        let missing = Array(Set(words.filter { wordCandidates[Self.candidateKey($0, source, target)] == nil }))
        guard !missing.isEmpty else { return }
        let translations = try await translator.translateBatch(missing, source: source, target: target)
        for (word, translation) in zip(missing, translations) {
            let candidates = translation
                .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
                .map { WordTokens.normalized(String($0)) }
                .filter { Self.isContentWord($0) }
            wordCandidates[Self.candidateKey(word, source, target)] = candidates
        }
    }

    private static func isContentWord(_ token: String) -> Bool {
        guard token.count >= 2 || token.contains(where: \.isNumber) else { return false }
        guard token.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return !functionWords.contains(token)
    }

    private static func key(_ source: String, _ target: String) -> String {
        source + "\u{1F}" + target
    }

    private static func candidateKey(_ word: String, _ source: LanguageOption, _ target: LanguageOption) -> String {
        "\(source.id)>\(target.id)\u{1F}\(word)"
    }
}
