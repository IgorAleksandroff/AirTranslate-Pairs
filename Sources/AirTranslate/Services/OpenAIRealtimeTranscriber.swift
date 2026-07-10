import AVFoundation
import CoreMedia
import Foundation

final class OpenAIRealtimeTranscriber: @unchecked Sendable {
    private static let realtimeAudioSampleRate = 24_000
    private static let maxAudioChunkMilliseconds = 80
    private static let bytesPerPCM16Sample = 2
    private static let maxPCM16AudioChunkByteCount = realtimeAudioSampleRate
        * bytesPerPCM16Sample
        * maxAudioChunkMilliseconds
        / 1_000
    private static let maxPendingAudioSendCount = 48
    private static let realtimeTranscriptPublishInterval: TimeInterval = 0.05

    enum OutputMode {
        case transcription
        case translationOnly
    }

    weak var delegate: LiveSpeechTranscriberDelegate?

    private let stateLock = NSLock()
    private let conversionLock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var language = LanguageOption.supported[0]
    private var outputMode = OutputMode.transcription
    private var isPaused = false
    private var pendingAudioSendCount = 0
    private let proxyTranscriber = LiveSpeechTranscriber()
    private let realtimeTranscriptionPublishThrottle = RealtimeTranscriptPublishThrottle(
        publishInterval: OpenAIRealtimeTranscriber.realtimeTranscriptPublishInterval
    )
    private let realtimeTranslationInputPublishThrottle = RealtimeTranscriptPublishThrottle(
        publishInterval: OpenAIRealtimeTranscriber.realtimeTranscriptPublishInterval
    )
    private let realtimeTranslationOutputPublishThrottle = RealtimeTranscriptPublishThrottle(
        publishInterval: OpenAIRealtimeTranscriber.realtimeTranscriptPublishInterval
    )

    func start(language: LanguageOption, model: OpenAIRealtimeTranscriptionModel) async throws {
        try await start(
            language: language,
            modelID: model.rawValue,
            outputMode: .transcription,
            isEnabled: model.isEnabled
        )
    }

    func startRealtimeTranslationOnly(language: LanguageOption, model: OpenAIRealtimeTranslationModel) async throws {
        try await start(
            language: language,
            modelID: model.apiModelID,
            outputMode: .translationOnly,
            isEnabled: model.usesRealtimeAudioTranslation
        )
    }

