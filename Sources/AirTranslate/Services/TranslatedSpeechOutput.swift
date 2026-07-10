import AVFAudio
import Foundation

final class TranslatedSpeechOutput: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private static let maximumQueuedUtterances = 3
    private static let catchUpRatePerQueuedUtterance: Float = 0.05
    private static let maximumCatchUpRateBoost: Float = 0.12

    private let synthesizer = AVSpeechSynthesizer()
    private var speechVolume: Float = 1
    private var queuedSpeechKeys: Set<String> = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func setVolume(_ volume: Double) {
        speechVolume = Float(min(max(volume, 0), 1))
    }

    func speak(_ text: String, language: LanguageOption) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let speechKey = normalizedSpeechKey(trimmedText, language: language)
        guard !queuedSpeechKeys.contains(speechKey) else { return }

        var backlogDepth = queuedSpeechKeys.count
        if backlogDepth > Self.maximumQueuedUtterances {
            // Live interpretation favors the newest text: skip the stale queue
            // instead of letting the synthesizer fall further behind.
            synthesizer.stopSpeaking(at: .word)
            queuedSpeechKeys.removeAll()
            backlogDepth = 0
        }

        queuedSpeechKeys.insert(speechKey)

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = AVSpeechSynthesisVoice(language: language.id)
        utterance.volume = speechVolume
        utterance.rate = Self.catchUpSpeechRate(backlogDepth: backlogDepth)
        synthesizer.speak(utterance)
    }

    static func catchUpSpeechRate(backlogDepth: Int) -> Float {
        let boost = min(
            catchUpRatePerQueuedUtterance * Float(max(backlogDepth, 0)),
            maximumCatchUpRateBoost
        )
        return AVSpeechUtteranceDefaultSpeechRate + boost
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queuedSpeechKeys.removeAll()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        removeQueuedSpeechKey(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        removeQueuedSpeechKey(for: utterance)
    }

    private func removeQueuedSpeechKey(for utterance: AVSpeechUtterance) {
        let languageID = utterance.voice?.language ?? Locale.current.identifier
        let language = LanguageOption(id: languageID, title: languageID, locale: Locale(identifier: languageID))
        queuedSpeechKeys.remove(normalizedSpeechKey(utterance.speechString, language: language))
    }

    private func normalizedSpeechKey(_ text: String, language: LanguageOption) -> String {
        let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: language.locale)
        let allowedCharacters = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespacesAndNewlines)
        let filteredText = String(foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        })

        return filteredText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
