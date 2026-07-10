import Foundation
import Testing
@testable import AirTranslate

@Suite
struct OpenAITranslationServiceRetryPolicyTests {
    @Test
    func rateLimitAndServerErrorStatusCodesAreRetryable() {
        #expect(OpenAITranslationService.isRetryableStatusCode(429))
        #expect(OpenAITranslationService.isRetryableStatusCode(500))
        #expect(OpenAITranslationService.isRetryableStatusCode(503))
        #expect(OpenAITranslationService.isRetryableStatusCode(599))
    }

    @Test
    func successAndClientErrorStatusCodesAreNotRetryable() {
        #expect(!OpenAITranslationService.isRetryableStatusCode(200))
        #expect(!OpenAITranslationService.isRetryableStatusCode(400))
        #expect(!OpenAITranslationService.isRetryableStatusCode(401))
        #expect(!OpenAITranslationService.isRetryableStatusCode(404))
    }

    @Test
    func retryDelayHonorsNumericRetryAfterHeader() {
        #expect(OpenAITranslationService.retryDelay(retryAfterHeader: "2") == 2)
        #expect(OpenAITranslationService.retryDelay(retryAfterHeader: " 0 ") == 0)
    }

    @Test
    func retryDelayCapsOversizedRetryAfterHeader() {
        #expect(OpenAITranslationService.retryDelay(retryAfterHeader: "120") == 10)
    }

    @Test
    func retryDelayFallsBackToJitterForMissingOrInvalidHeader() {
        let headers: [String?] = [nil, "soon", "-3", "Wed, 21 Oct 2026 07:28:00 GMT"]
        for header in headers {
            let delay = OpenAITranslationService.retryDelay(retryAfterHeader: header)
            #expect(delay >= 0.5)
            #expect(delay <= 1.5)
        }
    }
}
