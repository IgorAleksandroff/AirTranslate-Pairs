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

    weak var delegate: GeminiLiveTranslationServiceDelegate?

    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isPaused = false
    private var isSetupComplete = false
    private var setupError: Error?
    private var pendingAudioSendCount = 0
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
        withStateLock {
            self.urlSession = urlSession
            self.webSocketTask = webSocketTask
            isSetupComplete = false
            setupError = nil
            preSetupAudioChunks = []
            preSetupAudioByteCount = 0
        }
        webSocketTask.resume()

        do {
            try await connectionObserver.waitForOpen(timeoutMilliseconds: Self.connectionTimeoutMilliseconds)
        } catch {
            throw Self.publicConnectionError(from: error)
        }
        withStateLock {
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        }
        try await sendSetupMessage(model: model, targetLanguage: targetLanguage)
        try await waitForSetupComplete()
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isPaused = isPaused
        let hasActiveWebSocketTask = webSocketTask != nil
        stateLock.unlock()

        guard !isPaused, hasActiveWebSocketTask else { return }

        conversionLock.lock()
        let audioChunks = pcm16Base64AudioChunks(from: sampleBuffer)
        conversionLock.unlock()

        sendOrBufferAudioChunks(audioChunks)
    }

    func sendOrBufferAudioChunks(_ audioChunks: [String]) {
        guard !audioChunks.isEmpty else { return }

        stateLock.lock()
        guard isSetupComplete else {
            bufferPreSetupAudioChunksLocked(audioChunks)
            stateLock.unlock()
            return
        }
        let webSocketTask = webSocketTask
        stateLock.unlock()

        guard let webSocketTask else { return }
        sendAudioChunks(audioChunks, over: webSocketTask)
    }

    private func sendAudioChunks(_ audioChunks: [String], over webSocketTask: URLSessionWebSocketTask) {
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
            guard reserveAudioSendSlot() else { continue }

            webSocketTask.send(.string(text)) { [weak self] error in
                self?.releaseAudioSendSlot()
                guard let error, let self else { return }
                self.delegate?.geminiLiveTranslationService(
                    self,
                    didFail: Self.publicConnectionError(from: error)
                )
            }
        }
    }

    private func bufferPreSetupAudioChunksLocked(_ audioChunks: [String]) {
        for chunk in audioChunks {
            preSetupAudioChunks.append(chunk)
            preSetupAudioByteCount += Self.estimatedPCM16ByteCount(ofBase64: chunk)
        }
        while preSetupAudioByteCount > Self.maxPreSetupAudioByteCount, preSetupAudioChunks.count > 1 {
            let removed = preSetupAudioChunks.removeFirst()
            preSetupAudioByteCount -= Self.estimatedPCM16ByteCount(ofBase64: removed)
        }
    }

    private static func estimatedPCM16ByteCount(ofBase64 chunk: String) -> Int {
        chunk.utf8.count / 4 * 3
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
        setPaused(false)
        stateLock.lock()
        let receiveTask = receiveTask
        let webSocketTask = webSocketTask
        let urlSession = urlSession
        self.receiveTask = nil
        self.webSocketTask = nil
        self.urlSession = nil
        isSetupComplete = false
        setupError = nil
        pendingAudioSendCount = 0
        preSetupAudioChunks = []
        preSetupAudioByteCount = 0
        stateLock.unlock()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private func sendSetupMessage(model: GeminiTranslationModel, targetLanguage: LanguageOption) async throws {
        let data = try Self.encodedSetupMessage(model: model, targetLanguage: targetLanguage)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeminiLiveTranslationError.invalidResponse
        }
        try await send(text)
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

    private func waitForSetupComplete() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while !Task.isCancelled {
            let state = withStateLock {
                (isSetupComplete, setupError)
            }

            if state.0 { return }
            if let setupError = state.1 { throw setupError }
            if clock.now >= deadline {
                throw GeminiLiveTranslationError.setupTimedOut
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CancellationError()
    }

    private func send(_ text: String) async throws {
        var retryCount = 0
        while true {
            do {
                try await sendOnce(text)
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

    private func sendOnce(_ text: String) async throws {
        guard let webSocketTask else { return }
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

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask else { return }
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case let .string(text):
                    handleEventText(text)
                case let .data(data):
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    handleEventText(text)
                @unknown default:
                    continue
                }
            } catch {
                guard !Task.isCancelled else { return }
                let publicError = Self.publicConnectionError(from: error)
                recordSetupFailureIfNeeded(publicError)
                delegate?.geminiLiveTranslationService(self, didFail: publicError)
                return
            }
        }
    }

    func handleEventText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(GeminiLiveServerMessage.self, from: data)
        else { return }

        if let error = event.error {
            let serviceError = GeminiLiveTranslationError.server(error.message)
            recordSetupFailureIfNeeded(serviceError)
            delegate?.geminiLiveTranslationService(
                self,
                didFail: serviceError
            )
            return
        }

        if event.setupComplete != nil {
            markSetupComplete()
            return
        }

        guard let content = event.serverContent else { return }
        if content.interrupted == true {
            delegate?.geminiLiveTranslationServiceDidInterruptOutputAudio(self)
        }
        if let inputTranscript = content.inputTranscription?.text,
           !inputTranscript.isEmpty {
            delegate?.geminiLiveTranslationService(
                self,
                didReceiveInputTranscript: inputTranscript,
                languageCode: content.inputTranscription?.languageCode
            )
        }
        if let outputTranscript = content.outputTranscription?.text,
           !outputTranscript.isEmpty {
            delegate?.geminiLiveTranslationService(
                self,
                didReceiveOutputTranscript: outputTranscript,
                languageCode: content.outputTranscription?.languageCode
            )
        }
        for part in content.modelTurn?.parts ?? [] {
            guard let inlineData = part.inlineData,
                  let audioData = inlineData.data,
                  !audioData.isEmpty
            else { continue }

            delegate?.geminiLiveTranslationService(
                self,
                didOutputAudioPCM16Base64: audioData,
                sampleRate: Self.outputAudioSampleRate(from: inlineData.mimeType)
            )
        }
    }

    var isReadyForRealtimeInput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isSetupComplete
    }

    private func markSetupComplete() {
        while true {
            stateLock.lock()
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
            stateLock.unlock()

            sendAudioChunks(coalescedAudioChunks(bufferedChunks), over: webSocketTask)
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

    private func recordSetupFailureIfNeeded(_ error: Error) {
        stateLock.lock()
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

    private func reserveAudioSendSlot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard pendingAudioSendCount < Self.maxPendingAudioSendCount else {
            return false
        }

        pendingAudioSendCount += 1
        return true
    }

    private func releaseAudioSendSlot() {
        stateLock.lock()
        pendingAudioSendCount = max(0, pendingAudioSendCount - 1)
        stateLock.unlock()
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
    case server(String?)

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
        case let .server(message):
            message ?? AppText.geminiInvalidResponse
        }
    }
}

private extension LanguageOption {
    var geminiLiveLanguageCode: String {
        String(id.prefix(2))
    }
}
