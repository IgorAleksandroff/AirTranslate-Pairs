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
        await waitForPendingAuthorization(firstAuthorization)
        firstStart.cancel()

        let secondStart = Task.detached {
            try await secondTranscriber.start(languages: [.english])
        }
        await waitForPendingAuthorization(secondAuthorization)

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
        await waitForPendingAuthorization(authorization)

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

    private func waitForPendingAuthorization(
        _ authorization: SuspendedSpeechAuthorization
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while clock.now < deadline {
            if await authorization.isPending() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let isPending = await authorization.isPending()
        #expect(isPending)
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
