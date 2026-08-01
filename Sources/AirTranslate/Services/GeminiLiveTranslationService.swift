import AVFoundation
import CoreMedia
import Foundation

protocol GeminiLiveTranslationServiceDelegate: AnyObject {
    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveInputTranscript text: String,
        languageCode: String?
    )
    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveOutputTranscript text: String,
        languageCode: String?
    )
    func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    )
    func geminiLiveTranslationServiceDidInterruptOutputAudio(_ service: GeminiLiveTranslationService)
    func geminiLiveTranslationService(_ service: GeminiLiveTranslationService, didFail error: Error)
}

final class GeminiLiveTranslationService: @unchecked Sendable {
    static let modelID = "gemini-3.5-live-translate-preview"

    private static let inputAudioSampleRate = 16_000
    private static let outputAudioSampleRate = 24_000.0
    private static let maxAudioChunkMilliseconds = 100
    private static let bytesPerPCM16Sample = 2
    private static let maxPCM16AudioChunkByteCount = inputAudioSampleRate
        * bytesPerPCM16Sample
        * maxAudioChunkMilliseconds
        / 1_000
    private static let maxPendingAudioSendCount = 48
    private static let connectionTimeoutMilliseconds = 10_000
    private static let maxPreSetupAudioSeconds = 3
    static let maxPreSetupAudioByteCount = inputAudioSampleRate
        * bytesPerPCM16Sample
        * maxPreSetupAudioSeconds

