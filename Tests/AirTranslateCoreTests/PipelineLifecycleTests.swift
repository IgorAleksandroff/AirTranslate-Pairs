import Foundation
import Testing
@testable import AirTranslate

private actor SuspendedSpeechAuthorization {
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    func isPending() -> Bool {
        continuation != nil
    }

    func resume(authorized: Bool) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: authorized)
    }
}

private actor SuspendedSpeechCleanup {
    private var firstCleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var cleanupCount = 0

    func waitOnFirstCleanup() async {
        cleanupCount += 1
        guard cleanupCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstCleanupContinuation = continuation
        }
    }

    func isFirstCleanupPending() -> Bool {
        firstCleanupContinuation != nil
    }

    func resumeFirstCleanup() {
        let continuation = firstCleanupContinuation
        firstCleanupContinuation = nil
        continuation?.resume()
    }
}

private actor SpeechAuthorizationRecorder {
    private(set) var requestCount = 0

    func rejectAuthorization() -> Bool {
        requestCount += 1
        return false
    }
}

private actor SuspendedAssetInventory {
    private var firstReserveContinuation: CheckedContinuation<Void, Never>?
    private(set) var reserveCallCount = 0
    private(set) var releaseCallCount = 0
    private(set) var isReserved = false
    private(set) var events: [String] = []

    func reserve(_ locale: Locale) async throws -> Bool {
        reserveCallCount += 1
        let call = reserveCallCount
        events.append("reserve-\(call)-started")
        if call == 1 {
            await withCheckedContinuation { continuation in
                firstReserveContinuation = continuation
            }
        }
        let wasReserved = isReserved
        isReserved = true
        events.append("reserve-\(call)-finished")
        return !wasReserved
    }

    func release(_ locale: Locale) -> Bool {
        releaseCallCount += 1
        events.append("release-\(releaseCallCount)")
        let wasReserved = isReserved
        isReserved = false
        return wasReserved
    }

    func isFirstReservePending() -> Bool {
        firstReserveContinuation != nil
    }

    func resumeFirstReserve() {
        let continuation = firstReserveContinuation
        firstReserveContinuation = nil
        continuation?.resume()
    }
}

private final class SpeechReservationClaimState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true

    func invalidate() {
        lock.withLock {
            isCurrent = false
        }
    }

    func claim(_ reservation: SpeechAssetReservation) -> Bool {
        lock.withLock { isCurrent }
    }
}

private final class SpeechStateLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?

    func record(_ result: Bool) {
        lock.withLock {
            self.result = result
        }
    }

    func currentResult() -> Bool? {
        lock.withLock { result }
    }
}

private final class SpeechLifecycleOwnershipRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock {
            events.contains(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class SuspendedProducerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private var isSuspended = false

    func suspend() {
        lock.withLock {
            isSuspended = true
        }
        resumeSemaphore.wait()
    }

    func suspended() -> Bool {
        lock.withLock { isSuspended }
    }

    func resume() {
        resumeSemaphore.signal()
    }
}

@Suite
struct PipelineLifecycleTests {
    @Test
    func fatalErrorEndsOnlyTheMatchingGeneration() {
        var lifecycle = PipelineLifecycleState()
        let configuration = makeConfiguration()
        let firstGeneration = lifecycle.beginStart(configuration: configuration)

        #expect(
            lifecycle.markRunning(
                generation: firstGeneration,
                currentConfiguration: configuration
            ) == .valid
        )
        #expect(lifecycle.acceptsSample(generation: firstGeneration))
        let didFailFirstGeneration = lifecycle.fail(generation: firstGeneration)
        #expect(didFailFirstGeneration)
        #expect(lifecycle.phase == .stopped)
        #expect(!lifecycle.acceptsSample(generation: firstGeneration))