    private func start(
        language: LanguageOption,
        modelID: String,
        outputMode: OutputMode,
        isEnabled: Bool
    ) async throws {
        stop()

        guard isEnabled else { return }
        guard let apiKey = try OpenAIAPIKeyStore.readAPIKey(), !apiKey.isEmpty else {
            throw OpenAITranslationError.missingAPIKey
        }

        self.language = language
        self.outputMode = outputMode
        resetRealtimeTranscriptBuffers()
        let url: URL
        switch outputMode {
        case .transcription:
            url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        case .translationOnly:
            url = URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(modelID)")!
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        try await sendSessionUpdate(language: language, modelID: modelID)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isPaused = isPaused
        let webSocketTask = webSocketTask
        let audioAppendEventType = outputMode.audioAppendEventType
        stateLock.unlock()

        guard !isPaused, let webSocketTask else { return }

        conversionLock.lock()
        let audioChunks = pcm16Base64AudioChunks(from: sampleBuffer)
        conversionLock.unlock()

        for audio in audioChunks {
            let event = OpenAIRealtimeAudioAppendEvent(
                type: audioAppendEventType,
                audio: audio
            )
            guard let data = try? JSONEncoder().encode(event),
                  let text = String(data: data, encoding: .utf8) else { continue }
            guard reserveAudioSendSlot() else { continue }

            webSocketTask.send(.string(text)) { [weak self] error in
                self?.releaseAudioSendSlot()
                guard let error, let self else { return }
                self.delegate?.liveSpeechTranscriber(self.proxyTranscriber, didFail: error)
            }
        }
    }

    func setPaused(_ isPaused: Bool) {
        stateLock.lock()
        self.isPaused = isPaused
        stateLock.unlock()
    }

    func stop() {
        setPaused(false)
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stateLock.lock()
        pendingAudioSendCount = 0
        stateLock.unlock()
        resetRealtimeTranscriptBuffers()
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

    private func sendSessionUpdate(language: LanguageOption, modelID: String) async throws {
        let data: Data
        switch outputMode {
        case .transcription:
            let event = OpenAIRealtimeTranscriptionSessionUpdateEvent(
                session: OpenAIRealtimeTranscriptionSession(
                    type: "transcription",
                    audio: OpenAIRealtimeTranscriptionAudio(
                        input: OpenAIRealtimeTranscriptionAudioInput(
                            format: OpenAIRealtimeAudioFormat(type: "audio/pcm", rate: Self.realtimeAudioSampleRate),
                            transcription: OpenAIRealtimeTranscriptionConfig(
                                model: modelID,
                                language: language.openAILanguageCode
                            ),
                            turnDetection: .lowLatencyServerVAD,
                            noiseReduction: OpenAIRealtimeNoiseReduction(type: "near_field")
                        )
                    )
                )
            )
            data = try JSONEncoder().encode(event)
        case .translationOnly:
            let event = OpenAIRealtimeTranslationSessionUpdateEvent(
                session: OpenAIRealtimeTranslationSession(
                    audio: OpenAIRealtimeTranslationAudio(
                        input: OpenAIRealtimeTranslationAudioInput(
                            format: OpenAIRealtimeAudioFormat(type: "audio/pcm", rate: Self.realtimeAudioSampleRate),
                            transcription: OpenAIRealtimeTranslationInputTranscription(
                                model: OpenAIRealtimeTranscriptionModel.gptRealtimeWhisper.rawValue
                            ),
                            turnDetection: .lowLatencyServerVAD,
                            noiseReduction: OpenAIRealtimeNoiseReduction(type: "near_field")
                        ),
                        output: OpenAIRealtimeTranslationAudioOutput(
                            language: language.openAILanguageCode
                        )
                    )
                )
            )
            data = try JSONEncoder().encode(event)
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await send(text)
    }

    private func send(_ text: String) async throws {
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

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask else { return }
            do {
                let message = try await webSocketTask.receive()
                guard case let .string(text) = message else { continue }
                handleEventText(text)
            } catch {
                guard !Task.isCancelled else { return }
                delegate?.liveSpeechTranscriber(proxyTranscriber, didFail: error)
                return
            }
        }
    }

    func handleEventText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(OpenAIRealtimeTranscriptionEvent.self, from: data)
        else { return }

        switch event.type {
        case "conversation.item.input_audio_transcription.delta",
            "session.input_audio_transcription.delta",
            "session.input_transcription.delta",
            "session.input_transcript.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            switch outputMode {
            case .transcription:
                appendRealtimeTranscriptionDelta(delta)
            case .translationOnly:
                appendRealtimeTranslationInputDelta(delta)
            }
        case "conversation.item.input_audio_transcription.completed",
            "session.input_audio_transcription.completed",
            "session.input_transcription.completed",
            "session.input_transcript.completed",
            "session.input_transcript.done":
            let transcript = event.transcript ?? ""
            switch outputMode {
            case .transcription:
                realtimeTranscriptionPublishThrottle.finish(finalText: transcript) { [weak self] text in
                    self?.publishRecognizedTranscript(text)
                }
            case .translationOnly:
                realtimeTranslationInputPublishThrottle.finish(finalText: transcript) { [weak self] text in
                    self?.publishRealtimeTranslationInputTranscript(text)
                }
            }
        case "session.output_transcript.delta":
            guard outputMode == .translationOnly,
                  let delta = event.delta,
                  !delta.isEmpty else { return }
            appendRealtimeTranslationOutputDelta(delta)
        case "session.output_transcript.completed",
            "session.output_transcript.done":
            guard outputMode == .translationOnly else { return }
            realtimeTranslationOutputPublishThrottle.finish(finalText: event.transcript) { [weak self] text in
                self?.publishTranslatedTranscript(text)
            }
        case "session.output_audio.delta":
            guard outputMode == .translationOnly,
                  let delta = event.delta,
                  !delta.isEmpty else { return }
            delegate?.liveSpeechTranscriber(
                proxyTranscriber,
                didOutputAudioPCM16Base64: delta,
                sampleRate: Double(Self.realtimeAudioSampleRate)
            )
        case "error":
            delegate?.liveSpeechTranscriber(proxyTranscriber, didFail: OpenAIRealtimeTranscriberError.server(event.error?.message))
        default:
            return
        }
    }

