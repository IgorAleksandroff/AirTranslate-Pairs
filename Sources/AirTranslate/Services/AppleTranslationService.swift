import Foundation
@preconcurrency import Translation

actor AppleTranslationService {
    private let availability = LanguageAvailability()
    private var sessionsByLanguagePair: [String: TranslationSession] = [:]
    private var availabilityByLanguagePair: [String: LanguageAvailability.Status] = [:]

    func prepare(
        source: LanguageOption,
        target: LanguageOption,
        model: IntelligenceModel
    ) async throws {
        guard model != .appleSpeechOnly else { return }

        let sourceLanguage = Locale.Language(identifier: source.id)
        let targetLanguage = Locale.Language(identifier: target.id)
        let cacheKey = languagePairKey(source: source, target: target)
        let status = try await availabilityStatus(
            source: sourceLanguage,
            target: targetLanguage,
            cacheKey: cacheKey,
            sourceTitle: source.localizedTitle,
            targetTitle: target.localizedTitle
        )
        guard status != .unsupported else {
            throw TranslationServiceError.unsupportedPair(source.localizedTitle, target.localizedTitle)
        }

        let session = translationSession(
            source: sourceLanguage,
            target: targetLanguage,
            cacheKey: cacheKey
        )
        if !(await session.isReady) {
            try await session.prepareTranslation()
        }
    }

    func translate(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        model: IntelligenceModel
    ) async throws -> String {
        guard !text.isEmpty else { return text }
        guard model != .appleSpeechOnly else { return text }

        let sourceLanguage = Locale.Language(identifier: source.id)
        let targetLanguage = Locale.Language(identifier: target.id)
        let cacheKey = languagePairKey(source: source, target: target)
        let status = try await availabilityStatus(
            source: sourceLanguage,
            target: targetLanguage,
            cacheKey: cacheKey,
            sourceTitle: source.localizedTitle,
            targetTitle: target.localizedTitle
        )

        guard status != .unsupported else {
            throw TranslationServiceError.unsupportedPair(source.localizedTitle, target.localizedTitle)
        }

        let session = translationSession(
            source: sourceLanguage,
            target: targetLanguage,
            cacheKey: cacheKey
        )
        if !(await session.isReady) {
            try await session.prepareTranslation()
        }

        let response = try await session.translate(text)
        return response.targetText
    }

    func translateBatch(
        _ texts: [String],
        source: LanguageOption,
        target: LanguageOption
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        let sourceLanguage = Locale.Language(identifier: source.id)
        let targetLanguage = Locale.Language(identifier: target.id)
        let cacheKey = languagePairKey(source: source, target: target)
        let status = try await availabilityStatus(
            source: sourceLanguage,
            target: targetLanguage,
            cacheKey: cacheKey,
            sourceTitle: source.localizedTitle,
            targetTitle: target.localizedTitle
        )
        guard status != .unsupported else {
            throw TranslationServiceError.unsupportedPair(source.localizedTitle, target.localizedTitle)
        }

        let session = translationSession(source: sourceLanguage, target: targetLanguage, cacheKey: cacheKey)
        if !(await session.isReady) {
            try await session.prepareTranslation()
        }

        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        var results = Array(repeating: "", count: texts.count)
        for response in responses {
            guard let identifier = response.clientIdentifier, let index = Int(identifier), results.indices.contains(index) else {
                throw TranslationServiceError.batchResponseMismatch
            }
            results[index] = response.targetText
        }
        return results
    }

    private func languagePairKey(source: LanguageOption, target: LanguageOption) -> String {
        "\(source.id)->\(target.id)"
    }

    private func availabilityStatus(
        source: Locale.Language,
        target: Locale.Language,
        cacheKey: String,
        sourceTitle: String,
        targetTitle: String
    ) async throws -> LanguageAvailability.Status {
        if let status = availabilityByLanguagePair[cacheKey] {
            return status
        }

        let status = await availability.status(from: source, to: target)
        availabilityByLanguagePair[cacheKey] = status
        if status == .unsupported {
            throw TranslationServiceError.unsupportedPair(sourceTitle, targetTitle)
        }
        return status
    }

    private func translationSession(
        source: Locale.Language,
        target: Locale.Language,
        cacheKey: String
    ) -> TranslationSession {
        if let session = sessionsByLanguagePair[cacheKey] {
            return session
        }

        let session = TranslationSession(installedSource: source, target: target)
        sessionsByLanguagePair[cacheKey] = session
        return session
    }
}

enum TranslationServiceError: LocalizedError {
    case unsupportedPair(String, String)
    case batchResponseMismatch

    var errorDescription: String? {
        switch self {
        case let .unsupportedPair(source, target):
            AppText.unsupportedTranslation(source: source, target: target)
        case .batchResponseMismatch:
            "Translation batch returned responses that do not match the request."
        }
    }
}
