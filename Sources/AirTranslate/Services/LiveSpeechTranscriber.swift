import AVFoundation
import CoreMedia
import Speech

enum LiveSpeechTranscriberError: LocalizedError, Equatable, Sendable {
    case audioInputBackpressure(bufferLimit: Int)

    var errorDescription: String? {
        switch self {
        case .audioInputBackpressure:
            "Apple Speech stopped because audio arrived faster than it could be transcribed. Restart transcription to continue."
        }
    }
}

enum SpeechAnalyzerInputYieldDisposition: Equatable, Sendable {
    case enqueued
    case dropped
    case terminated
}

final class SpeechAnalyzerInputQueue<Element: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Element>

    private let continuation: AsyncStream<Element>.Continuation
    private let bufferLimit: Int
    private let onBackpressure: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var isFinished = false
    private var didReportBackpressure = false

    init(
        bufferLimit: Int,
        onBackpressure: @escaping @Sendable (Int) -> Void
    ) {
        precondition(bufferLimit > 0)

        var capturedContinuation: AsyncStream<Element>.Continuation?
        stream = AsyncStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        ) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
        self.bufferLimit = bufferLimit
        self.onBackpressure = onBackpressure
    }

    @discardableResult
    func yield(_ element: Element) -> SpeechAnalyzerInputYieldDisposition {
        lock.lock()
        let canYield = !isFinished
        lock.unlock()
        guard canYield else { return .terminated }

        switch continuation.yield(element) {
        case .enqueued:
            return .enqueued
        case .dropped:
            lock.lock()
            let shouldReport = !isFinished && !didReportBackpressure
            if shouldReport {
                isFinished = true
                didReportBackpressure = true
            }
            lock.unlock()

            if shouldReport {
                // Once any chunk is evicted, transcript completeness can no
                // longer be guaranteed. End the input before reporting the
                // fatal degradation so the owner can stop the pipeline.
                continuation.finish()
                onBackpressure(bufferLimit)
            }
            return .dropped
        case .terminated:
            lock.lock()
            isFinished = true
            lock.unlock()
            return .terminated
        @unknown default:
            lock.lock()
            isFinished = true
            lock.unlock()
            continuation.finish()
            return .terminated
        }
    }

    func finish() {
        lock.lock()
        let shouldFinish = !isFinished
        isFinished = true
        lock.unlock()

        if shouldFinish {
            continuation.finish()
        }
    }
}

protocol LiveSpeechTranscriberDelegate: AnyObject {
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    )
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didTranslate text: String,
        language: LanguageOption,
        confidence: Double
    )
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognizeSourceTranscript text: String,
        confidence: Double
    )
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    )
    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error)
}

extension LiveSpeechTranscriberDelegate {
    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didTranslate text: String,
        language: LanguageOption,
        confidence: Double
    ) {}

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognizeSourceTranscript text: String,
        confidence: Double
    ) {}

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    ) {}
}

struct SpeechAssetReservation: Sendable {
    fileprivate let id: UInt64
    let locale: Locale
}

private final class SpeechAssetAsyncMutex: @unchecked Sendable {
    // This intentionally stays non-reentrant across the caller's awaits.
    // An actor method would permit another reserve/release operation to enter
    // while AssetInventory is suspended.
    private let stateLock = NSLock()
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = stateLock.withLock {
                guard !isAcquired else {
                    waiters.append(continuation)
                    return false
                }
                isAcquired = true
                return true
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let nextWaiter: CheckedContinuation<Void, Never>? = stateLock.withLock {
            guard !waiters.isEmpty else {
                isAcquired = false
                return nil
            }
            return waiters.removeFirst()
        }
        nextWaiter?.resume()
    }
}

final class SpeechAssetReservationCoordinator: @unchecked Sendable {
    typealias ReserveLocale = @Sendable (Locale) async throws -> Bool
    typealias ReleaseLocale = @Sendable (Locale) async -> Bool

    static let shared = SpeechAssetReservationCoordinator()

    private struct LocaleOwners {
        let locale: Locale
        var reservationIDs: Set<UInt64>
    }

