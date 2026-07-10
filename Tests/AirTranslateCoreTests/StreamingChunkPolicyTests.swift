import Testing
@testable import AirTranslate

@Suite
struct StreamingChunkPolicyTests {
    private func totalAnimationNanoseconds(for text: String) -> UInt64 {
        let chunks = StreamingChunkPolicy.chunks(for: text)
        let delay = StreamingChunkPolicy.chunkDelayNanoseconds(chunkCount: chunks.count)
        return UInt64(chunks.count) * delay
    }

    @Test
    func koreanDeltaWithFrequentSpacesStaysWithinAnimationBudget() {
        let delta = String(String(repeating: "지금 회의 중이에요 ", count: 40).prefix(360))

        #expect(delta.count == 360)
        let chunks = StreamingChunkPolicy.chunks(for: delta)
        #expect(chunks.count <= StreamingChunkPolicy.targetChunkCount)
        #expect(totalAnimationNanoseconds(for: delta) <= StreamingChunkPolicy.totalAnimationBudgetNanoseconds)
    }

    @Test
    func englishDeltaStaysWithinAnimationBudget() {
        let delta = String(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 8).prefix(360))

        #expect(delta.count == 360)
        let chunks = StreamingChunkPolicy.chunks(for: delta)
        #expect(chunks.count <= StreamingChunkPolicy.targetChunkCount)
        #expect(totalAnimationNanoseconds(for: delta) <= StreamingChunkPolicy.totalAnimationBudgetNanoseconds)
    }

    @Test
    func spacelessCJKDeltaStaysWithinAnimationBudget() {
        let delta = String(String(repeating: "現在進行中の会議内容を翻訳しています", count: 20).prefix(360))

        #expect(delta.count == 360)
        let chunks = StreamingChunkPolicy.chunks(for: delta)
        #expect(chunks.count <= StreamingChunkPolicy.targetChunkCount)
        #expect(totalAnimationNanoseconds(for: delta) <= StreamingChunkPolicy.totalAnimationBudgetNanoseconds)
    }

    @Test
    func everyDeltaLengthUpToAnimatedLimitStaysWithinAnimationBudget() {
        let base = String(repeating: "안녕 hi 。", count: 60)

        for length in 1...360 {
            let delta = String(base.prefix(length))
            let chunks = StreamingChunkPolicy.chunks(for: delta)
            #expect(chunks.count <= StreamingChunkPolicy.targetChunkCount)
            #expect(totalAnimationNanoseconds(for: delta) <= StreamingChunkPolicy.totalAnimationBudgetNanoseconds)
        }
    }

    @Test
    func shortDeltaKeepsMaximumPerChunkDelay() {
        #expect(StreamingChunkPolicy.chunkDelayNanoseconds(chunkCount: 2) == StreamingChunkPolicy.maxChunkDelayNanoseconds)
    }

    @Test
    func chunksPreserveGraphemeClustersOnReassembly() {
        let delta = "가족 이모지 👨‍👩‍👧‍👦 결합 자모 \u{1100}\u{1161}\u{11A8} flag 🇰🇷 끝"

        let chunks = StreamingChunkPolicy.chunks(for: delta)
        #expect(chunks.joined() == delta)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test
    func emptyDeltaProducesNoChunksAndZeroDelay() {
        #expect(StreamingChunkPolicy.chunks(for: "").isEmpty)
        #expect(StreamingChunkPolicy.chunkDelayNanoseconds(chunkCount: 0) == 0)
    }
}
