import Foundation
import Testing
@testable import AirTranslate

@Suite(.serialized)
struct OpenAITranslationModelRestoreTests {
    private static let selectedModelKey = "selectedModelID"
    private static let openAITranscriptionModelKey = "openAITranscriptionModelID"
    private static let openAITranslationModelKey = "openAITranslationModelID"
    private static let geminiTranslationModelKey = "geminiTranslationModelID"
    private static let modelSelectorKeys = [
        selectedModelKey,
        openAITranscriptionModelKey,
        openAITranslationModelKey,
        geminiTranslationModelKey
    ]

    @Test
    @MainActor
    func restorePreservesDisabledOpenAITranslationModel() {
        withRestoredDefaults(value: "off") { session in
            #expect(session.openAITranslationModel == .off)
        }
    }

    @Test
    @MainActor
    func restoreRecoversEnabledUnsupportedModelToLiveTranslate() {
        withRestoredDefaults(value: "gpt-realtime-2.1") { session in
            #expect(session.openAITranslationModel == .gptRealtimeTranslate)
        }
    }

    @Test
    @MainActor
    func restoreKeepsSupportedLiveTranslateModel() {
        withRestoredDefaults(value: "gpt-realtime-translate") { session in
            #expect(session.openAITranslationModel == .gptRealtimeTranslate)
        }
    }

    @MainActor
    private func withRestoredDefaults(value: String, assert: (TranslationSessionStore) -> Void) {
        StandardUserDefaultsTestLock.shared.withLock {
            let defaults = UserDefaults.standard
            let previousValues = Dictionary(uniqueKeysWithValues: Self.modelSelectorKeys.map {
                ($0, defaults.object(forKey: $0))
            })
            defer {
                for key in Self.modelSelectorKeys {
                    if let value = previousValues[key] {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
            defaults.set(IntelligenceModel.appleSpeechOnly.rawValue, forKey: Self.selectedModelKey)
            defaults.set(OpenAIRealtimeTranscriptionModel.off.rawValue, forKey: Self.openAITranscriptionModelKey)
            defaults.set(value, forKey: Self.openAITranslationModelKey)
            defaults.set(GeminiTranslationModel.off.rawValue, forKey: Self.geminiTranslationModelKey)

            let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
            assert(session)
        }
    }
}