        let secondGeneration = lifecycle.beginStart(configuration: configuration)
        #expect(
            lifecycle.markRunning(
                generation: secondGeneration,
                currentConfiguration: configuration
            ) == .valid
        )
        let didFailStaleGeneration = lifecycle.fail(generation: firstGeneration)
        #expect(!didFailStaleGeneration)
        #expect(lifecycle.phase == .running)
        #expect(lifecycle.acceptsSample(generation: secondGeneration))
    }

    @Test
    func startRejectsConfigurationMutationAcrossAwaitBoundary() {
        var lifecycle = PipelineLifecycleState()
        let initialConfiguration = makeConfiguration(audioInputSource: .systemAudio)
        let generation = lifecycle.beginStart(configuration: initialConfiguration)
        let changedConfiguration = makeConfiguration(audioInputSource: .microphone)

        #expect(
            lifecycle.validateStart(
                generation: generation,
                currentConfiguration: changedConfiguration
            ) == .configurationChanged
        )
        #expect(lifecycle.phase == .stopped)
        #expect(lifecycle.startConfiguration == nil)
        #expect(
            lifecycle.markRunning(
                generation: generation,
                currentConfiguration: initialConfiguration
            ) == .staleGeneration
        )
    }

    @Test
    func stopThenRestartRejectsOldSamplesAndAcceptsNewSamples() {
        var lifecycle = PipelineLifecycleState()
        let configuration = makeConfiguration()
        let firstGeneration = lifecycle.beginStart(configuration: configuration)
        #expect(
            lifecycle.markRunning(
                generation: firstGeneration,
                currentConfiguration: configuration
            ) == .valid
        )

        lifecycle.stop()
        #expect(!lifecycle.acceptsSample(generation: firstGeneration))

        let secondGeneration = lifecycle.beginStart(configuration: configuration)
        #expect(secondGeneration != firstGeneration)
        #expect(
            lifecycle.markRunning(
                generation: secondGeneration,
                currentConfiguration: configuration
            ) == .valid
        )
        #expect(!lifecycle.acceptsSample(generation: firstGeneration))
        #expect(lifecycle.acceptsSample(generation: secondGeneration))
    }

    @Test
    func cancellationCleansUpOnlyWhenItsGenerationIsStillActive() {
        var lifecycle = PipelineLifecycleState()
        let configuration = makeConfiguration()
        let activeGeneration = lifecycle.beginStart(configuration: configuration)

        #expect(lifecycle.isActive(generation: activeGeneration))
        let didCleanUpActiveGeneration = lifecycle.fail(generation: activeGeneration)
        #expect(didCleanUpActiveGeneration)
        #expect(lifecycle.phase == .stopped)

        let replacementGeneration = lifecycle.beginStart(configuration: configuration)
        let didCleanUpStaleGeneration = lifecycle.fail(generation: activeGeneration)
        #expect(!didCleanUpStaleGeneration)
        #expect(lifecycle.isActive(generation: replacementGeneration))
        #expect(lifecycle.phase == .starting)
    }

    @Test
    @MainActor
    func cancellingPermissionSuspendedStartReleasesConfigurationLockAndAllowsRestart() async throws {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        let firstGeneration = try #require(session.beginPermissionSuspendedStartForTesting())
        await waitForPermissionSuspension(on: session)

        #expect(session.isStarting)
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        session.stop()
        session.resumePermissionSuspendedStartForTesting()
        await Task.yield()

        #expect(!session.isRunning)
        #expect(!session.isStarting)
        #expect(
            !SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        let secondGeneration = try #require(session.beginPermissionSuspendedStartForTesting())
        #expect(secondGeneration != firstGeneration)
        #expect(session.isStarting)

        await waitForPermissionSuspension(on: session)
        session.stop()
        session.resumePermissionSuspendedStartForTesting()
        await Task.yield()
        #expect(!session.isRunning)
        #expect(!session.isStarting)
    }

    @Test
    func cancelledAppleSpeechPermissionCallbackCleansUpLocallyAndKeepsNewerRequestPending() async {
        let firstAuthorization = SuspendedSpeechAuthorization()
        let secondAuthorization = SuspendedSpeechAuthorization()
        let firstTranscriber = LiveSpeechTranscriber(
            authorizationRequester: { await firstAuthorization.requestAuthorization() }
        )
        let secondTranscriber = LiveSpeechTranscriber(
            authorizationRequester: { await secondAuthorization.requestAuthorization() }
        )

        let firstStart = Task.detached {
            try await firstTranscriber.start(languages: [.english])
        }
        await waitForPending { await firstAuthorization.isPending() }
        firstStart.cancel()

        let secondStart = Task.detached {
            try await secondTranscriber.start(languages: [.english])
        }
        await waitForPending { await secondAuthorization.isPending() }

        // Model a late, non-cooperative OS callback for G1 after G2 is
        // already waiting for its own permission result.
        await firstAuthorization.resume(authorized: true)
        let firstResult = await firstStart.result
        let firstDidCancel: Bool
        switch firstResult {
        case .success:
            firstDidCancel = false
        case .failure(let error):
            firstDidCancel = error is CancellationError
        }

        #expect(firstDidCancel)
        #expect(!firstTranscriber.hasActiveResourcesForTesting)
        let secondIsStillPending = await secondAuthorization.isPending()
        #expect(secondIsStillPending)
        #expect(!secondTranscriber.hasActiveResourcesForTesting)

        await secondAuthorization.resume(authorized: false)
        let secondResult = await secondStart.result
        let secondDidRejectAuthorization: Bool
        switch secondResult {
        case .success:
            secondDidRejectAuthorization = false
        case .failure:
            secondDidRejectAuthorization = true
        }

        #expect(secondDidRejectAuthorization)
        #expect(!secondTranscriber.hasActiveResourcesForTesting)
    }

    @Test
    func stopInvalidatesPermissionSuspendedAppleSpeechStartWithoutTaskCancellation() async {
        let authorization = SuspendedSpeechAuthorization()
        let transcriber = LiveSpeechTranscriber(
            authorizationRequester: { await authorization.requestAuthorization() }
        )
        let start = Task.detached {
            try await transcriber.start(languages: [.english])
        }
        await waitForPending { await authorization.isPending() }

        transcriber.stop()
        await authorization.resume(authorized: true)

        let result = await start.result
        let didCancel: Bool
        switch result {
        case .success:
            didCancel = false
        case .failure(let error):
            didCancel = error is CancellationError
        }

        #expect(didCancel)
        #expect(!transcriber.hasActiveResourcesForTesting)
    }

    @Test
    func stopThenRestartWaitsForSerializedSpeechAssetCleanup() async {
        let cleanup = SuspendedSpeechCleanup()
        let authorization = SpeechAuthorizationRecorder()
        let transcriber = LiveSpeechTranscriber(
            authorizationRequester: {
                await authorization.rejectAuthorization()
            }
        )
        transcriber.setCleanupCompletionHookForTesting {
            await cleanup.waitOnFirstCleanup()
        }

        transcriber.stop()
        await waitForPending { await cleanup.isFirstCleanupPending() }

        let restart = Task.detached {
            try await transcriber.start(languages: [.english])
        }
        await Task.yield()

        #expect(await authorization.requestCount == 0)

        await cleanup.resumeFirstCleanup()
        let restartResult = await restart.result

        switch restartResult {
        case .success:
            Issue.record("Restart unexpectedly succeeded without authorization")
        case .failure:
            break
        }
        #expect(await authorization.requestCount == 1)
        #expect(await cleanup.cleanupCount >= 2)
        #expect(!transcriber.hasActiveResourcesForTesting)
    }

    @Test
    func lifecycleCancellationRunsAfterStateLockIsReleased() async {
        let probe = SpeechStateLockProbe()
        let transcriber = LiveSpeechTranscriber()
        transcriber.installAnalyzeTaskCancellationLockProbeForTesting {
            probe.record($0)
        }

        transcriber.stop()
        for _ in 0..<50 where probe.currentResult() == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(probe.currentResult() == true)
        await transcriber.stopAndWaitForCleanup()
    }

    @Test
    func stopBeforeProducerOwnershipDoesNotCreateOrphanOrDoubleCleanAssets() async throws {
        let recorder = SpeechLifecycleOwnershipRecorder()
        let coordinator = SpeechAssetReservationCoordinator(
            reserveLocale: { _ in
                recorder.record("asset-reserved")
                return true
            },
            releaseLocale: { _ in
                recorder.record("asset-released")
                return true
            }
        )
        let transcriber = LiveSpeechTranscriber(
            assetReservationCoordinator: coordinator
        )
        transcriber.setCleanupCompletionHookForTesting {
            recorder.record("cleanup-complete")
        }
        let lifecycleGeneration = transcriber.lifecycleGenerationForTesting
        _ = try await coordinator.reserve(
            locale: Locale(identifier: "en-US")
        ) { reservation in
            transcriber.claimAssetReservationForTesting(
                reservation,
                lifecycleGeneration: lifecycleGeneration
            )
        }

        // Stop wins after preparation ownership but before producer
        // construction. The stale publication attempt must not invoke its
        // producer factory or repeat lifecycle cleanup.
        await transcriber.stopAndWaitForCleanup()
        let didPublishStaleProducer = transcriber.publishCancellationProbeTasksForTesting(
            lifecycleGeneration: lifecycleGeneration,
            onStarted: { recorder.record("\($0)-started") },
            onCancelled: { recorder.record("\($0)-cancelled") }
        )

        #expect(!didPublishStaleProducer)
        #expect(!recorder.contains("analyze-started"))
        #expect(!recorder.contains("result-started"))
        #expect(
            recorder.snapshot() == [
                "asset-reserved",
                "asset-released",
                "cleanup-complete",
            ]
        )
        #expect(!transcriber.hasActiveResourcesForTesting)
    }

    @Test
    func stopAfterProducerOwnershipCancelsBeforeStartGateAndCleansOnce() async throws {
        let recorder = SpeechLifecycleOwnershipRecorder()
        let suspendedGate = SuspendedProducerStartGate()
        let coordinator = SpeechAssetReservationCoordinator(
            reserveLocale: { _ in
                recorder.record("asset-reserved")
                return true
            },
            releaseLocale: { _ in
                recorder.record("asset-released")
                return true
            }
        )
        let transcriber = LiveSpeechTranscriber(
            assetReservationCoordinator: coordinator
        )
        transcriber.setCleanupCompletionHookForTesting {
            recorder.record("cleanup-complete")
        }
        transcriber.setPostRunningTaskPublicationHookForTesting {
            suspendedGate.suspend()
        }
        let lifecycleGeneration = transcriber.lifecycleGenerationForTesting
        _ = try await coordinator.reserve(
            locale: Locale(identifier: "en-US")
        ) { reservation in
            transcriber.claimAssetReservationForTesting(
                reservation,
                lifecycleGeneration: lifecycleGeneration
            )
        }

        let publication = Task.detached {
            transcriber.publishCancellationProbeTasksForTesting(
                lifecycleGeneration: lifecycleGeneration,
                onStarted: { recorder.record("\($0)-started") },
                onCancelled: { recorder.record("\($0)-cancelled") }
            )
        }
        await waitForPending { suspendedGate.suspended() }

        let cleanup = Task.detached {
            await transcriber.stopAndWaitForCleanup()
        }
        await waitForPending { recorder.contains("cleanup-complete") }
        suspendedGate.resume()

        #expect(await publication.value)
        await cleanup.value
        await waitForPending {
            recorder.contains("analyze-cancelled")
                && recorder.contains("result-cancelled")
        }

        let events = recorder.snapshot()
        #expect(events.filter { $0 == "asset-released" }.count == 1)
        #expect(events.filter { $0 == "cleanup-complete" }.count == 1)
        #expect(!events.contains("analyze-started"))
        #expect(!events.contains("result-started"))
        #expect(events.first == "asset-reserved")
        #expect(
            events.firstIndex(of: "asset-released")!
                < events.firstIndex(of: "cleanup-complete")!
        )
        #expect(!transcriber.hasActiveResourcesForTesting)
    }

    @Test
    func staleInFlightReserveReleasesBeforeNewOwnerAndCannotReleaseItLater() async throws {
        let inventory = SuspendedAssetInventory()
        let coordinator = SpeechAssetReservationCoordinator(
            reserveLocale: { try await inventory.reserve($0) },
            releaseLocale: { await inventory.release($0) }
        )
        let locale = Locale(identifier: "en-US")
        let staleClaim = SpeechReservationClaimState()

        let staleReserve = Task.detached {
            try await coordinator.reserve(
                locale: locale,
                claim: staleClaim.claim
            )
        }
        await waitForPending { await inventory.isFirstReservePending() }

        staleClaim.invalidate()
        staleReserve.cancel()
        let replacementReserve = Task.detached {
            try await coordinator.reserve(locale: locale) { _ in true }
        }
        await inventory.resumeFirstReserve()

        switch await staleReserve.result {
        case .success:
            Issue.record("Stale reservation unexpectedly claimed ownership")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        let replacement = try await replacementReserve.value
        #expect(await inventory.reserveCallCount == 2)
        #expect(await inventory.releaseCallCount == 1)
        #expect(await inventory.isReserved)
        #expect(
            await inventory.events == [
                "reserve-1-started",
                "reserve-1-finished",
                "release-1",
                "reserve-2-started",
                "reserve-2-finished",
            ]
        )

        let overlappingOwner = try await coordinator.reserve(locale: locale) { _ in true }
        #expect(await inventory.reserveCallCount == 2)

        await coordinator.release(replacement)
        #expect(await inventory.releaseCallCount == 1)
        #expect(await inventory.isReserved)

        await coordinator.release(overlappingOwner)
        #expect(await inventory.releaseCallCount == 2)
        #expect(!(await inventory.isReserved))
    }

    @Test
    @MainActor
    func lateFirstPermissionResumeDoesNotUnlockOrStopNewerStart() async throws {
        let session = TranslationSessionStore(modelAvailabilityProvider: { _, _ in [:] })
        let firstGeneration = try #require(session.beginPermissionSuspendedStartForTesting())
        await waitForPermissionSuspension(on: session, generation: firstGeneration)

        session.stop()
        #expect(!session.isStarting)
        #expect(
            !SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        let secondGeneration = try #require(session.beginPermissionSuspendedStartForTesting())
        await waitForPermissionSuspension(on: session, generation: secondGeneration)
        #expect(secondGeneration != firstGeneration)
        #expect(session.isStarting)
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        await session.simulatePipelineStartConfigurationErrorForTesting(
            generation: firstGeneration
        )
        #expect(session.isPermissionSuspendedStartForTesting(generation: secondGeneration))
        #expect(session.isStarting)

        session.resumePermissionSuspendedStartForTesting(generation: firstGeneration)
        await Task.yield()

        #expect(!session.isPermissionSuspendedStartForTesting(generation: firstGeneration))
        #expect(session.isPermissionSuspendedStartForTesting(generation: secondGeneration))
        #expect(session.isStarting)
        #expect(
            SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        session.resumePermissionSuspendedStartForTesting(generation: secondGeneration)
        await waitForStartCompletion(on: session)

        #expect(!session.isRunning)
        #expect(!session.isStarting)
        #expect(
            !SidebarSessionConfigurationAccess.isLocked(
                isRunning: session.isRunning,
                isStarting: session.isStarting
            )
        )

        // A completed G2 leaves the configuration lock released for the next
        // independent start attempt.
        let thirdGeneration = try #require(session.beginPermissionSuspendedStartForTesting())
        #expect(thirdGeneration != secondGeneration)
        await waitForPermissionSuspension(on: session, generation: thirdGeneration)
        session.stop()
        session.resumePermissionSuspendedStartForTesting(generation: thirdGeneration)
        await waitForStartCompletion(on: session)
    }

    @MainActor
    private func waitForPermissionSuspension(on session: TranslationSessionStore) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while !session.isPermissionSuspendedStartForTesting,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.isPermissionSuspendedStartForTesting)
    }

    @MainActor
    private func waitForPermissionSuspension(
        on session: TranslationSessionStore,
        generation: UInt64
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while !session.isPermissionSuspendedStartForTesting(generation: generation),
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.isPermissionSuspendedStartForTesting(generation: generation))
    }

    @MainActor
    private func waitForStartCompletion(on session: TranslationSessionStore) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while session.isStarting, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isStarting)
    }

    private func waitForPending(
        _ isPending: @escaping () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while clock.now < deadline {
            if await isPending() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await isPending())
    }

    private func makeConfiguration(
        audioInputSource: AudioInputSource = .systemAudio
    ) -> StartConfiguration {
        StartConfiguration(
            audioInputSource: audioInputSource,
            microphoneDeviceUniqueID: nil,
            sourceLanguage: .english,
            targetLanguage: .korean,
            selectedModel: .appleSystem,
            openAITranscriptionModel: .off,
            openAITranslationModel: .off,
            geminiTranslationModel: .off,
            usesAppleSourceAutoDetection: false
        )
    }
}