    private let mutex = SpeechAssetAsyncMutex()
    private let reserveLocale: ReserveLocale
    private let releaseLocale: ReleaseLocale
    private var nextReservationID: UInt64 = 0
    private var ownersByLocaleIdentifier: [String: LocaleOwners] = [:]

    init(
        reserveLocale: @escaping ReserveLocale = {
            try await AssetInventory.reserve(locale: $0)
        },
        releaseLocale: @escaping ReleaseLocale = {
            await AssetInventory.release(reservedLocale: $0)
        }
    ) {
        self.reserveLocale = reserveLocale
        self.releaseLocale = releaseLocale
    }

    func reserve(
        locale: Locale,
        claim: @escaping @Sendable (SpeechAssetReservation) -> Bool
    ) async throws -> SpeechAssetReservation {
        await mutex.acquire()
        defer { mutex.release() }

        try Task.checkCancellation()
        let localeIdentifier = locale.identifier
        let needsSystemReservation = ownersByLocaleIdentifier[localeIdentifier] == nil
        if needsSystemReservation {
            // A false result means the app already owns this global locale
            // reservation. The coordinator still adopts it and releases it
            // when its final logical owner exits.
            _ = try await reserveLocale(locale)
            do {
                try Task.checkCancellation()
            } catch {
                _ = await releaseLocale(locale)
                throw error
            }
        }

        nextReservationID &+= 1
        let reservation = SpeechAssetReservation(
            id: nextReservationID,
            locale: locale
        )
        guard claim(reservation) else {
            if needsSystemReservation {
                _ = await releaseLocale(locale)
            }
            throw CancellationError()
        }

        if var owners = ownersByLocaleIdentifier[localeIdentifier] {
            owners.reservationIDs.insert(reservation.id)
            ownersByLocaleIdentifier[localeIdentifier] = owners
        } else {
            ownersByLocaleIdentifier[localeIdentifier] = LocaleOwners(
                locale: locale,
                reservationIDs: [reservation.id]
            )
        }
        return reservation
    }

    func release(_ reservation: SpeechAssetReservation) async {
        await mutex.acquire()
        defer { mutex.release() }

        let localeIdentifier = reservation.locale.identifier
        guard var owners = ownersByLocaleIdentifier[localeIdentifier],
              owners.reservationIDs.remove(reservation.id) != nil
        else {
            return
        }
        guard owners.reservationIDs.isEmpty else {
            ownersByLocaleIdentifier[localeIdentifier] = owners
            return
        }

        ownersByLocaleIdentifier[localeIdentifier] = nil
        _ = await releaseLocale(owners.locale)
    }
}

final class LiveSpeechTranscriber: @unchecked Sendable {
    private struct LifecycleResources {
        let inputQueue: SpeechAnalyzerInputQueue<AnalyzerInput>?
        let analyzer: SpeechAnalyzer?
        let analyzeTask: Task<Void, Never>?
        let resultTasks: [Task<Void, Never>]
        let assetReservations: [SpeechAssetReservation]
    }

    private struct LifecycleTransition {
        let generation: UInt64
        let cleanupTask: Task<Void, Never>
    }

    weak var delegate: LiveSpeechTranscriberDelegate?

    private static let reusablePCMBufferCount = 48
    private static let analyzerInputBufferLimit = 32

    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var analyzer: SpeechAnalyzer?
    private var inputQueue: SpeechAnalyzerInputQueue<AnalyzerInput>?
    private var analyzeTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var assetReservations: [SpeechAssetReservation] = []
    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private let authorizationRequester: @Sendable () async -> Bool
    private let assetReservationCoordinator: SpeechAssetReservationCoordinator
#if DEBUG
    private var cleanupCompletionHookForTesting: (@Sendable () async -> Void)?
#endif
    private var lifecycleGeneration: UInt64 = 0
    private var cleanupTask: Task<Void, Never>?
    private var isPaused = false
    private var reusablePCMBuffers = [AVAudioPCMBuffer?](
        repeating: nil,
        count: reusablePCMBufferCount
    )
    private var reusablePCMBufferCursor = 0