    var delegate: GeminiLiveTranslationServiceDelegate? {
        get {
            withStateLock { serviceDelegate }
        }
        set {
            withStateLock {
                serviceDelegate = newValue
            }
        }
    }
    /// Store integration can observe loss metrics without making the translation delegate requirement mandatory.
    /// The callback runs after the state lock is released and never contains audio, URLs, or provider diagnostics.
    var onAudioTransportDegraded: (@Sendable (RealtimeAudioTransportDegradation) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return audioTransportDegradationHandler
        }
        set {
            stateLock.lock()
            audioTransportDegradationHandler = newValue
            stateLock.unlock()
        }
    }

    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private weak var serviceDelegate: GeminiLiveTranslationServiceDelegate?
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var isPaused = false
    private var isSetupComplete = false
    private var setupError: Error?
    private var pendingAudioSendCount = 0
    private var droppedAudioChunkCount = 0
    private var droppedAudioByteCount = 0
    private var lastAudioDropPhase = RealtimeAudioDropPhase.sendWindow
    private var audioTransportDegradationHandler:
        (@Sendable (RealtimeAudioTransportDegradation) -> Void)?
    private var preSetupAudioChunks: [String] = []
    private var preSetupAudioByteCount = 0

    func start(targetLanguage: LanguageOption, model: GeminiTranslationModel) async throws {
        stop()

        guard model.isEnabled else { return }
        guard let apiKey = try GeminiAPIKeyStore.readAPIKey(), !apiKey.isEmpty else {
            throw GeminiLiveTranslationError.missingAPIKey
        }
        guard var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        ) else {
            throw GeminiLiveTranslationError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw GeminiLiveTranslationError.invalidResponse
        }

        let connectionObserver = GeminiLiveWebSocketConnectionObserver()
        let urlSession = URLSession(configuration: .default, delegate: connectionObserver, delegateQueue: nil)
        let webSocketTask = urlSession.webSocketTask(with: url)
        let installation: (
            generation: UInt64,
            receiveTask: Task<Void, Never>?,
            webSocketTask: URLSessionWebSocketTask?,
            urlSession: URLSession?
        ) = withStateLock {
            let displacedReceiveTask = self.receiveTask
            let displacedWebSocketTask = self.webSocketTask
            let displacedURLSession = self.urlSession
            connectionGeneration &+= 1
            self.urlSession = urlSession
            self.webSocketTask = webSocketTask
            self.receiveTask = nil
            isPaused = false
            isSetupComplete = false
            setupError = nil
            pendingAudioSendCount = 0
            droppedAudioChunkCount = 0
            droppedAudioByteCount = 0
            lastAudioDropPhase = .sendWindow
            preSetupAudioChunks = []
            preSetupAudioByteCount = 0
            return (
                generation: connectionGeneration,
                receiveTask: displacedReceiveTask,
                webSocketTask: displacedWebSocketTask,
                urlSession: displacedURLSession
            )
        }
        installation.receiveTask?.cancel()
        installation.webSocketTask?.cancel(
            with: URLSessionWebSocketTask.CloseCode.goingAway,
            reason: Data?.none
        )
        installation.urlSession?.finishTasksAndInvalidate()
        let generation = installation.generation
        webSocketTask.resume()

        do {
            try await connectionObserver.waitForOpen(timeoutMilliseconds: Self.connectionTimeoutMilliseconds)
        } catch {
            guard isCurrentConnection(generation, webSocketTask: webSocketTask) else {
                throw CancellationError()
            }
            throw Self.publicConnectionError(from: error)
        }
        guard isCurrentConnection(generation, webSocketTask: webSocketTask) else {
            throw CancellationError()
        }
        let receiveTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.receiveLoop(
                webSocketTask: webSocketTask,
                connectionGeneration: generation
            )
        }
        let installedReceiveTask = withStateLock {
            guard isCurrentConnectionLocked(generation, webSocketTask: webSocketTask) else {
                return false
            }
            self.receiveTask = receiveTask
            return true
        }
        guard installedReceiveTask else {
            receiveTask.cancel()
            throw CancellationError()
        }
        try await sendSetupMessage(
            model: model,
            targetLanguage: targetLanguage,
            connectionGeneration: generation
        )
        try await waitForSetupComplete(connectionGeneration: generation)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let state = withStateLock {
            (
                isPaused: isPaused,
                hasActiveWebSocketTask: webSocketTask != nil,
                connectionGeneration: connectionGeneration
            )
        }

        guard !state.isPaused, state.hasActiveWebSocketTask else { return }

        conversionLock.lock()
        let audioChunks = pcm16Base64AudioChunks(from: sampleBuffer)
        conversionLock.unlock()

        sendOrBufferAudioChunks(
            audioChunks,
            connectionGeneration: state.connectionGeneration
        )
    }

    func sendOrBufferAudioChunks(_ audioChunks: [String]) {
        sendOrBufferAudioChunks(audioChunks, connectionGeneration: nil)
    }

    private func sendOrBufferAudioChunks(
        _ audioChunks: [String],
        connectionGeneration expectedGeneration: UInt64?
    ) {
        guard !audioChunks.isEmpty else { return }

        stateLock.lock()
        if let expectedGeneration,
           !isCurrentConnectionLocked(expectedGeneration) {
            stateLock.unlock()
            return
        }
        guard isSetupComplete else {
            let degradation = bufferPreSetupAudioChunksLocked(audioChunks)
            let callback = audioTransportDegradationHandler
            stateLock.unlock()
            if let degradation {
                callback?(degradation)
            }
            return
        }
        let webSocketTask = webSocketTask
        let connectionGeneration = self.connectionGeneration
        stateLock.unlock()

        guard let webSocketTask else { return }
        sendAudioChunks(
            audioChunks,
            over: webSocketTask,
            connectionGeneration: connectionGeneration
        )
    }

    private func sendAudioChunks(
        _ audioChunks: [String],
        over webSocketTask: URLSessionWebSocketTask,
        connectionGeneration: UInt64
    ) {
        for audioData in audioChunks {
            let event = GeminiLiveRealtimeInputMessage(
                realtimeInput: GeminiLiveRealtimeInput(
                    audio: GeminiLiveAudioBlob(
                        data: audioData,
                        mimeType: "audio/pcm;rate=16000"
                    )
                )
            )
            guard let data = try? JSONEncoder().encode(event),
                  let text = String(data: data, encoding: .utf8) else { continue }
            guard reserveAudioSendSlot(
                audioByteCount: Self.decodedAudioByteCount(audioData),
                connectionGeneration: connectionGeneration
            ) else {
                continue
            }

            webSocketTask.send(.string(text)) { [weak self] error in
                self?.releaseAudioSendSlot(connectionGeneration: connectionGeneration)
                guard let error, let self else { return }
                self.notifyDelegate(connectionGeneration: connectionGeneration) {
                    $0.geminiLiveTranslationService(
                        self,
                        didFail: Self.publicConnectionError(from: error)
                    )
                }
            }
        }
    }

    private func bufferPreSetupAudioChunksLocked(
        _ audioChunks: [String]
    ) -> RealtimeAudioTransportDegradation? {
        var droppedChunkInThisCall = false
        for chunk in audioChunks {
            preSetupAudioChunks.append(chunk)
            preSetupAudioByteCount += Self.decodedAudioByteCount(chunk)
        }
        while preSetupAudioByteCount > Self.maxPreSetupAudioByteCount, !preSetupAudioChunks.isEmpty {
            let removed = preSetupAudioChunks.removeFirst()
            let removedByteCount = Self.decodedAudioByteCount(removed)
            preSetupAudioByteCount = max(0, preSetupAudioByteCount - removedByteCount)
            droppedAudioChunkCount += 1
            droppedAudioByteCount += removedByteCount
            lastAudioDropPhase = .preSetupBuffer
            droppedChunkInThisCall = true
        }
        return droppedChunkInThisCall ? audioTransportDegradationLocked(phase: .preSetupBuffer) : nil
    }

    private static func decodedAudioByteCount(_ base64: String) -> Int {
        Data(base64Encoded: base64)?.count ?? (base64.utf8.count / 4 * 3)
    }

    var bufferedPreSetupAudioChunks: [String] {
        withStateLock { preSetupAudioChunks }
    }

    func setPaused(_ isPaused: Bool) {
        stateLock.lock()
        self.isPaused = isPaused
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        connectionGeneration &+= 1
        let receiveTask = receiveTask
        let webSocketTask = webSocketTask
        let urlSession = urlSession
        self.receiveTask = nil
        self.webSocketTask = nil
        self.urlSession = nil
        isPaused = false
        isSetupComplete = false
        setupError = nil
        pendingAudioSendCount = 0
        droppedAudioChunkCount = 0
        droppedAudioByteCount = 0
        lastAudioDropPhase = .sendWindow
        preSetupAudioChunks = []
        preSetupAudioByteCount = 0
        stateLock.unlock()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private func sendSetupMessage(
        model: GeminiTranslationModel,
        targetLanguage: LanguageOption,
        connectionGeneration: UInt64
    ) async throws {
        let data = try Self.encodedSetupMessage(model: model, targetLanguage: targetLanguage)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeminiLiveTranslationError.invalidResponse
        }
        try await send(text, connectionGeneration: connectionGeneration)
    }

    nonisolated static func encodedSetupMessage(
        model: GeminiTranslationModel,
        targetLanguage: LanguageOption
    ) throws -> Data {
        let event = GeminiLiveSetupMessage(
            setup: GeminiLiveSetup(
                model: "models/\(model.apiModelID)",
                generationConfig: GeminiLiveGenerationConfig(
                    responseModalities: ["AUDIO"],
                    translationConfig: GeminiLiveTranslationConfig(
                        targetLanguageCode: targetLanguage.geminiLiveLanguageCode,
                        echoTargetLanguage: true
                    )
                ),
                realtimeInputConfig: GeminiLiveRealtimeInputConfig(
                    automaticActivityDetection: GeminiLiveActivityDetection(
                        startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
                        endOfSpeechSensitivity: "END_SENSITIVITY_HIGH",
                        silenceDurationMs: 250,
                        prefixPaddingMs: 120
                    )
                ),
                inputAudioTranscription: GeminiLiveEmptyObject(),
                outputAudioTranscription: GeminiLiveEmptyObject()
            )
        )
        return try JSONEncoder().encode(event)
    }

    private func waitForSetupComplete(connectionGeneration: UInt64) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while !Task.isCancelled {
            let state = withStateLock {
                (
                    isCurrent: isCurrentConnectionLocked(connectionGeneration),
                    isSetupComplete: isSetupComplete,
                    setupError: setupError
                )
            }

            guard state.isCurrent else { throw CancellationError() }
            if state.isSetupComplete { return }
            if let setupError = state.setupError { throw setupError }
            if clock.now >= deadline {
                throw GeminiLiveTranslationError.setupTimedOut
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CancellationError()
    }

    private func send(_ text: String, connectionGeneration: UInt64) async throws {
        var retryCount = 0
        while true {
            do {
                try await sendOnce(text, connectionGeneration: connectionGeneration)
                return
            } catch {
                guard retryCount < 40, Self.isSocketNotConnectedError(error) else {
                    throw Self.publicConnectionError(from: error)
                }

                retryCount += 1
                try await Task.sleep(for: .milliseconds(min(100 + (retryCount * 50), 500)))
            }
        }
    }

    private func sendOnce(_ text: String, connectionGeneration: UInt64) async throws {
        let webSocketTask: URLSessionWebSocketTask? = withStateLock {
            guard isCurrentConnectionLocked(connectionGeneration) else { return nil }
            return self.webSocketTask
        }
        guard let webSocketTask else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocketTask.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated static func isSocketNotConnectedError(_ error: Error) -> Bool {
        var nsError = error as NSError
        while true {
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOTCONN) {
                return true
            }
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNetworkConnectionLost {
                return true
            }
            guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            nsError = underlyingError
        }
    }

    nonisolated static func publicConnectionError(from error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if error is GeminiLiveTranslationError {
            return error
        }
        return GeminiLiveTranslationError.connectionFailed
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func isCurrentConnection(
        _ generation: UInt64,
        webSocketTask expectedWebSocketTask: URLSessionWebSocketTask? = nil
    ) -> Bool {
        withStateLock {
            isCurrentConnectionLocked(
                generation,
                webSocketTask: expectedWebSocketTask
            )
        }
    }

    private func isCurrentConnectionLocked(
        _ generation: UInt64,
        webSocketTask expectedWebSocketTask: URLSessionWebSocketTask? = nil
    ) -> Bool {
        guard isCurrentGenerationLocked(generation),
              let webSocketTask
        else {
            return false
        }
        guard let expectedWebSocketTask else { return true }
        return webSocketTask === expectedWebSocketTask
    }

    private func isCurrentGenerationLocked(_ generation: UInt64) -> Bool {
        connectionGeneration == generation
    }

    private func notifyDelegate(
        connectionGeneration expectedGeneration: UInt64?,
        _ notification: (GeminiLiveTranslationServiceDelegate) -> Void
    ) {
        let delegate: GeminiLiveTranslationServiceDelegate? = withStateLock {
            if let expectedGeneration,
               !isCurrentGenerationLocked(expectedGeneration) {
                return nil
            }
            return serviceDelegate
        }
        if let delegate {
            notification(delegate)
        }
    }

    private func receiveLoop(
        webSocketTask: URLSessionWebSocketTask,
        connectionGeneration: UInt64
    ) async {
        while !Task.isCancelled {
            guard isCurrentConnection(
                connectionGeneration,
                webSocketTask: webSocketTask
            ) else {
                return
            }
            do {
                let message = try await webSocketTask.receive()
                guard isCurrentConnection(
                    connectionGeneration,
                    webSocketTask: webSocketTask
                ) else {
                    return
                }
                switch message {
                case let .string(text):
                    handleEventText(text, connectionGeneration: connectionGeneration)
                case let .data(data):
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    handleEventText(text, connectionGeneration: connectionGeneration)
                @unknown default:
                    continue
                }
            } catch {
                guard !Task.isCancelled,
                      isCurrentConnection(
                        connectionGeneration,
                        webSocketTask: webSocketTask
                      )
                else {
                    return
                }
                let publicError = Self.publicConnectionError(from: error)
                recordSetupFailureIfNeeded(
                    publicError,
                    connectionGeneration: connectionGeneration
                )
                notifyDelegate(connectionGeneration: connectionGeneration) {
                    $0.geminiLiveTranslationService(self, didFail: publicError)
                }
                return
            }
        }
    }

    func handleEventText(_ text: String) {
        handleEventText(text, connectionGeneration: nil)
    }

    func handleEventText(_ text: String, connectionGeneration: UInt64) {
        handleEventText(text, connectionGeneration: Optional(connectionGeneration))
    }

    private func handleEventText(
        _ text: String,
        connectionGeneration: UInt64?
    ) {
        if let connectionGeneration,
           !withStateLock({ isCurrentGenerationLocked(connectionGeneration) }) {
            return
        }
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(GeminiLiveServerMessage.self, from: data)
        else { return }

        if event.error != nil {
            let serviceError = GeminiLiveTranslationError.server
            recordSetupFailureIfNeeded(
                serviceError,
                connectionGeneration: connectionGeneration
            )
            notifyDelegate(connectionGeneration: connectionGeneration) {
                $0.geminiLiveTranslationService(
                    self,
                    didFail: serviceError
                )
            }
            return
        }

        if event.setupComplete != nil {
            markSetupComplete(connectionGeneration: connectionGeneration)
            return
        }

        guard let content = event.serverContent else { return }
        if content.interrupted == true {
            notifyDelegate(connectionGeneration: connectionGeneration) {
                $0.geminiLiveTranslationServiceDidInterruptOutputAudio(self)
            }
        }
        if let inputTranscript = content.inputTranscription?.text,
           !inputTranscript.isEmpty {
            notifyDelegate(connectionGeneration: connectionGeneration) {
                $0.geminiLiveTranslationService(
                    self,
                    didReceiveInputTranscript: inputTranscript,
                    languageCode: content.inputTranscription?.languageCode
                )
            }
        }
        if let outputTranscript = content.outputTranscription?.text,
           !outputTranscript.isEmpty {
            notifyDelegate(connectionGeneration: connectionGeneration) {
                $0.geminiLiveTranslationService(
                    self,
                    didReceiveOutputTranscript: outputTranscript,
                    languageCode: content.outputTranscription?.languageCode
                )
            }
        }
        for part in content.modelTurn?.parts ?? [] {
            guard let inlineData = part.inlineData,
                  let audioData = inlineData.data,
                  !audioData.isEmpty
            else { continue }

            notifyDelegate(connectionGeneration: connectionGeneration) {
                $0.geminiLiveTranslationService(
                    self,
                    didOutputAudioPCM16Base64: audioData,
                    sampleRate: Self.outputAudioSampleRate(from: inlineData.mimeType)
                )
            }
        }
    }

    var isReadyForRealtimeInput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isSetupComplete
    }

    private func markSetupComplete(connectionGeneration expectedGeneration: UInt64?) {
        while true {
            stateLock.lock()
            if let expectedGeneration,
               !isCurrentGenerationLocked(expectedGeneration) {
                stateLock.unlock()
                return
            }
            guard let webSocketTask, !preSetupAudioChunks.isEmpty else {
                isSetupComplete = true
                setupError = nil
                preSetupAudioChunks = []
                preSetupAudioByteCount = 0
                stateLock.unlock()
                return
            }
            let bufferedChunks = preSetupAudioChunks
            preSetupAudioChunks = []
            preSetupAudioByteCount = 0
            let connectionGeneration = self.connectionGeneration
            stateLock.unlock()

            sendAudioChunks(
                coalescedAudioChunks(bufferedChunks),
                over: webSocketTask,
                connectionGeneration: connectionGeneration
            )
        }
    }

    func coalescedAudioChunks(_ chunks: [String]) -> [String] {
        var audioData = Data()
        for chunk in chunks {
            guard let decoded = Data(base64Encoded: chunk) else { continue }
            audioData.append(decoded)
        }
        guard !audioData.isEmpty else { return [] }
        return base64PCM16Chunks(from: audioData)
    }

    private func recordSetupFailureIfNeeded(
        _ error: Error,
        connectionGeneration expectedGeneration: UInt64?
    ) {
        stateLock.lock()
        if let expectedGeneration,
           !isCurrentGenerationLocked(expectedGeneration) {
            stateLock.unlock()
            return
        }
        if !isSetupComplete {
            setupError = error
        }
        stateLock.unlock()
    }

    nonisolated static func outputAudioSampleRate(from mimeType: String?) -> Double {
        guard let mimeType else { return outputAudioSampleRate }

        for part in mimeType.split(separator: ";") {
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPart.hasPrefix("rate=") else { continue }

            let value = trimmedPart.dropFirst("rate=".count)
            return Double(value) ?? outputAudioSampleRate
        }

        return outputAudioSampleRate
    }

    @discardableResult
    func reserveAudioSendSlot(audioByteCount: Int) -> Bool {
        reserveAudioSendSlot(
            audioByteCount: audioByteCount,
            connectionGeneration: nil
        )
    }

    func reserveAudioSendSlot(
        audioByteCount: Int,
        connectionGeneration expectedGeneration: UInt64?
    ) -> Bool {
        stateLock.lock()
        if let expectedGeneration,
           !isCurrentGenerationLocked(expectedGeneration) {
            stateLock.unlock()
            return false
        }
        guard pendingAudioSendCount < Self.maxPendingAudioSendCount else {
            droppedAudioChunkCount += 1
            droppedAudioByteCount += max(0, audioByteCount)
            lastAudioDropPhase = .sendWindow
            let degradation = audioTransportDegradationLocked(phase: .sendWindow)
            let callback = audioTransportDegradationHandler
            stateLock.unlock()
            callback?(degradation)
            return false
        }

        pendingAudioSendCount += 1
        stateLock.unlock()
        return true
    }

    func releaseAudioSendSlot() {
        releaseAudioSendSlot(connectionGeneration: nil)
    }

    func releaseAudioSendSlot(connectionGeneration expectedGeneration: UInt64?) {
        stateLock.lock()
        if let expectedGeneration,
           !isCurrentGenerationLocked(expectedGeneration) {
            stateLock.unlock()
            return
        }
        pendingAudioSendCount = max(0, pendingAudioSendCount - 1)
        stateLock.unlock()
    }

    var audioTransportDegradation: RealtimeAudioTransportDegradation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard droppedAudioChunkCount > 0 else { return nil }
        return audioTransportDegradationLocked(phase: lastAudioDropPhase)
    }

    var currentConnectionGeneration: UInt64 {
        withStateLock { connectionGeneration }
    }

    var pendingAudioSendSlotCount: Int {
        withStateLock { pendingAudioSendCount }
    }

    private func audioTransportDegradationLocked(
        phase: RealtimeAudioDropPhase
    ) -> RealtimeAudioTransportDegradation {
        RealtimeAudioTransportDegradation(
            provider: .gemini,
            policy: phase == .preSetupBuffer ? .dropOldest : .dropNewest,
            phase: phase,
            droppedChunkCount: droppedAudioChunkCount,
            droppedAudioDuration: TimeInterval(droppedAudioByteCount)
                / TimeInterval(Self.inputAudioSampleRate * Self.bytesPerPCM16Sample),
            pendingSendCount: pendingAudioSendCount,
            pendingSendLimit: Self.maxPendingAudioSendCount
        )
    }

    private func pcm16Base64AudioChunks(from sampleBuffer: CMSampleBuffer) -> [String] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return []
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
        guard listSize > 0 else { return [] }

        return withUnsafeTemporaryAllocation(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { rawList -> [String] in
            guard let baseAddress = rawList.baseAddress else { return [] }

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
            guard status == noErr else { return [] }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var audioData = Data()
            let sourceIsFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }

                if sourceIsFloat {
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                    for index in 0..<sampleCount {
                        let clamped = max(-1, min(1, samples[index]))
                        var sample = Int16(clamped * Float(Int16.max)).littleEndian
                        withUnsafeBytes(of: &sample) { audioData.append(contentsOf: $0) }
                    }
                } else {
                    audioData.append(data.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
                }
            }

            guard !audioData.isEmpty else { return [] }
            return base64PCM16Chunks(from: audioData)
        }
    }

    private func base64PCM16Chunks(from audioData: Data) -> [String] {
        guard audioData.count > Self.maxPCM16AudioChunkByteCount else {
            return [audioData.base64EncodedString()]
        }

        var chunks: [String] = []
        var offset = 0
        while offset < audioData.count {
            let end = min(offset + Self.maxPCM16AudioChunkByteCount, audioData.count)
            chunks.append(Data(audioData[offset..<end]).base64EncodedString())
            offset = end
        }
        return chunks
    }
}

final class GeminiLiveWebSocketConnectionObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completedResult: Result<Void, Error>?

    func waitForOpen(timeoutMilliseconds: Int) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
            guard !Task.isCancelled else { return }
            self?.resolve(.failure(GeminiLiveTranslationError.setupTimedOut))
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(continuation)
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        resolve(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resolve(.failure(error))
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        resolve(.failure(error ?? GeminiLiveTranslationError.setupTimedOut))
    }

    private func register(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(with: completedResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct GeminiLiveSetupMessage: Encodable {
    let setup: GeminiLiveSetup
}

private struct GeminiLiveSetup: Encodable {
    let model: String
    let generationConfig: GeminiLiveGenerationConfig
    let realtimeInputConfig: GeminiLiveRealtimeInputConfig?
    let inputAudioTranscription: GeminiLiveEmptyObject
    let outputAudioTranscription: GeminiLiveEmptyObject
}

private struct GeminiLiveRealtimeInputConfig: Encodable {
    let automaticActivityDetection: GeminiLiveActivityDetection
}

private struct GeminiLiveActivityDetection: Encodable {
    let startOfSpeechSensitivity: String
    let endOfSpeechSensitivity: String
    let silenceDurationMs: Int
    let prefixPaddingMs: Int
}

private struct GeminiLiveGenerationConfig: Encodable {
    let responseModalities: [String]
    let translationConfig: GeminiLiveTranslationConfig
}

private struct GeminiLiveTranslationConfig: Encodable {
    let targetLanguageCode: String
    let echoTargetLanguage: Bool
}

private struct GeminiLiveEmptyObject: Encodable {}

private struct GeminiLiveRealtimeInputMessage: Encodable {
    let realtimeInput: GeminiLiveRealtimeInput
}

private struct GeminiLiveRealtimeInput: Encodable {
    let audio: GeminiLiveAudioBlob
}

private struct GeminiLiveAudioBlob: Encodable {
    let data: String
    let mimeType: String
}

private struct GeminiLiveServerMessage: Decodable {
    let setupComplete: GeminiLiveSetupComplete?
    let serverContent: GeminiLiveServerContent?
    let error: GeminiLiveErrorBody?
}

private struct GeminiLiveSetupComplete: Decodable {}

private struct GeminiLiveServerContent: Decodable {
    let inputTranscription: GeminiLiveTranscript?
    let outputTranscription: GeminiLiveTranscript?
    let modelTurn: GeminiLiveModelTurn?
    let interrupted: Bool?
}

private struct GeminiLiveTranscript: Decodable {
    let text: String?
    let languageCode: String?
}

private struct GeminiLiveModelTurn: Decodable {
    let parts: [GeminiLivePart]?
}

private struct GeminiLivePart: Decodable {
    let inlineData: GeminiLiveInlineData?
}

private struct GeminiLiveInlineData: Decodable {
    let data: String?
    let mimeType: String?
}

private struct GeminiLiveErrorBody: Decodable {
    let message: String?
}

enum GeminiLiveTranslationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case setupTimedOut
    case connectionFailed
    case server

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppText.geminiAPIKeyMissing
        case .invalidResponse:
            AppText.geminiInvalidResponse
        case .setupTimedOut:
            AppText.geminiInvalidResponse
        case .connectionFailed:
            AppText.geminiConnectionFailed
        case .server:
            AppText.geminiInvalidResponse
        }
    }
}

private extension LanguageOption {
    var geminiLiveLanguageCode: String {
        String(id.prefix(2))
    }
}
