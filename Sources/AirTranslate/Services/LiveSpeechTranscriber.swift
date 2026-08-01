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

final class LiveSpeechTranscriber: @unchecked Sendable {
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
    private var reservedLocales: [Locale] = []
    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private let authorizationRequester: @Sendable () async -> Bool
    private var isPaused = false
    private var reusablePCMBuffers = [AVAudioPCMBuffer?](
        repeating: nil,
        count: reusablePCMBufferCount
    )
    private var reusablePCMBufferCursor = 0

    init(
        authorizationRequester: @escaping @Sendable () async -> Bool = {
            await LiveSpeechTranscriber.requestAuthorization()
        }
    ) {
        self.authorizationRequester = authorizationRequester
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
        do {
            let authorized = await authorizationRequester()
            // SFSpeechRecognizer's completion handler can resume after its
            // surrounding task was cancelled. Check before reserving locales
            // or constructing an analyzer so that stale starts stay local.
            try Task.checkCancellation()
            guard authorized else { throw SpeechError.notAuthorized }

            stop()

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

                try await AssetInventory.reserve(locale: supportedLocale)
                reservedLocales.append(supportedLocale)
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
            stateLock.withLock {
                self.inputQueue = inputQueue
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            self.analyzer = analyzer

            try Task.checkCancellation()
            try await analyzer.prepareToAnalyze(in: audioFormat)
            try Task.checkCancellation()

            self.analyzer = analyzer
            analyzeTask = Task { [weak self] in
                do {
                    try await analyzer.start(inputSequence: inputQueue.stream)
                } catch {
                    guard let self else { return }
                    self.delegate?.liveSpeechTranscriber(self, didFail: error)
                }
            }

            resultTasks = transcribers.map { entry in
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
            try Task.checkCancellation()
        } catch {
            // This instance may be a stale candidate which was never promoted
            // to TranslationSessionStore. Its cleanup must not rely on the
            // store's currently active generation.
            stop()
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
        stateLock.lock()
        isPaused = false
        let inputQueue = inputQueue
        self.inputQueue = nil
        stateLock.unlock()
        inputQueue?.finish()
        analyzeTask?.cancel()
        analyzeTask = nil
        resultTasks.forEach { $0.cancel() }
        resultTasks = []
        resetReusablePCMBuffers()

        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil

        let localesToRelease = reservedLocales
        reservedLocales = []
        Task {
            for locale in localesToRelease {
                await AssetInventory.release(reservedLocale: locale)
            }
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
        stateLock.lock()
        let hasInputQueue = inputQueue != nil
        stateLock.unlock()

        return analyzer != nil
            || hasInputQueue
            || analyzeTask != nil
            || !resultTasks.isEmpty
            || !reservedLocales.isEmpty
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
