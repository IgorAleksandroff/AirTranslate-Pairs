import Foundation
import Testing
@testable import AirTranslate

@Suite
struct OpenAITranslationModelRestoreTests {
    private static let key = "openAITranslationModelID"

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
        let defaults = UserDefaults.standard
        let previousValue = defaults.string(forKey: Self.key)
        defaults.set(value, forKey: Self.key)

        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        assert(session)

        if let previousValue {
            defaults.set(previousValue, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