    private func appendRealtimeTranscriptionDelta(_ delta: String) {
        realtimeTranscriptionPublishThrottle.append(delta) { [weak self] text in
            self?.publishRecognizedTranscript(text)
        }
    }

    private func appendRealtimeTranslationInputDelta(_ delta: String) {
        realtimeTranslationInputPublishThrottle.append(delta) { [weak self] text in
            self?.publishRealtimeTranslationInputTranscript(text)
        }
    }

    private func appendRealtimeTranslationOutputDelta(_ delta: String) {
        realtimeTranslationOutputPublishThrottle.append(delta) { [weak self] text in
            self?.publishTranslatedTranscript(text)
        }
    }

    private func publishRecognizedTranscript(_ text: String) {
        delegate?.liveSpeechTranscriber(
            proxyTranscriber,
            didRecognize: text,
            language: language,
            confidence: 0.5
        )
    }

    private func publishRealtimeTranslationInputTranscript(_ text: String) {
        delegate?.liveSpeechTranscriber(
            proxyTranscriber,
            didRecognizeSourceTranscript: text,
            confidence: 0.5
        )
    }

    private func publishTranslatedTranscript(_ text: String) {
        delegate?.liveSpeechTranscriber(
            proxyTranscriber,
            didTranslate: text,
            language: language,
            confidence: 0.5
        )
    }

    private func resetRealtimeTranscriptBuffers() {
        realtimeTranscriptionPublishThrottle.reset()
        realtimeTranslationInputPublishThrottle.reset()
        realtimeTranslationOutputPublishThrottle.reset()
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

final class RealtimeTranscriptPublishThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let publishInterval: TimeInterval
    private var text = ""
    private var lastPublishAt = Date.distantPast
    private var pendingFlushTask: Task<Void, Never>?

    init(publishInterval: TimeInterval) {
        self.publishInterval = publishInterval
    }

    func append(_ delta: String, publish: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        text += delta
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPublishAt)
        guard elapsed >= publishInterval else {
            scheduleTrailingFlushLocked(after: publishInterval - elapsed, publish: publish)
            return
        }
        cancelPendingFlushLocked()
        lastPublishAt = now
        publish(text)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        cancelPendingFlushLocked()
        text = ""
        lastPublishAt = .distantPast
    }

    func finish(
        finalText: String?,
        publish: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        cancelPendingFlushLocked()
        let bufferedText = text
        let completedText: String
        if let finalText, !finalText.isEmpty {
            completedText = finalText
        } else {
            completedText = bufferedText
        }
        text = ""
        lastPublishAt = .distantPast
        lock.unlock()

        guard !completedText.isEmpty else { return }
        publish(completedText)
    }

    private func scheduleTrailingFlushLocked(
        after delay: TimeInterval,
        publish: @escaping @Sendable (String) -> Void
    ) {
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.flushPendingText(publish: publish)
        }
    }

    private func flushPendingText(publish: @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !Task.isCancelled else { return }
        pendingFlushTask = nil
        guard !text.isEmpty else { return }
        lastPublishAt = Date()
        publish(text)
    }

    private func cancelPendingFlushLocked() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
    }
}

private struct OpenAIRealtimeTranscriptionSessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: OpenAIRealtimeTranscriptionSession
}

private struct OpenAIRealtimeTranslationSessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: OpenAIRealtimeTranslationSession
}

private struct OpenAIRealtimeTranscriptionSession: Encodable {
    let type: String
    let audio: OpenAIRealtimeTranscriptionAudio
}

private struct OpenAIRealtimeTranscriptionAudio: Encodable {
    let input: OpenAIRealtimeTranscriptionAudioInput
}

private struct OpenAIRealtimeTranscriptionAudioInput: Encodable {
    let format: OpenAIRealtimeAudioFormat
    let transcription: OpenAIRealtimeTranscriptionConfig
    let turnDetection: OpenAIRealtimeTurnDetection
    let noiseReduction: OpenAIRealtimeNoiseReduction

    private enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
        case noiseReduction = "noise_reduction"
    }
}

private struct OpenAIRealtimeAudioFormat: Encodable {
    let type: String
    let rate: Int
}

private struct OpenAIRealtimeTranslationSession: Encodable {
    let audio: OpenAIRealtimeTranslationAudio
}

private struct OpenAIRealtimeTranslationAudio: Encodable {
    let input: OpenAIRealtimeTranslationAudioInput
    let output: OpenAIRealtimeTranslationAudioOutput
}

private struct OpenAIRealtimeTranslationAudioInput: Encodable {
    let format: OpenAIRealtimeAudioFormat
    let transcription: OpenAIRealtimeTranslationInputTranscription
    let turnDetection: OpenAIRealtimeTurnDetection
    let noiseReduction: OpenAIRealtimeNoiseReduction

    private enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
        case noiseReduction = "noise_reduction"
    }
}

private struct OpenAIRealtimeTranslationInputTranscription: Encodable {
    let model: String
}

private struct OpenAIRealtimeTranslationAudioOutput: Encodable {
    let language: String
}

private struct OpenAIRealtimeTranscriptionConfig: Encodable {
    let model: String
    let language: String
}

private struct OpenAIRealtimeTurnDetection: Encodable {
    let type: String
    let threshold: Double?
    let prefixPaddingMilliseconds: Int?
    let silenceDurationMilliseconds: Int?

    static let lowLatencyServerVAD = OpenAIRealtimeTurnDetection(
        type: "server_vad",
        threshold: 0.42,
        prefixPaddingMilliseconds: 120,
        silenceDurationMilliseconds: 220
    )

    init(
        type: String,
        threshold: Double? = nil,
        prefixPaddingMilliseconds: Int? = nil,
        silenceDurationMilliseconds: Int? = nil
    ) {
        self.type = type
        self.threshold = threshold
        self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case threshold
        case prefixPaddingMilliseconds = "prefix_padding_ms"
        case silenceDurationMilliseconds = "silence_duration_ms"
    }
}

private struct OpenAIRealtimeNoiseReduction: Encodable {
    let type: String
}

private struct OpenAIRealtimeAudioAppendEvent: Encodable {
    let type: String
    let audio: String
}

private struct OpenAIRealtimeTranscriptionEvent: Decodable {
    let type: String
    let delta: String?
    let transcript: String?
    let error: OpenAIRealtimeErrorBody?
}

private struct OpenAIRealtimeErrorBody: Decodable {
    let message: String?
}

private enum OpenAIRealtimeTranscriberError: LocalizedError {
    case server(String?)

    var errorDescription: String? {
        switch self {
        case let .server(message):
            message ?? AppText.openAIInvalidResponse
        }
    }
}

private extension OpenAIRealtimeTranscriber.OutputMode {
    var audioAppendEventType: String {
        switch self {
        case .transcription:
            "input_audio_buffer.append"
        case .translationOnly:
            "session.input_audio_buffer.append"
        }
    }
}

private extension LanguageOption {
    var openAILanguageCode: String {
        String(id.prefix(2))
    }
}