    init(
        authorizationRequester: @escaping @Sendable () async -> Bool = {
            await LiveSpeechTranscriber.requestAuthorization()
        },
        assetReservationCoordinator: SpeechAssetReservationCoordinator = .shared
    ) {
        self.authorizationRequester = authorizationRequester
        self.assetReservationCoordinator = assetReservationCoordinator
    }

    static func installedSupportedLanguages(from languages: [LanguageOption]) async -> [LanguageOption] {
        guard SpeechTranscriber.isAvailable else { return [] }

        let maximumLanguageCount = max(1, AssetInventory.maximumReservedLocales)
        var installedLanguages: [LanguageOption] = []
        for language in languages {
            guard installedLanguages.count < maximumLanguageCount else { break }
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                continue
            }

            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed:
                installedLanguages.append(language)
            case .downloading, .supported, .unsupported:
                continue
            @unknown default:
                continue
            }
        }

        return installedLanguages
    }

    func start(languages: [LanguageOption]) async throws {
        let lifecycleTransition = takeLifecycleTransition()
        let lifecycleGeneration = lifecycleTransition.generation
        await lifecycleTransition.cleanupTask.value

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let authorized = await authorizationRequester()
            // SFSpeechRecognizer's completion handler can resume after its
            // surrounding task was cancelled. Check before reserving locales
            // or constructing an analyzer so that stale starts stay local.
            try Task.checkCancellation()
            guard authorized else { throw SpeechError.notAuthorized }
            try ensureLifecycleIsCurrent(lifecycleGeneration)

            var seenLanguageIDs = Set<String>()
            let uniqueLanguages = languages.filter { language in
                seenLanguageIDs.insert(language.id).inserted
            }
            var transcribers: [(language: LanguageOption, transcriber: SpeechTranscriber)] = []
            for language in uniqueLanguages {
                try Task.checkCancellation()
                guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                    throw SpeechError.recognizerUnavailable
                }
                try Task.checkCancellation()

                _ = try await assetReservationCoordinator.reserve(
                    locale: supportedLocale
                ) { [weak self] reservation in
                    guard let self else { return false }
                    return stateLock.withLock {
                        guard self.lifecycleGeneration == lifecycleGeneration else {
                            return false
                        }
                        assetReservations.append(reservation)
                        return true
                    }
                }
                try Task.checkCancellation()
                transcribers.append((
                    language: language,
                    transcriber: SpeechTranscriber(
                        locale: supportedLocale,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults, .fastResults],
                        attributeOptions: [.transcriptionConfidence]
                    )
                ))
            }
            let modules: [any SpeechModule] = transcribers.map(\.transcriber)
            let inputQueue: SpeechAnalyzerInputQueue<AnalyzerInput> = makeInputQueue(
                bufferLimit: Self.analyzerInputBufferLimit
            )
            let analyzer = SpeechAnalyzer(modules: modules)
            let didPublishPreparationResources = stateLock.withLock {
                guard self.lifecycleGeneration == lifecycleGeneration else {
                    return false
                }
                self.inputQueue = inputQueue
                self.analyzer = analyzer
                return true
            }
            guard didPublishPreparationResources else {
                inputQueue.finish()
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            }

            try Task.checkCancellation()
            try await analyzer.prepareToAnalyze(in: audioFormat)
            try ensureLifecycleIsCurrent(lifecycleGeneration)
            try Task.checkCancellation()

            let analyzeTask = Task { [weak self] in
                do {
                    try await analyzer.start(inputSequence: inputQueue.stream)
                } catch {
                    guard let self else { return }
                    self.delegate?.liveSpeechTranscriber(self, didFail: error)
                }
            }

            let resultTasks = transcribers.map { entry in
                Task { [weak self] in
                    do {
                        for try await result in entry.transcriber.results {
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            guard let self else { return }
                            self.delegate?.liveSpeechTranscriber(
                                self,
                                didRecognize: text,
                                language: entry.language,
                                confidence: Self.averageConfidence(in: result.text)
                            )
                        }
                    } catch {
                        guard let self else { return }
                        self.delegate?.liveSpeechTranscriber(self, didFail: error)
                    }
                }
            }
            let didPublishRunningTasks = stateLock.withLock {
                guard self.lifecycleGeneration == lifecycleGeneration else {
                    return false
                }
                self.analyzeTask = analyzeTask
                self.resultTasks = resultTasks
                return true
            }
            guard didPublishRunningTasks else {
                analyzeTask.cancel()
                resultTasks.forEach { $0.cancel() }
                inputQueue.finish()
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            }
            try Task.checkCancellation()
            try ensureLifecycleIsCurrent(lifecycleGeneration)
            } onCancel: {
                // A local candidate may never be published to
                // TranslationSessionStore. Invalidate its generation as soon
                // as its owning task is cancelled so an in-flight global
                // reservation transaction cannot claim stale ownership.
                _ = self.stop(lifecycleGeneration: lifecycleGeneration)
            }
        } catch {
            // This instance may be a stale candidate which was never promoted
            // to TranslationSessionStore. Its cleanup must not rely on the
            // store's currently active generation.
            if let cleanupTask = stop(lifecycleGeneration: lifecycleGeneration) {
                await cleanupTask.value
            }
            throw error
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isPaused = isPaused
        let inputQueue = inputQueue
        stateLock.unlock()

        guard !isPaused, let inputQueue else { return }

        conversionLock.lock()
        let pcmBuffer = pcmBuffer(from: sampleBuffer)
        conversionLock.unlock()

        guard let pcmBuffer else {
            return
        }

        inputQueue.yield(AnalyzerInput(buffer: pcmBuffer))
    }

    func setPaused(_ isPaused: Bool) {
        stateLock.lock()
        self.isPaused = isPaused
        stateLock.unlock()
    }

    func stop() {
        _ = takeLifecycleTransition()
    }

    func stopAndWaitForCleanup() async {
        let lifecycleTransition = takeLifecycleTransition()
        await lifecycleTransition.cleanupTask.value
    }

    private func stop(lifecycleGeneration: UInt64) -> Task<Void, Never>? {
        guard let lifecycleTransition = takeLifecycleTransition(
            expectedGeneration: lifecycleGeneration
        ) else {
            return nil
        }
        return lifecycleTransition.cleanupTask
    }

    private func takeLifecycleTransition() -> LifecycleTransition {
        transitionLifecycle(expectedGeneration: nil)!
    }

    private func takeLifecycleTransition(
        expectedGeneration: UInt64
    ) -> LifecycleTransition? {
        transitionLifecycle(expectedGeneration: expectedGeneration)
    }

    private func transitionLifecycle(
        expectedGeneration: UInt64?
    ) -> LifecycleTransition? {
        let transition: LifecycleTransition? = stateLock.withLock {
            if let expectedGeneration,
               lifecycleGeneration != expectedGeneration {
                return nil
            }

            lifecycleGeneration &+= 1
            isPaused = false
            let resources = LifecycleResources(
                inputQueue: inputQueue,
                analyzer: analyzer,
                analyzeTask: analyzeTask,
                resultTasks: resultTasks,
                assetReservations: assetReservations
            )
            inputQueue = nil
            analyzer = nil
            analyzeTask = nil
            resultTasks = []
            assetReservations = []

            // Detach and stop synchronous producers while holding the same
            // lock that publishes the cleanup tail. A later start therefore
            // cannot observe an empty lifecycle before this teardown is
            // registered.
            resources.inputQueue?.finish()
            resources.analyzeTask?.cancel()
            resources.resultTasks.forEach { $0.cancel() }

            let previousCleanupTask = cleanupTask
            let analyzer = resources.analyzer
            let assetReservations = resources.assetReservations
#if DEBUG
            let cleanupCompletionHookForTesting = cleanupCompletionHookForTesting
#endif
            let assetReservationCoordinator = assetReservationCoordinator
            let cleanupTask = Task {
                await previousCleanupTask?.value
                if let analyzer {
                    await analyzer.cancelAndFinishNow()
                }
                for reservation in assetReservations {
                    await assetReservationCoordinator.release(reservation)
                }
#if DEBUG
                await cleanupCompletionHookForTesting?()
#endif
            }
            self.cleanupTask = cleanupTask
            return LifecycleTransition(
                generation: lifecycleGeneration,
                cleanupTask: cleanupTask
            )
        }
        if transition != nil {
            resetReusablePCMBuffers()
        }
        return transition
    }

    private func ensureLifecycleIsCurrent(_ expectedGeneration: UInt64) throws {
        guard stateLock.withLock({
            lifecycleGeneration == expectedGeneration
        }) else {
            throw CancellationError()
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func makeInputQueue<Element: Sendable>(
        bufferLimit: Int
    ) -> SpeechAnalyzerInputQueue<Element> {
        SpeechAnalyzerInputQueue(bufferLimit: bufferLimit) { [weak self] bufferLimit in
            guard let self else { return }
            delegate?.liveSpeechTranscriber(
                self,
                didFail: LiveSpeechTranscriberError.audioInputBackpressure(
                    bufferLimit: bufferLimit
                )
            )
        }
    }

#if DEBUG
    var hasActiveResourcesForTesting: Bool {
        stateLock.withLock {
            analyzer != nil
                || inputQueue != nil
                || analyzeTask != nil
                || !resultTasks.isEmpty
                || !assetReservations.isEmpty
        }
    }

    func setCleanupCompletionHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        stateLock.withLock {
            cleanupCompletionHookForTesting = hook
        }
    }

    func makeInputQueueForTesting<Element: Sendable>(
        bufferLimit: Int = LiveSpeechTranscriber.analyzerInputBufferLimit
    ) -> SpeechAnalyzerInputQueue<Element> {
        makeInputQueue(bufferLimit: bufferLimit)
    }
#endif

    private static func averageConfidence(in text: AttributedString) -> Double {
        var total = 0.0
        var count = 0

        for run in text.runs {
            if let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                total += confidence
                count += 1
            }
        }

        return count == 0 ? 0.5 : total / Double(count)
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = reusablePCMBuffer(frameCount: frameCount),
              let destination = pcmBuffer.int16ChannelData?.pointee,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard listSize > 0 else { return nil }

        return withUnsafeTemporaryAllocation(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { rawList -> AVAudioPCMBuffer? in
            guard let baseAddress = rawList.baseAddress else { return nil }

            let audioBufferList = baseAddress.bindMemory(to: AudioBufferList.self, capacity: 1)
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: listSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return nil }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let sourceIsFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            var copiedSamples = 0

            for buffer in buffers {
                guard let data = buffer.mData else { continue }

                if sourceIsFloat {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                    for index in 0..<sampleCount where copiedSamples < frameCount {
                        let sample = max(-1, min(1, samples[index]))
                        destination[copiedSamples] = Int16(sample * Float(Int16.max))
                        copiedSamples += 1
                    }
                } else {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
                    let remainingSamples = frameCount - copiedSamples
                    let samplesToCopy = min(sampleCount, remainingSamples)
                    guard samplesToCopy > 0 else { break }

                    destination
                        .advanced(by: copiedSamples)
                        .update(from: samples, count: samplesToCopy)
                    copiedSamples += samplesToCopy
                }
            }

            guard copiedSamples > 0 else { return nil }
            pcmBuffer.frameLength = AVAudioFrameCount(copiedSamples)
            return pcmBuffer
        }
    }

    private func reusablePCMBuffer(frameCount: Int) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(frameCount)
        let index = reusablePCMBufferCursor
        reusablePCMBufferCursor = (reusablePCMBufferCursor + 1) % Self.reusablePCMBufferCount

        if let buffer = reusablePCMBuffers[index],
           buffer.frameCapacity >= frameCapacity {
            buffer.frameLength = 0
            return buffer
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: frameCapacity
        )
        reusablePCMBuffers[index] = buffer
        return buffer
    }

    private func resetReusablePCMBuffers() {
        conversionLock.lock()
        reusablePCMBuffers = [AVAudioPCMBuffer?](
            repeating: nil,
            count: Self.reusablePCMBufferCount
        )
        reusablePCMBufferCursor = 0
        conversionLock.unlock()
    }
}
