import AVFAudio
import AppKit
import AirTranslateCore
import Foundation
import Observation

enum PrivacySettingsPane {
    case screenRecording
    case systemAudioRecording
    case microphone
    case speechRecognition

    fileprivate var anchor: String {
        switch self {
        case .screenRecording, .systemAudioRecording:
            // macOS groups Screen Recording and System Audio Recording in this pane.
            "Privacy_ScreenCapture"
        case .microphone:
            "Privacy_Microphone"
        case .speechRecognition:
            "Privacy_SpeechRecognition"
        }
    }
}

private enum SettingsKey {
    static let sourceLanguageID = "sourceLanguageID"
    static let targetLanguageID = "targetLanguageID"
    static let selectedModelID = "selectedModelID"
    static let openAITranscriptionModelID = "openAITranscriptionModelID"
    static let openAITranslationModelID = "openAITranslationModelID"
    static let geminiTranslationModelID = "geminiTranslationModelID"
    static let isDubbingEnabled = "isDubbingEnabled"
    static let appleVoiceOutputEnabled = "appleVoiceOutputEnabled"
    static let providerVoiceOutputEnabled = "providerVoiceOutputEnabled"
    static let translatedVoiceVolume = "translatedVoiceVolume"
    static let isTranscriptLintEnabled = "isTranscriptLintEnabled"
    static let floatingCaptionDisplayMode = "floatingCaptionDisplayMode"
    static let floatingCaptionTextSize = "floatingCaptionTextSize"
    static let floatingCaptionLineCount = "floatingCaptionLineCount"
    static let keepsFloatingCaptionAboveOtherWindows = "keepsFloatingCaptionAboveOtherWindows"
    static let sentencePanelBackgroundOpacity = "sentencePanelBackgroundOpacity"
    static let sentencePanelFontSize = "sentencePanelFontSize"
    static let paragraphBreakSilenceInterval = "paragraphBreakSilenceInterval"
    static let savedTranscriptContentMode = "savedTranscriptContentMode"
    static let sessionDurationMode = "sessionDurationMode"
    static let audioInputSource = "audioInputSource"
    static let selectedMicrophoneInputDeviceID = "selectedMicrophoneInputDeviceID"
    static let isAppleSourceAutoDetectionEnabled = "isAppleSourceAutoDetectionEnabled"
}

private struct TranslationRequest {
    let line: CaptionLine
    let sourceText: String
    let translationSourceText: String
    let source: LanguageOption
    let target: LanguageOption
}

private struct PendingCaptionPresentation {
    let lineID: UUID
    let sourceText: String
    let isFinal: Bool
    let source: LanguageOption
    let target: LanguageOption
}

private struct PendingRecognizedCaption {
    let sourceText: String
    let recognizedLanguage: LanguageOption
    let confidence: Double
}

struct StartConfiguration: Equatable {
    let audioInputSource: AudioInputSource
    let microphoneDeviceUniqueID: String?
    let sourceLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let selectedModel: IntelligenceModel
    let openAITranscriptionModel: OpenAIRealtimeTranscriptionModel
    let openAITranslationModel: OpenAIRealtimeTranslationModel
    let geminiTranslationModel: GeminiTranslationModel
    let usesAppleSourceAutoDetection: Bool

    var isUsingGPTTranscriptionMode: Bool {
        openAITranscriptionModel == .gptLiveTranscribe
    }

    var isTranscribeOnlyMode: Bool {
        selectedModel == .appleSpeechOnly || isUsingGPTTranscriptionMode
    }

    var sampleRate: Int {
        openAITranscriptionModel.isEnabled || openAITranslationModel.usesRealtimeAudioTranslation
            ? 24_000
            : 16_000
    }
}

enum PipelineLifecyclePhase: Equatable {
    case stopped
    case starting
    case running
}

enum PipelineStartValidation: Equatable {
    case valid
    case staleGeneration
    case configurationChanged
}

struct PipelineLifecycleState {
    private(set) var generation: UInt64 = 0
    private(set) var phase = PipelineLifecyclePhase.stopped
    private(set) var startConfiguration: StartConfiguration?

    mutating func beginStart(configuration: StartConfiguration) -> UInt64 {
        generation &+= 1
        phase = .starting
        startConfiguration = configuration
        return generation
    }

    mutating func validateStart(
        generation expectedGeneration: UInt64,
        currentConfiguration: StartConfiguration
    ) -> PipelineStartValidation {
        guard generation == expectedGeneration, phase == .starting else {
            return .staleGeneration
        }
        guard startConfiguration == currentConfiguration else {
            generation &+= 1
            phase = .stopped
            startConfiguration = nil
            return .configurationChanged
        }
        return .valid
    }

    mutating func markRunning(
        generation expectedGeneration: UInt64,
        currentConfiguration: StartConfiguration
    ) -> PipelineStartValidation {
        let validation = validateStart(
            generation: expectedGeneration,
            currentConfiguration: currentConfiguration
        )
        if validation == .valid {
            phase = .running
        }
        return validation
    }

    mutating func fail(generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, phase != .stopped else {
            return false
        }
        stop()
        return true
    }

    mutating func failCurrent() -> Bool {
        guard phase != .stopped else { return false }
        stop()
        return true
    }

    mutating func stop() {
        generation &+= 1
        phase = .stopped
        startConfiguration = nil
    }

    func acceptsSample(generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && phase == .running
    }

    func isActive(generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && phase != .stopped
    }
}

private enum PipelineStartError: LocalizedError {
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .configurationChanged:
            AppText.localized(
                english: "Capture settings changed while starting. Start again.",
                korean: "시작하는 동안 캡처 설정이 변경되었습니다. 다시 시작해 주세요.",
                japanese: "開始中にキャプチャ設定が変更されました。もう一度開始してください。",
                chineseSimplified: "启动期间捕获设置已更改。请重新启动。"
            )
        }
    }
}

private struct RealtimeAudioTransportError: LocalizedError {
    let degradation: RealtimeAudioTransportDegradation

    var errorDescription: String? {
        AppText.localized(
            english: "Realtime audio could not keep up, so capture was stopped to avoid missing captions.",
            korean: "실시간 오디오 전송이 입력을 따라가지 못해 자막 누락을 막기 위해 캡처를 중지했습니다.",
            japanese: "リアルタイム音声転送が入力に追いつかなかったため、字幕の欠落を防ぐためにキャプチャを停止しました。",
            chineseSimplified: "实时音频传输无法跟上输入，已停止捕获以避免字幕缺失。"
        )
    }
}

private final class AudioSamplePipelineRegistry: @unchecked Sendable {
    private struct Pipeline {
        let generation: UInt64
        let transcriber: LiveSpeechTranscriber
        let openAITranscriber: OpenAIRealtimeTranscriber
        let geminiLiveTranslator: GeminiLiveTranslationService
    }

    private let lock = NSLock()
    private var pipeline: Pipeline?

    func publish(
        generation: UInt64,
        transcriber: LiveSpeechTranscriber,
        openAITranscriber: OpenAIRealtimeTranscriber,
        geminiLiveTranslator: GeminiLiveTranslationService
    ) {
        lock.lock()
        pipeline = Pipeline(
            generation: generation,
            transcriber: transcriber,
            openAITranscriber: openAITranscriber,
            geminiLiveTranslator: geminiLiveTranslator
        )
        lock.unlock()
    }

    func clear() {
        lock.lock()
        pipeline = nil
        lock.unlock()
    }

    func append(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let pipeline, pipeline.generation == generation else { return }

        // clear() waits for any in-flight append to finish before the MainActor
        // stops or replaces these backends.
        pipeline.transcriber.append(sampleBuffer)
        pipeline.openAITranscriber.append(sampleBuffer)
        pipeline.geminiLiveTranslator.append(sampleBuffer)
    }
}

private struct OpenAITerminalTranscript: Sendable {
    let text: String
    let language: LanguageOption
    let confidence: Double
    let transcriber: OpenAIRealtimeTranscriber
}

private final class OpenAITerminalTranscriptMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var transcripts: [OpenAITerminalTranscript] = []

    func append(_ transcript: OpenAITerminalTranscript) {
        lock.lock()
        transcripts.append(transcript)
        lock.unlock()
    }

    func drain() -> [OpenAITerminalTranscript] {
        lock.lock()
        let drained = transcripts
        transcripts.removeAll()
        lock.unlock()
        return drained
    }
}

struct AutoDetectionLanguageChangeConfirmation: Equatable {
    let currentLanguage: LanguageOption
    let detectedLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let sourceText: String
    let confidence: Double
}

enum AutoDetectionLanguageChangePolicy {
    static func shouldRequestConfirmation(
        isAutoDetectionEnabled: Bool,
        activeLanguage: LanguageOption?,
        detectedLanguage: LanguageOption,
        confidence: Double,
        hadLongSilence: Bool,
        hasVisibleTranscript: Bool,
        minimumSwitchConfidence: Double
    ) -> Bool {
        guard isAutoDetectionEnabled,
              hasVisibleTranscript,
              hadLongSilence,
              confidence >= minimumSwitchConfidence,
              let activeLanguage,
              activeLanguage != detectedLanguage
        else {
            return false
        }

        return true
    }
}

@Observable
@MainActor
final class TranslationSessionStore {
    private static let maxTranslationCacheEntries = 2_000
    private static let largeTranscriptPresentationCharacterLimit = 4_000
    private static let largeTranscriptPresentationInterval: TimeInterval = 0.35
    private static let largeTranscriptRecognitionDeliveryInterval: TimeInterval = 0.25
    private static let translationCacheHitYieldInterval = 32
    private static let largeTranscriptTranslationCharacterLimit = 4_000
    private static let veryLargeTranscriptTranslationCharacterLimit = 10_000
    private static let defaultTranscriptCheckpointInterval: TimeInterval = 30
    private static let floatingCaptionEarlyRevisionWindow = 0.45
    private static let minimumFloatingCaptionDwell = 1.2
    private static let maximumFloatingCaptionDwell = 2.2
    private static let transcribeOnlyNoticeDisplayDuration: TimeInterval = 10
    private static let appleAutoDetectionMinimumConfidence = 0.35
    private static let appleAutoDetectionLanguageSwitchMinimumConfidence = 0.72
    private static let isAppleSourceAutoDetectionTemporarilyDisabled = true

    var isRunning = false
    var isStarting = false
    var isPaused = false
    var isDubbingEnabled = false {
        didSet {
            if !isApplyingVoiceOutputDefault {
                rememberVoiceOutputPreference(isDubbingEnabled)
            }
            persistSelectedSettings()
            if isDubbingEnabled {
                if isUsingProviderRealtimeTranslation {
                    openAIRealtimeAudioOutput.stop()
                } else {
                    primeDubbingBaselineToCurrentTranslation()
                }
            } else {
                stopSpeaking()
                dubbingSpeechProgress.reset()
            }
        }
    }
    var translatedVoiceVolume = 1.0 {
        didSet {
            let clampedVolume = Self.clampedVolume(translatedVoiceVolume)
            guard translatedVoiceVolume == clampedVolume else {
                translatedVoiceVolume = clampedVolume
                return
            }

            persistSelectedSettings()
            applyTranslatedVoiceVolume()
        }
    }
    var sourceLanguage = LanguageOption.supported[0] {
        didSet {
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
            syncLiveOutputModeWithLanguagePair()
        }
    }
    var targetLanguage = LanguageOption.supported[1] {
        didSet {
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
            syncLiveOutputModeWithLanguagePair()
        }
    }
    var selectedModel = IntelligenceModel.appleSystem {
        didSet {
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
        }
    }
    var hasOpenAIAPIKey = OpenAIAPIKeyStore.hasAPIKey()
    var hasGeminiAPIKey = GeminiAPIKeyStore.hasAPIKey()
    var requestedSettingsCategoryID: String?
    var openAITranscriptionModel = OpenAIRealtimeTranscriptionModel.off {
        didSet {
            if openAITranscriptionModel.isEnabled {
                isTranscriptLintEnabled = false
                geminiTranslationModel = .off
            }
            persistSelectedSettings()
            resetTranslationCache()
            refreshModelAvailability()
        }
    }
    var openAITranslationModel = OpenAIRealtimeTranslationModel.off {
        didSet {
            if openAITranslationModel.isEnabled {
                guard openAITranslationModel.isSupportedLiveTranslationModel else {
                    openAITranslationModel = .gptRealtimeTranslate
                    return
                }
                isTranscriptLintEnabled = false
                geminiTranslationModel = .off
            }
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
        }
    }
    var geminiTranslationModel = GeminiTranslationModel.off {
        didSet {
            if geminiTranslationModel.isEnabled {
                isTranscriptLintEnabled = false
                selectedModel = .appleSystem
                openAITranscriptionModel = .off
                openAITranslationModel = .off
                restoreFloatingCaptionDisplayModeAfterTranscribeOnly()
            }
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
        }
    }
    var isTranscriptLintEnabled = false {
        didSet { persistSelectedSettings() }
    }
    var floatingCaptionDisplayMode = FloatingCaptionDisplayMode.originalAndTranslation {
        didSet {
            if isTranscribeOnlyMode, floatingCaptionDisplayMode != .original {
                floatingCaptionDisplayMode = .original
                return
            }
            persistSelectedSettings()
        }
    }
    var floatingCaptionTextSize = FloatingCaptionTextSize.medium {
        didSet { persistSelectedSettings() }
    }
    var floatingCaptionLineCount = FloatingCaptionLineCount.three {
        didSet { persistSelectedSettings() }
    }
    var keepsFloatingCaptionAboveOtherWindows = true {
        didSet { persistSelectedSettings() }
    }
    var sentencePanelBackgroundOpacity = 0.78 {
        didSet { persistSelectedSettings() }
    }
    var sentencePanelFontSize = 15.0 {
        didSet { persistSelectedSettings() }
    }
    var paragraphBreakSilenceInterval = 5.0 {
        didSet { persistSelectedSettings() }
    }
    var savedTranscriptContentMode = SavedTranscriptContentMode.original {
        didSet { persistSelectedSettings() }
    }
    var sessionDurationMode = SessionDurationMode.standard {
        didSet { persistSelectedSettings() }
    }
    var isAppleSourceAutoDetectionEnabled = false {
        didSet {
            persistSelectedSettings()
            resetTranslationCache()
            resetDubbingProgress()
            refreshModelAvailability()
        }
    }
    var audioInputSource = AudioInputSource.systemAudio {
        didSet { persistSelectedSettings() }
    }
    var selectedMicrophoneInputDeviceID = MicrophoneInputDevice.systemDefaultID {
        didSet { persistSelectedSettings() }
    }
    var microphoneInputDevices = MicrophoneDeviceCatalog.availableInputDevices()
    var statusMessage = AppText.ready
    var toastMessage: String?
    var toastSequence = 0
    var floatingNoticeText: String?
    var lines: [CaptionLine] = []
    var savedTranscripts: [SavedTranscript] = []
    var selectedSavedTranscriptID: String?
    var savedDraftSourceText = ""
    var savedDraftTranslationText = ""
    var pendingAutoDetectionLanguageChange: AutoDetectionLanguageChangeConfirmation?
    var isFoundationTranscriptCleanupRunning = false
    private(set) var latestAudioLevel: Float?
    var modelAvailabilityByModelID = Dictionary(
        uniqueKeysWithValues: IntelligenceModel.allCases.map {
            ($0.id, ModelAvailability.checking(for: $0))
        }
    )

    private let systemAudioCapture = SystemAudioCapture()
    private let microphoneAudioCapture = MicrophoneAudioCapture()
    @ObservationIgnored private var transcriber = LiveSpeechTranscriber()
    @ObservationIgnored private var openAITranscriber = OpenAIRealtimeTranscriber()
    @ObservationIgnored private var geminiLiveTranslator = GeminiLiveTranslationService()
    @ObservationIgnored nonisolated private let audioSamplePipelineRegistry = AudioSamplePipelineRegistry()
    @ObservationIgnored nonisolated private let openAITerminalTranscriptMailbox =
        OpenAITerminalTranscriptMailbox()
    private let translator = AppleTranslationService()
    private let openAITranslator = OpenAITranslationService()
    private let foundationTranscriptPolisher = FoundationTranscriptPolisher()
    private let speechOutput = TranslatedSpeechOutput()
    private let openAIRealtimeAudioOutput = OpenAIRealtimeAudioOutput()
    private let spellChecker = NSSpellChecker.shared
    private let spellDocumentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private let modelAvailabilityProvider: (LanguageOption, LanguageOption) async -> [String: ModelAvailability]
    private let modelAssetDownloader: (IntelligenceModel, LanguageOption, LanguageOption) async throws -> Void
    private let translationSessionPreparer: (
        @Sendable (LanguageOption, LanguageOption, IntelligenceModel) async throws -> Void
    )?
    private let transcriptsDirectoryOverride: URL?
    private var audioSampleCount = 0
    private var lastRecognizedText = ""
    private var lastRecognizedWasFinal = false
    private var lastRecognitionAt = Date.distantPast
    private var currentLineID: UUID?
    private var lastCaptionPresentationUpdateAt = Date.distantPast
    private var pendingCaptionPresentation: PendingCaptionPresentation?
    private var captionPresentationTask: Task<Void, Never>?
    private var pendingRecognizedCaption: PendingRecognizedCaption?
    private var recognizedCaptionDeliveryTask: Task<Void, Never>?
    private var lastRecognizedCaptionDeliveryAt = Date.distantPast
    private var isLargeTranscriptRecognitionCoalescingActive = false
    private var transcriptCleanupTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationTaskGeneration = 0
    private var translationSessionWarmupTask: Task<Void, Never>?
    private var translationSessionWarmupGeneration: UInt64?
    private var latestTranslationRequest: TranslationRequest?
    private var translationBurstStartedAt = Date.distantPast
    private var committedSourceText = ""
    private var currentPartialText = ""
    private var currentPartialLanguage: LanguageOption?
    private var pendingParagraphBreakBeforePartial = false
    private var floatingCommittedSourceText = ""
    private var floatingCurrentPartialText = ""
    private var pendingFloatingParagraphBreakBeforePartial = false
    private var floatingPresentedSourceText = ""
    private var floatingQueuedSourceText = ""
    private var floatingPresentedAt = Date.distantPast
    private var floatingPresentedUnreadLength = 0
    private var appleAutoDetectionPreferredLanguage: LanguageOption?
    private var floatingDisplayTranslationText = ""
    private var floatingDisplayTranslationSourceText = ""
    private var floatingQueuedTranslationText = ""
    private var floatingQueuedTranslationSourceText = ""
    private var floatingPresentationTask: Task<Void, Never>?
    private var sourceLanguageByLineID: [UUID: LanguageOption] = [:]
    private var pendingTranslationSourceText = ""
    private var translationSegmentCache = TranslationSegmentCache(
        capacity: TranslationSessionStore.maxTranslationCacheEntries
    )
    private var realtimeTranslationSourceText = ""
    private var realtimeTranslationOnlyText = ""
    private var geminiLiveInputTranscriptText = ""
    private var geminiLiveOutputTranscriptText = ""
    private var activeAutosaveSourceText = ""
    private var activeAutosaveTranslatedText = ""
    private var activeAutosaveBaseFileName: String?
    private var transcriptCheckpointTask: Task<Void, Never>?
    private let transcriptCheckpointInterval: TimeInterval
    private var isRestoringSelectedSettings = false
    private var isUpdatingLanguagePair = false
    private var modelAvailabilityTask: Task<Void, Never>?
    private var autoStartAfterModelAssetDownloadTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var transcribeOnlyNoticeDismissTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    private var activeCaptureStartGeneration: UInt64?
#if DEBUG
    private var permissionSuspendedStartContinuations: [UInt64: CheckedContinuation<Void, Never>] = [:]
#endif
    private var captureStopTask: Task<Void, Never>?
    private var pipelineLifecycle = PipelineLifecycleState()
    private var activeCaptionerGeneration: UInt64?
    private var dubbingSpeechProgress = DubbingSpeechProgress()
    private var hasShownTranscribeOnlyNoticeForCurrentActivation = false
    private var floatingCaptionDisplayModeBeforeTranscribeOnly: FloatingCaptionDisplayMode?
    private var appleVoiceOutputEnabled = false
    private var providerVoiceOutputEnabled = true
    private var isApplyingVoiceOutputDefault = false

    private enum SavedTranscriptPart {
        case original
        case translation
    }

    private var usesLongSessionMode: Bool {
        sessionDurationMode == .thirtyMinutesOrMore
    }

    var shouldCoalesceTranscriptAutoScroll: Bool {
        isRunning || usesLongSessionMode
    }

    var isUsingOpenAIRealtime: Bool {
        openAITranscriptionModel.isEnabled || openAITranslationModel.isSupportedLiveTranslationModel
    }

    var isUsingGPTTranscriptionMode: Bool {
        openAITranscriptionModel == .gptLiveTranscribe
    }

    var isUsingOpenAIRealtimeTranslation: Bool {
        openAITranslationModel.usesRealtimeAudioTranslation
    }

    var isUsingGeminiTranslation: Bool {
        geminiTranslationModel.isEnabled
    }

    var isUsingProviderRealtimeTranslation: Bool {
        isUsingOpenAIRealtimeTranslation || isUsingGeminiTranslation
    }

    var isTranscribeOnlyMode: Bool {
        selectedModel == .appleSpeechOnly || isUsingGPTTranscriptionMode
    }

    var liveOutputMode: LiveOutputMode {
        isTranscribeOnlyMode ? .transcription : .translation
    }

    private struct SavedTranscriptFile {
        let fileName: String
        let previewText: String
        let updatedAt: Date
    }

    private struct PartialSavedTranscript {
        var original: SavedTranscriptFile?
        var translation: SavedTranscriptFile?
    }

    init(
        modelAvailabilityProvider: @escaping (LanguageOption, LanguageOption) async -> [String: ModelAvailability] = { source, target in
            await ModelAvailabilityChecker.availability(source: source, target: target)
        },
        modelAssetDownloader: @escaping (IntelligenceModel, LanguageOption, LanguageOption) async throws -> Void = { model, source, target in
            try await ModelAvailabilityChecker.downloadAssets(for: model, source: source, target: target)
        },
        translationSessionPreparer: (
            @Sendable (LanguageOption, LanguageOption, IntelligenceModel) async throws -> Void
        )? = nil,
        transcriptsDirectoryURL: URL? = nil,
        transcriptCheckpointInterval: TimeInterval = TranslationSessionStore.defaultTranscriptCheckpointInterval
    ) {
        self.modelAvailabilityProvider = modelAvailabilityProvider
        self.modelAssetDownloader = modelAssetDownloader
        self.translationSessionPreparer = translationSessionPreparer
        self.transcriptsDirectoryOverride = transcriptsDirectoryURL
        self.transcriptCheckpointInterval = transcriptCheckpointInterval
        restoreSelectedSettings()
        applyTranslatedVoiceVolume()
        syncLiveOutputModeWithLanguagePair()
        systemAudioCapture.delegate = self
        microphoneAudioCapture.delegate = self
        transcriber.delegate = self
        openAITranscriber.delegate = self
        configureOpenAITerminalTranscriptDelivery(for: openAITranscriber)
        geminiLiveTranslator.delegate = self
        loadSavedTranscripts()
        loadProductHuntScreenshotDemoIfRequested()
        refreshModelAvailability()
    }

    private func loadProductHuntScreenshotDemoIfRequested() {
        guard ProcessInfo.processInfo.environment["AIRTRANSLATE_PRODUCT_HUNT_SCREENSHOTS"] == "1" else {
            return
        }

        let now = Date()
        hasOpenAIAPIKey = false
        lines = [
            CaptionLine(
                sourceText: "The speaker is explaining how the product roadmap changes when customers need live translation during meetings.",
                translatedText: "The speaker is explaining how the product roadmap changes when customers need live translation during meetings.",
                translatedSourceText: "The speaker is explaining how the product roadmap changes when customers need live translation during meetings.",
                createdAt: now.addingTimeInterval(-12),
                isFinal: true
            ),
            CaptionLine(
                sourceText: "AirTranslate keeps captions visible while you watch a lecture, interview, stream, or video on your Mac.",
                translatedText: "AirTranslate keeps captions visible while you watch a lecture, interview, stream, or video on your Mac.",
                translatedSourceText: "AirTranslate keeps captions visible while you watch a lecture, interview, stream, or video on your Mac.",
                createdAt: now,
                isFinal: true
            ),
        ]

        let demoTranscript = SavedTranscript(
            id: "product-hunt-demo",
            sourceFileName: "product-hunt-demo_original.txt",
            translationFileName: "product-hunt-demo_translation.txt",
            sourceText: "AirTranslate keeps captions visible while you watch a lecture, interview, stream, or video on your Mac.",
            translatedText: "AirTranslate keeps captions visible while you watch a lecture, interview, stream, or video on your Mac.",
            updatedAt: now
        )
        savedTranscripts = [demoTranscript]
        selectedSavedTranscriptID = demoTranscript.id
        savedDraftSourceText = demoTranscript.sourceText
        savedDraftTranslationText = demoTranscript.translatedText ?? ""
    }

    func start() {
        guard !isRunning, !isStarting else { return }

        let readiness = startReadinessAssessment()
        guard readiness.canStart else {
            if readiness.issue == .localAssetsDownloadRequired,
               let model = requiredLocalModelForStart {
                downloadRequiredModelAssetsThenStart(model)
                return
            }
            statusMessage = statusMessage(for: readiness)
            return
        }

        invalidateCaptureStartAttempt()
        let configuration = currentStartConfiguration()
        let generation = pipelineLifecycle.beginStart(configuration: configuration)
        activeCaptureStartGeneration = generation
        isPaused = false
        setCaptionersPaused(false)
        isStarting = true
        statusMessage = configuration.audioInputSource == .microphone
            ? AppText.checkingMicrophonePermission
            : AppText.checkingScreenPermission

        captureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeCaptureStartAttempt(generation: generation) }
            do {
                if let captureStopTask {
                    await captureStopTask.value
                    self.captureStopTask = nil
                }
                try validatePipelineStart(generation: generation, configuration: configuration)
                if configuration.audioInputSource == .systemAudio {
                    try systemAudioCapture.requestScreenRecordingAccess()
                }
                try validatePipelineStart(generation: generation, configuration: configuration)
                if configuration.isUsingGPTTranscriptionMode {
                    statusMessage = AppText.connectingGPTTranscription
                } else if configuration.geminiTranslationModel.isEnabled {
                    statusMessage = AppText.connectingGeminiLiveTranslation
                } else {
                    statusMessage = AppText.checkingSpeechPermission
                }
                try await startCaptioners(
                    configuration: configuration,
                    generation: generation
                )
                try validatePipelineStart(generation: generation, configuration: configuration)
                audioSamplePipelineRegistry.publish(
                    generation: generation,
                    transcriber: transcriber,
                    openAITranscriber: openAITranscriber,
                    geminiLiveTranslator: geminiLiveTranslator
                )

                statusMessage = AppText.startingCapture(for: configuration.audioInputSource)
                switch configuration.audioInputSource {
                case .systemAudio:
                    try await systemAudioCapture.start(
                        sampleRate: configuration.sampleRate,
                        generation: generation
                    )
                case .microphone:
                    try await microphoneAudioCapture.start(
                        sampleRate: configuration.sampleRate,
                        deviceUniqueID: configuration.microphoneDeviceUniqueID,
                        generation: generation
                    )
                }
                try validatePipelineStart(generation: generation, configuration: configuration)
                let promotion = pipelineLifecycle.markRunning(
                    generation: generation,
                    currentConfiguration: currentStartConfiguration()
                )
                switch promotion {
                case .valid:
                    break
                case .configurationChanged:
                    throw PipelineStartError.configurationChanged
                case .staleGeneration:
                    throw CancellationError()
                }
                resetLiveSessionState(clearsVisibleLines: true)
                isRunning = true
                isStarting = false
                statusMessage = AppText.listeningForSpeech(from: configuration.audioInputSource)
                warmTranslationSession()
            } catch let error as CancellationError {
                await handleCancelledCaptureStart(
                    generation: generation,
                    error: error
                )
            } catch let error as PipelineStartError {
                await handlePipelineStartError(
                    error,
                    generation: generation
                )
            } catch {
                await handleCaptureStartFailure(
                    error,
                    generation: generation,
                    configuration: configuration
                )
            }
        }
    }

    func stop() {
        guard isRunning || isStarting else { return }
        pipelineLifecycle.stop()
        finishPipeline(statusOverride: nil)
    }

    private func finishPipeline(statusOverride: String?) {
        invalidateCaptureStartAttempt()
        cancelTranslationSessionWarmup()
        autoStartAfterModelAssetDownloadTask?.cancel()
        autoStartAfterModelAssetDownloadTask = nil
        transcriptCheckpointTask?.cancel()
        transcriptCheckpointTask = nil
        openAITranscriber.stop()
        flushOpenAITerminalTranscriptMailbox()
        flushPendingRecognizedCaption()
        flushPendingCaptionPresentation()
        let hadTranscriptToSave = !visibleTranscript().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !activeAutosaveSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let didSaveTranscript = flushPendingTranscriptSave()
        resetLiveSessionState(clearsVisibleLines: false)
        isPaused = false
        setCaptionersPaused(false)
        isStarting = false
        isRunning = false
        if let statusOverride {
            statusMessage = statusOverride
        } else if didSaveTranscript {
            statusMessage = AppText.transcriptSavedToast
        } else if !hadTranscriptToSave {
            statusMessage = AppText.stopped
        }
        stopCaptioners(openAITranscriberAlreadyStopped: true)
        if didSaveTranscript {
            showToast(AppText.transcriptSavedToast)
        }

        let previousStopTask = captureStopTask
        captureStopTask = Task { @MainActor in
            if let previousStopTask {
                await previousStopTask.value
            }
            await stopCapture()
        }
    }

    private func invalidateCaptureStartAttempt() {
        activeCaptureStartGeneration = nil
        captureStartTask?.cancel()
        captureStartTask = nil
    }

    private func completeCaptureStartAttempt(generation: UInt64) {
        guard activeCaptureStartGeneration == generation else { return }
        activeCaptureStartGeneration = nil
        captureStartTask = nil
        if !isRunning {
            isStarting = false
        }
    }

    private func handleCancelledCaptureStart(
        generation: UInt64,
        error: Error
    ) async {
        guard pipelineLifecycle.fail(generation: generation) else {
            // stop() may have invalidated this task while a permission prompt
            // was suspended. It must not affect a newer generation, but it can
            // still have resumed and initialized the old captioners.
            stopCaptionersIfOwned(by: generation)
            return
        }

        isStarting = false
        isRunning = false
        stopCaptioners()
        await stopCapture()
        statusMessage = AppText.startFailed(error.localizedDescription)
    }

    private func handlePipelineStartError(
        _ error: PipelineStartError,
        generation: UInt64
    ) async {
        if pipelineLifecycle.isActive(generation: generation) {
            _ = pipelineLifecycle.fail(generation: generation)
        }
        guard activeCaptureStartGeneration == generation else {
            stopCaptionersIfOwned(by: generation)
            return
        }

        isStarting = false
        isRunning = false
        stopCaptioners()
        await stopCapture()
        statusMessage = AppText.startFailed(error.localizedDescription)
    }

    private func stopCaptionersIfOwned(by generation: UInt64) {
        guard activeCaptionerGeneration == generation else { return }
        stopCaptioners()
    }

    private func currentStartConfiguration() -> StartConfiguration {
        StartConfiguration(
            audioInputSource: audioInputSource,
            microphoneDeviceUniqueID: selectedMicrophoneDevice.uniqueID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            selectedModel: selectedModel,
            openAITranscriptionModel: openAITranscriptionModel,
            openAITranslationModel: openAITranslationModel,
            geminiTranslationModel: geminiTranslationModel,
            usesAppleSourceAutoDetection: isUsingAppleSourceAutoDetection
        )
    }

    private func validatePipelineStart(
        generation: UInt64,
        configuration: StartConfiguration
    ) throws {
        guard !Task.isCancelled, isStarting else {
            throw CancellationError()
        }

        switch pipelineLifecycle.validateStart(
            generation: generation,
            currentConfiguration: currentStartConfiguration()
        ) {
        case .valid:
            guard configuration == currentStartConfiguration() else {
                throw PipelineStartError.configurationChanged
            }
        case .staleGeneration:
            throw CancellationError()
        case .configurationChanged:
            throw PipelineStartError.configurationChanged
        }
    }

    private func handleFatalPipelineError(
        _ error: Error,
        generation: UInt64? = nil
    ) {
        let didEndLifecycle: Bool
        if let generation {
            didEndLifecycle = pipelineLifecycle.fail(generation: generation)
        } else {
            didEndLifecycle = pipelineLifecycle.failCurrent()
        }
        guard didEndLifecycle, isRunning || isStarting else { return }

        finishPipeline(statusOverride: error.localizedDescription)
    }

    private func handleSystemAudioCaptureStoppedByUser(generation: UInt64) {
        guard pipelineLifecycle.fail(generation: generation),
              isRunning || isStarting
        else {
            return
        }

        finishPipeline(statusOverride: nil)
    }

    private func handleCaptureStartFailure(
        _ error: Error,
        generation: UInt64,
        configuration: StartConfiguration
    ) async {
        if configuration.audioInputSource == .systemAudio,
           SystemAudioCapture.isUserStoppedError(error) {
            handleSystemAudioCaptureStoppedByUser(generation: generation)
            return
        }

        guard pipelineLifecycle.fail(generation: generation) else {
            // A capture/provider callback already ended this generation.
            return
        }
        isStarting = false
        isRunning = false
        stopCaptioners()
        await stopCapture()
        statusMessage = AppText.startFailed(error.localizedDescription)
    }

    func startReadinessAssessment() -> StartReadinessAssessment {
        StartReadinessPolicy.assess(
            requiresOpenAIAPIKey: isUsingOpenAIRealtime,
            hasOpenAIAPIKey: hasOpenAIAPIKey,
            requiresGeminiAPIKey: isUsingGeminiTranslation,
            hasGeminiAPIKey: hasGeminiAPIKey,
            requiredLocalModelAvailability: requiredLocalModelForStart.map { modelAvailability(for: $0) }
        )
    }

    private var requiredLocalModelForStart: IntelligenceModel? {
        if openAITranslationModel.usesRealtimeAudioTranslation {
            return nil
        }
        if openAITranscriptionModel.isEnabled {
            return isTranscribeOnlyMode ? nil : .appleOnDevice
        }
        if isUsingGeminiTranslation {
            return nil
        }
        return selectedModel
    }

    private func statusMessage(for readiness: StartReadinessAssessment) -> String {
        switch readiness.issue {
        case nil:
            return AppText.ready
        case .openAIAPIKeyMissing:
            return AppText.openAIAPIKeyRequiredForGPTMode
        case .geminiAPIKeyMissing:
            return AppText.geminiAPIKeyMissing
        case .localAssetsChecking:
            return AppText.startBlockedLocalAssetsChecking
        case .localAssetsDownloadRequired:
            return AppText.startBlockedLocalAssetsDownloadRequired
        case .localAssetsUnavailable(let detail):
            return AppText.startBlockedLocalAssetsUnavailable(detail)
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }

        flushPendingRecognizedCaption()
        flushPendingCaptionPresentation()
        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = nil
        commitCurrentPartial()
        organizeCurrentTranscript(sourceTextOverride: visibleTranscript())
        _ = checkpointPendingTranscriptSave()
        setCaptionersPaused(true)
        stopSpeaking()
        isPaused = true
        statusMessage = AppText.paused
    }

    func resume() {
        guard isRunning, isPaused else { return }
        pendingAutoDetectionLanguageChange = nil

        setCaptionersPaused(false)
        isPaused = false
        lastRecognitionAt = Date()
        statusMessage = AppText.listeningForSpeech(from: audioInputSource)
    }

    func confirmAutoDetectionLanguageChange() {
        guard let pendingAutoDetectionLanguageChange else { return }

        self.pendingAutoDetectionLanguageChange = nil
        let detectedLanguage = pendingAutoDetectionLanguageChange.detectedLanguage
        let bufferedSourceText = pendingAutoDetectionLanguageChange.sourceText
        let bufferedConfidence = pendingAutoDetectionLanguageChange.confidence
        let didSaveTranscript = flushPendingTranscriptSave()

        resetLiveSessionState(clearsVisibleLines: true)
        appleAutoDetectionPreferredLanguage = detectedLanguage
        setCaptionersPaused(false)
        isPaused = false
        lastRecognitionAt = Date()
        statusMessage = AppText.listeningForSpeech(from: audioInputSource)

        if didSaveTranscript {
            showToast(AppText.transcriptSavedToast)
        }

        Task { @MainActor in
            appendCaption(
                sourceText: bufferedSourceText,
                recognizedLanguage: detectedLanguage,
                confidence: bufferedConfidence,
                isFinal: false
            )
        }
    }

    func keepCurrentAutoDetectionLanguage() {
        guard pendingAutoDetectionLanguageChange != nil else { return }

        pendingAutoDetectionLanguageChange = nil
        setCaptionersPaused(false)
        isPaused = false
        lastRecognitionAt = Date()
        statusMessage = AppText.listeningForSpeech(from: audioInputSource)
    }

    func showAppleSourceAutoDetectionUnavailableNotice() {
        isAppleSourceAutoDetectionEnabled = false
        showToast(AppText.appleAutoLanguageModeUnavailableToast)
    }

    func prepareForTermination() {
        autoStartAfterModelAssetDownloadTask?.cancel()
        cancelTranslationSessionWarmup()
        transcriptCheckpointTask?.cancel()
        transcriptCheckpointTask = nil
        flushPendingRecognizedCaption()
        flushPendingCaptionPresentation()
        _ = flushPendingTranscriptSave()
    }

    func openPrivacySettings() {
        openPrivacySettings(audioInputSource == .microphone ? .microphone : .screenRecording)
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    var selectedMicrophoneDevice: MicrophoneInputDevice {
        microphoneInputDevices.first { $0.id == selectedMicrophoneInputDeviceID }
            ?? .systemDefault
    }

    func refreshMicrophoneInputDevices() {
        microphoneInputDevices = MicrophoneDeviceCatalog.availableInputDevices()
        if !microphoneInputDevices.contains(where: { $0.id == selectedMicrophoneInputDeviceID }) {
            selectedMicrophoneInputDeviceID = MicrophoneInputDevice.systemDefaultID
        }
    }

    func saveOpenAIAPIKey(_ key: String) throws {
        try OpenAIAPIKeyStore.saveAPIKey(key)
        hasOpenAIAPIKey = true
        statusMessage = AppText.openAIAPIKeySaved
        refreshModelAvailability()
    }

    func removeOpenAIAPIKey() throws {
        try OpenAIAPIKeyStore.deleteAPIKey()
        hasOpenAIAPIKey = false
        statusMessage = AppText.openAIAPIKeyRemoved
        refreshModelAvailability()
    }

    func saveGeminiAPIKey(_ key: String) throws {
        try GeminiAPIKeyStore.saveAPIKey(key)
        hasGeminiAPIKey = true
        statusMessage = AppText.geminiAPIKeySaved
        refreshModelAvailability()
    }

    func removeGeminiAPIKey() throws {
        try GeminiAPIKeyStore.deleteAPIKey()
        hasGeminiAPIKey = false
        statusMessage = AppText.geminiAPIKeyRemoved
        refreshModelAvailability()
    }

    func openTranscriptsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(transcriptsDirectoryURL)
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
    }

    var languageSummary: String {
        if isTranscribeOnlyMode {
            return AppText.transcribeLanguageSummary(source: sourceLanguage.localizedTitle)
        }
        if isUsingOpenAIRealtimeTranslation {
            return AppText.openAILanguageSummary(target: targetLanguage.localizedTitle)
        }
        if isUsingAppleSourceAutoDetection {
            return AppText.openAILanguageSummary(target: targetLanguage.localizedTitle)
        }
        return AppText.languageSummary(source: sourceLanguage.localizedTitle, target: targetLanguage.localizedTitle)
    }

    var isUsingAppleSourceAutoDetection: Bool {
        isAppleSourceAutoDetectionAvailable
            && isAppleSourceAutoDetectionEnabled
            && !openAITranscriptionModel.isEnabled
            && !openAITranslationModel.isEnabled
            && !isUsingGeminiTranslation
    }

    var isAppleSourceAutoDetectionAvailable: Bool {
        !Self.isAppleSourceAutoDetectionTemporarilyDisabled
    }

    func usePreferredLanguageForOpenAIOutput() {
        let preferredLanguage = LanguageOption.preferredSystemLanguage(fallback: targetLanguage)
        if targetLanguage != preferredLanguage {
            targetLanguage = preferredLanguage
        }
    }

    func useQuickSourceLanguage(_ language: LanguageOption) {
        guard !isRunning else { return }
        guard !isTranscribeOnlyMode else {
            sourceLanguage = language
            return
        }

        let previousSourceLanguage = sourceLanguage
        let nextTargetLanguage = language == targetLanguage
            ? fallbackTargetLanguage(excluding: language, preferred: previousSourceLanguage)
            : targetLanguage
        updateLanguagePair(source: language, target: nextTargetLanguage)
    }

    func useQuickTargetLanguage(_ language: LanguageOption) {
        guard !isRunning else { return }
        guard !isTranscribeOnlyMode else { return }
        guard language != sourceLanguage else {
            showToast(AppText.sameLanguageTranslationUnavailable)
            return
        }

        updateLanguagePair(source: sourceLanguage, target: language)
    }

    func swapQuickLanguagePair() {
        guard !isRunning, !isTranscribeOnlyMode else { return }

        updateLanguagePair(
            source: targetLanguage,
            target: fallbackTargetLanguage(excluding: targetLanguage, preferred: sourceLanguage)
        )
    }

    func requestAPIKeySettings() {
        requestedSettingsCategoryID = "apiKeys"
    }

    func useAppleDefaultMode() {
        clearTranscribeOnlyNotice(resetActivation: true)
        selectedModel = .appleSystem
        openAITranscriptionModel = .off
        openAITranslationModel = .off
        geminiTranslationModel = .off
        applyAppleVoiceOutputDefault()
    }

    func useGPTRealtimeMode() {
        useGPTRealtimeMode(model: openAITranslationModel.isEnabled ? openAITranslationModel : .gptRealtimeTranslate)
    }

    func useGPTRealtimeMode(model: OpenAIRealtimeTranslationModel) {
        let selectedOpenAIModel = model.isSupportedLiveTranslationModel ? model : .gptRealtimeTranslate
        clearTranscribeOnlyNotice(resetActivation: true)
        selectedModel = .appleSystem
        geminiTranslationModel = .off
        openAITranscriptionModel = .off
        isTranscriptLintEnabled = false
        if openAITranslationModel != selectedOpenAIModel {
            openAITranslationModel = selectedOpenAIModel
        }
        applyProviderVoiceOutputDefault()
        restoreFloatingCaptionDisplayModeAfterTranscribeOnly()
        usePreferredLanguageForOpenAIOutput()
    }

    func useGPTTranscriptionMode() {
        if floatingCaptionDisplayModeBeforeTranscribeOnly == nil {
            floatingCaptionDisplayModeBeforeTranscribeOnly = floatingCaptionDisplayMode
        }
        selectedModel = .appleSpeechOnly
        geminiTranslationModel = .off
        openAITranslationModel = .off
        if openAITranscriptionModel != .gptLiveTranscribe {
            openAITranscriptionModel = .gptLiveTranscribe
        }
        isTranscriptLintEnabled = false
        floatingCaptionDisplayMode = .original
        isDubbingEnabled = false
        clearTranscribeOnlyNotice(resetActivation: true)
    }

    func useGeminiTranslationMode() {
        clearTranscribeOnlyNotice(resetActivation: true)
        selectedModel = .appleSystem
        openAITranscriptionModel = .off
        openAITranslationModel = .off
        if !geminiTranslationModel.isEnabled {
            geminiTranslationModel = .gemini35LiveTranslate
        }
        applyProviderVoiceOutputDefault()
        restoreFloatingCaptionDisplayModeAfterTranscribeOnly()
    }

    func useLiveOutputMode(_ mode: LiveOutputMode) {
        switch mode {
        case .translation:
            useTranslationMode()
        case .transcription:
            useTranscribeOnlyMode()
        }
    }

    func useTranslationMode() {
        clearTranscribeOnlyNotice(resetActivation: true)
        if isTranscribeOnlyMode {
            selectedModel = .appleSystem
        }
        if openAITranscriptionModel.isEnabled || openAITranslationModel.isEnabled {
            openAITranscriptionModel = .off
            if !openAITranslationModel.isEnabled {
                openAITranslationModel = .gptRealtimeTranslate
            }
            applyProviderVoiceOutputDefault()
        }
        restoreFloatingCaptionDisplayModeAfterTranscribeOnly()
    }

    func useTranscribeOnlyMode() {
        if floatingCaptionDisplayModeBeforeTranscribeOnly == nil {
            floatingCaptionDisplayModeBeforeTranscribeOnly = floatingCaptionDisplayMode
        }
        floatingCaptionDisplayMode = .original
        if openAITranslationModel.isEnabled {
            openAITranslationModel = .off
        }
        if openAITranscriptionModel.isEnabled {
            openAITranscriptionModel = .off
        }
        if geminiTranslationModel.isEnabled {
            geminiTranslationModel = .off
        }
        isDubbingEnabled = false
        selectedModel = .appleSpeechOnly
        clearTranscribeOnlyNotice(resetActivation: true)
    }

    private func syncLiveOutputModeWithLanguagePair() {
        guard !isRestoringSelectedSettings, !isUpdatingLanguagePair, !isRunning else { return }

        if selectedModel == .appleSpeechOnly {
            if targetLanguage != sourceLanguage {
                targetLanguage = sourceLanguage
            }
            return
        }

        guard !isUsingProviderRealtimeTranslation else { return }

        if sourceLanguage == targetLanguage {
            useTranscribeOnlyMode()
            return
        }
    }

    private func updateLanguagePair(source: LanguageOption, target: LanguageOption) {
        isUpdatingLanguagePair = true
        sourceLanguage = source
        targetLanguage = target
        isUpdatingLanguagePair = false
        syncLiveOutputModeWithLanguagePair()
    }

    private func fallbackTargetLanguage(excluding excludedLanguage: LanguageOption, preferred: LanguageOption) -> LanguageOption {
        if preferred != excludedLanguage {
            return preferred
        }
        return LanguageOption.supported.first { $0 != excludedLanguage } ?? preferred
    }

    private func applyAppleVoiceOutputDefault() {
        appleVoiceOutputEnabled = false
        applyVoiceOutputDefault(false)
    }

    private func applyProviderVoiceOutputDefault() {
        providerVoiceOutputEnabled = true
        applyVoiceOutputDefault(true)
    }

    private func applyRestoredVoiceOutputPreference() {
        applyVoiceOutputDefault(isUsingProviderRealtimeTranslation ? providerVoiceOutputEnabled : appleVoiceOutputEnabled)
    }

    private func applyVoiceOutputDefault(_ isEnabled: Bool) {
        isApplyingVoiceOutputDefault = true
        isDubbingEnabled = isEnabled
        isApplyingVoiceOutputDefault = false
    }

    private func rememberVoiceOutputPreference(_ isEnabled: Bool) {
        if isUsingProviderRealtimeTranslation {
            providerVoiceOutputEnabled = isEnabled
        } else if !isTranscribeOnlyMode {
            appleVoiceOutputEnabled = isEnabled
        }
    }

    private func restoreFloatingCaptionDisplayModeAfterTranscribeOnly() {
        guard let previousMode = floatingCaptionDisplayModeBeforeTranscribeOnly else { return }

        floatingCaptionDisplayModeBeforeTranscribeOnly = nil
        floatingCaptionDisplayMode = previousMode
    }

    private func showTranscribeOnlyNoticeForCurrentActivation() {
        guard isTranscribeOnlyMode,
              !hasShownTranscribeOnlyNoticeForCurrentActivation
        else {
            return
        }

        hasShownTranscribeOnlyNoticeForCurrentActivation = true
        floatingNoticeText = AppText.translationDisabledForSpeechOnly
        statusMessage = AppText.translationDisabledForSpeechOnly
        transcribeOnlyNoticeDismissTask?.cancel()

        transcribeOnlyNoticeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.transcribeOnlyNoticeDisplayDuration * 1_000)))
            guard !Task.isCancelled else { return }

            if floatingNoticeText == AppText.translationDisabledForSpeechOnly {
                floatingNoticeText = nil
            }
            if statusMessage == AppText.translationDisabledForSpeechOnly {
                statusMessage = isRunning ? AppText.listeningForSpeech(from: audioInputSource) : AppText.ready
            }
            transcribeOnlyNoticeDismissTask = nil
        }
    }

    private func clearTranscribeOnlyNotice(resetActivation: Bool) {
        transcribeOnlyNoticeDismissTask?.cancel()
        transcribeOnlyNoticeDismissTask = nil
        if floatingNoticeText == AppText.translationDisabledForSpeechOnly {
            floatingNoticeText = nil
        }
        if resetActivation {
            hasShownTranscribeOnlyNoticeForCurrentActivation = false
        }
    }

    func modelAvailability(for model: IntelligenceModel) -> ModelAvailability {
        modelAvailabilityByModelID[model.id] ?? ModelAvailability.checking(for: model)
    }

    func downloadModelAssets(for model: IntelligenceModel) {
        guard modelAvailability(for: model).state.canDownload else { return }

        let sourceLanguage = sourceLanguage
        let targetLanguage = targetLanguage
        modelAvailabilityByModelID[model.id] = ModelAvailability(
            state: .downloading,
            detail: model.detail
        )

        Task { @MainActor in
            do {
                try await modelAssetDownloader(model, sourceLanguage, targetLanguage)
                refreshModelAvailability()
            } catch {
                modelAvailabilityByModelID[model.id] = ModelAvailability(
                    state: .failed,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func downloadRequiredModelAssetsThenStart(_ model: IntelligenceModel) {
        guard modelAvailability(for: model).state.canDownload else {
            statusMessage = statusMessage(for: startReadinessAssessment())
            return
        }

        let sourceLanguage = sourceLanguage
        let targetLanguage = targetLanguage
        isPaused = false
        setCaptionersPaused(false)
        isStarting = true
        statusMessage = "\(AppText.modelStatusDownloading): \(model.title)"
        modelAvailabilityByModelID[model.id] = ModelAvailability(
            state: .downloading,
            detail: model.detail
        )

        autoStartAfterModelAssetDownloadTask?.cancel()
        autoStartAfterModelAssetDownloadTask = Task { [weak self, model, sourceLanguage, targetLanguage] in
            do {
                try await self?.modelAssetDownloader(model, sourceLanguage, targetLanguage)
                guard !Task.isCancelled else { return }
                let availabilityByModelID = await self?.modelAvailabilityProvider(sourceLanguage, targetLanguage) ?? [:]
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self else { return }
                    self.modelAvailabilityByModelID = availabilityByModelID
                    guard self.isStarting else { return }

                    guard sourceLanguage == self.sourceLanguage,
                          targetLanguage == self.targetLanguage,
                          model == self.requiredLocalModelForStart
                    else {
                        self.isStarting = false
                        self.statusMessage = AppText.ready
                        self.refreshModelAvailability()
                        return
                    }

                    let readiness = self.startReadinessAssessment()
                    guard readiness.canStart else {
                        self.isStarting = false
                        self.statusMessage = self.statusMessage(for: readiness)
                        return
                    }

                    self.isStarting = false
                    self.autoStartAfterModelAssetDownloadTask = nil
                    self.start()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isStarting = false
                    self.autoStartAfterModelAssetDownloadTask = nil
                    self.modelAvailabilityByModelID[model.id] = ModelAvailability(
                        state: .failed,
                        detail: error.localizedDescription
                    )
                    self.statusMessage = AppText.startFailed(error.localizedDescription)
                }
            }
        }
    }

    var floatingSourceText: String {
        let displayText = floatingPresentedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayText.isEmpty {
            return floatingCaptionText(from: displayText)
        }

        let liveDisplayText = floatingVisibleSourceTranscript()
        if !liveDisplayText.isEmpty {
            return floatingCaptionText(from: liveDisplayText)
        }

        return floatingCaptionText(from: lines.last?.sourceText)
    }

    var floatingTranslationText: String {
        let displaySourceText = floatingPresentedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displaySourceText.isEmpty {
            let translatedText = floatingDisplayTranslationText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translatedText.isEmpty, translatedText != AppText.translating else {
                return ""
            }
            guard floatingDisplayTranslationSourceText.isEmpty
                || translationSource(floatingDisplayTranslationSourceText, matches: displaySourceText)
            else {
                return ""
            }

            return floatingCaptionText(from: translatedText)
        }

        guard let lineTranslatedText = lines.last?.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
              lineTranslatedText != AppText.translating
        else {
            return ""
        }

        return floatingCaptionText(from: lineTranslatedText)
    }

    var hasFloatingCaptionContent: Bool {
        !floatingSourceText.isEmpty || !floatingTranslationText.isEmpty
    }

    var hasTranscriptContent: Bool {
        !lines.isEmpty
    }

    var shouldShowTranscript: Bool {
        isRunning || !lines.isEmpty
    }

    var shouldShowTranslationPane: Bool {
        !isTranscribeOnlyMode
    }

    var availableFloatingCaptionDisplayModes: [FloatingCaptionDisplayMode] {
        isTranscribeOnlyMode ? [.original] : FloatingCaptionDisplayMode.allCases
    }

    var selectedSavedTranscript: SavedTranscript? {
        guard let selectedSavedTranscriptID else { return nil }
        return savedTranscripts.first { $0.id == selectedSavedTranscriptID }
    }

    func selectSavedTranscript(_ id: String) {
        guard let transcript = savedTranscripts.first(where: { $0.id == id }) else { return }

        selectedSavedTranscriptID = id
        savedDraftSourceText = loadTranscriptText(fileName: transcript.sourceFileName) ?? transcript.sourceText
        if let translationFileName = transcript.translationFileName,
           let translatedText = loadTranscriptText(fileName: translationFileName) {
            savedDraftTranslationText = translatedText
        } else {
            savedDraftTranslationText = transcript.translatedText ?? ""
        }
    }

    func saveSelectedTranscriptEdits() {
        guard let selectedTranscript = selectedSavedTranscript else { return }

        let sourceText = savedDraftSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        if selectedTranscript.isOriginalAndTranslation,
           let translationFileName = selectedTranscript.translationFileName {
            let translatedText = savedDraftTranslationText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard writeTranscriptText(sourceText, fileName: selectedTranscript.sourceFileName),
                  writeTranscriptText(translatedText, fileName: translationFileName)
            else {
                return
            }
        } else {
            guard writeTranscriptText(sourceText, fileName: selectedTranscript.sourceFileName) else { return }
        }

        let selectedID = selectedTranscript.id
        loadSavedTranscripts()
        selectSavedTranscript(selectedID)
    }

    func polishSelectedTranscriptDraftWithFoundationModel() {
        guard !isFoundationTranscriptCleanupRunning,
              let selectedTranscript = selectedSavedTranscript
        else {
            return
        }

        let selectedID = selectedTranscript.id
        let sourceText = savedDraftSourceText
        let translationText = savedDraftTranslationText
        let shouldPolishTranslation = selectedTranscript.isOriginalAndTranslation
            && translationText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
        guard sourceText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            || shouldPolishTranslation
        else {
            return
        }

        isFoundationTranscriptCleanupRunning = true
        statusMessage = AppText.foundationModelCleanupRunning

        Task { @MainActor in
            do {
                let cleanedSource = try await foundationTranscriptPolisher.polishTranscript(sourceText)
                let cleanedTranslation = shouldPolishTranslation
                    ? try await foundationTranscriptPolisher.polishTranscript(translationText)
                    : ""

                if selectedSavedTranscriptID == selectedID {
                    if !cleanedSource.isEmpty {
                        savedDraftSourceText = cleanedSource
                    }
                    if shouldPolishTranslation {
                        savedDraftTranslationText = cleanedTranslation
                    }
                    statusMessage = AppText.foundationModelCleanupComplete
                }
            } catch {
                statusMessage = AppText.foundationModelCleanupFailed(error.localizedDescription)
            }

            isFoundationTranscriptCleanupRunning = false
        }
    }

    func deleteSelectedTranscript() {
        guard let selectedTranscript = selectedSavedTranscript else { return }

        savedTranscripts.removeAll { $0.id == selectedTranscript.id }
        try? FileManager.default.removeItem(at: transcriptURL(fileName: selectedTranscript.sourceFileName))
        if let translationFileName = selectedTranscript.translationFileName {
            try? FileManager.default.removeItem(at: transcriptURL(fileName: translationFileName))
        }
        self.selectedSavedTranscriptID = nil
        savedDraftSourceText = ""
        savedDraftTranslationText = ""
    }

    func deleteAllSavedTranscripts() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: transcriptsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for fileURL in fileURLs where fileURL.pathExtension == "txt" {
                try FileManager.default.removeItem(at: fileURL)
            }
            savedTranscripts.removeAll()
            selectedSavedTranscriptID = nil
            savedDraftSourceText = ""
            savedDraftTranslationText = ""
            activeAutosaveSourceText = ""
            activeAutosaveTranslatedText = ""
            activeAutosaveBaseFileName = nil
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
        }
    }

    private func startCaptioners(
        configuration: StartConfiguration,
        generation: UInt64
    ) async throws {
        if usesAppleSpeechTranscriber(for: configuration) {
            try await startAppleSpeechTranscriber(
                configuration: configuration,
                generation: generation
            )
            return
        }

        stopCaptioners()
        transcriber = LiveSpeechTranscriber()
        transcriber.delegate = self
        openAITranscriber = OpenAIRealtimeTranscriber()
        openAITranscriber.delegate = self
        configureOpenAITerminalTranscriptDelivery(for: openAITranscriber)
        openAITranscriber.onAudioTransportDegraded = { [weak self, weak openAITranscriber] degradation in
            Task { @MainActor in
                guard let self,
                      let openAITranscriber,
                      openAITranscriber === self.openAITranscriber
                else {
                    return
                }
                self.handleFatalPipelineError(
                    RealtimeAudioTransportError(degradation: degradation),
                    generation: generation
                )
            }
        }
        geminiLiveTranslator = GeminiLiveTranslationService()
        geminiLiveTranslator.delegate = self
        geminiLiveTranslator.onAudioTransportDegraded = { [weak self, weak geminiLiveTranslator] degradation in
            Task { @MainActor in
                guard let self,
                      let geminiLiveTranslator,
                      geminiLiveTranslator === self.geminiLiveTranslator
                else {
                    return
                }
                self.handleFatalPipelineError(
                    RealtimeAudioTransportError(degradation: degradation),
                    generation: generation
                )
            }
        }
        activeCaptionerGeneration = generation

        if configuration.isTranscribeOnlyMode, configuration.openAITranscriptionModel.isEnabled {
            try await openAITranscriber.start(
                language: configuration.sourceLanguage,
                model: configuration.openAITranscriptionModel
            )
        } else if configuration.geminiTranslationModel.isEnabled {
            try await geminiLiveTranslator.start(
                targetLanguage: configuration.targetLanguage,
                model: configuration.geminiTranslationModel
            )
        } else if configuration.openAITranslationModel.usesRealtimeAudioTranslation {
            try await openAITranscriber.startRealtimeTranslationOnly(
                language: configuration.targetLanguage,
                model: configuration.openAITranslationModel
            )
        } else if configuration.openAITranscriptionModel.isEnabled {
            try await openAITranscriber.start(
                language: configuration.sourceLanguage,
                model: configuration.openAITranscriptionModel
            )
        }
    }

    private func usesAppleSpeechTranscriber(for configuration: StartConfiguration) -> Bool {
        !configuration.openAITranscriptionModel.isEnabled
            && !configuration.geminiTranslationModel.isEnabled
            && !configuration.openAITranslationModel.usesRealtimeAudioTranslation
    }

    private func startAppleSpeechTranscriber(
        configuration: StartConfiguration,
        generation: UInt64
    ) async throws {
        // Keep this candidate entirely local until all cancellation and
        // generation checks pass. A non-cooperative speech-permission callback
        // from an older start must never replace or stop a newer pipeline.
        let candidate = LiveSpeechTranscriber()
        candidate.delegate = self
        do {
            // stopCaptioners() intentionally returns synchronously so Stop
            // never blocks MainActor. Before a replacement can reserve Speech
            // assets, suspend until the old analyzer has cancelled and all of
            // its locales have been released.
            await transcriber.stopAndWaitForCleanup()
            try Task.checkCancellation()
            try validatePipelineStart(generation: generation, configuration: configuration)

            let languages = await appleSpeechLanguages(for: configuration)
            try Task.checkCancellation()
            try await candidate.start(languages: languages)
            try validatePipelineStart(generation: generation, configuration: configuration)

            stopCaptioners()
            transcriber = candidate
            transcriber.delegate = self
            activeCaptionerGeneration = generation
        } catch {
            candidate.delegate = nil
            candidate.stop()
            throw error
        }
    }

    private func appleSpeechLanguages(for configuration: StartConfiguration) async -> [LanguageOption] {
        guard configuration.usesAppleSourceAutoDetection else {
            return [configuration.sourceLanguage]
        }

        let candidates = LanguageOption.prioritizedAutoDetectionCandidates(
            sourceLanguage: configuration.sourceLanguage,
            targetLanguage: configuration.targetLanguage
        )
        let installedCandidates = await LiveSpeechTranscriber.installedSupportedLanguages(from: candidates)
        let selectedCandidates = installedCandidates.isEmpty
            ? [candidates.first ?? configuration.sourceLanguage]
            : installedCandidates
        appleAutoDetectionPreferredLanguage = selectedCandidates.first
        return selectedCandidates
    }

    func prioritizedAutoDetectionLanguages() -> [LanguageOption] {
        LanguageOption.prioritizedAutoDetectionCandidates(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func stopCaptioners(openAITranscriberAlreadyStopped: Bool = false) {
        audioSamplePipelineRegistry.clear()
        activeCaptionerGeneration = nil
        openAITranscriber.onAudioTransportDegraded = nil
        geminiLiveTranslator.onAudioTransportDegraded = nil
        transcriber.delegate = nil
        openAITranscriber.delegate = nil
        geminiLiveTranslator.delegate = nil
        transcriber.stop()
        if !openAITranscriberAlreadyStopped {
            openAITranscriber.stop()
        }
        geminiLiveTranslator.stop()
    }

    private func flushOpenAITerminalTranscriptMailbox() {
        openAITerminalTranscriptMailbox.drain().forEach { transcript in
            guard transcript.transcriber === openAITranscriber,
                  isRunning || isStarting
            else {
                return
            }
            enqueueRecognizedCaption(
                sourceText: transcript.text,
                recognizedLanguage: transcript.language,
                confidence: transcript.confidence
            )
        }
    }

    private func configureOpenAITerminalTranscriptDelivery(
        for transcriber: OpenAIRealtimeTranscriber
    ) {
        let terminalTranscriptMailbox = openAITerminalTranscriptMailbox
        transcriber.onTerminalTranscriptReady = { [weak self, weak transcriber] text, language, confidence in
            guard let transcriber else { return }
            terminalTranscriptMailbox.append(
                OpenAITerminalTranscript(
                    text: text,
                    language: language,
                    confidence: confidence,
                    transcriber: transcriber
                )
            )
            Task { @MainActor [weak self] in
                self?.flushOpenAITerminalTranscriptMailbox()
            }
        }
    }

    private func setCaptionersPaused(_ isPaused: Bool) {
        transcriber.setPaused(isPaused)
        openAITranscriber.setPaused(isPaused)
        geminiLiveTranslator.setPaused(isPaused)
    }

    private func resetLiveSessionState(clearsVisibleLines: Bool) {
        audioSampleCount = 0
        latestAudioLevel = nil
        lastRecognizedText = ""
        lastRecognizedWasFinal = false
        currentLineID = nil
        lastCaptionPresentationUpdateAt = Date.distantPast
        pendingCaptionPresentation = nil
        captionPresentationTask?.cancel()
        captionPresentationTask = nil
        pendingRecognizedCaption = nil
        recognizedCaptionDeliveryTask?.cancel()
        recognizedCaptionDeliveryTask = nil
        lastRecognizedCaptionDeliveryAt = Date.distantPast
        isLargeTranscriptRecognitionCoalescingActive = false
        committedSourceText = ""
        currentPartialText = ""
        currentPartialLanguage = nil
        appleAutoDetectionPreferredLanguage = nil
        pendingAutoDetectionLanguageChange = nil
        pendingParagraphBreakBeforePartial = false
        floatingPresentationTask?.cancel()
        floatingPresentationTask = nil
        if clearsVisibleLines {
            sourceLanguageByLineID.removeAll()
            floatingCommittedSourceText = ""
            floatingCurrentPartialText = ""
            pendingFloatingParagraphBreakBeforePartial = false
            floatingPresentedSourceText = ""
            floatingQueuedSourceText = ""
            floatingPresentedAt = Date.distantPast
            floatingPresentedUnreadLength = 0
            floatingDisplayTranslationText = ""
            floatingDisplayTranslationSourceText = ""
            floatingQueuedTranslationText = ""
            floatingQueuedTranslationSourceText = ""
        } else {
            rehydrateFloatingCaptionDisplayFromCurrentLine()
        }
        pendingTranslationSourceText = ""
        latestTranslationRequest = nil
        translationBurstStartedAt = Date.distantPast
        if !clearsVisibleLines {
            clearPendingTranslationPlaceholders(message: AppText.translationCancelled)
        }
        resetTranslationCache()
        realtimeTranslationSourceText = ""
        realtimeTranslationOnlyText = ""
        geminiLiveInputTranscriptText = ""
        geminiLiveOutputTranscriptText = ""
        activeAutosaveSourceText = ""
        activeAutosaveTranslatedText = ""
        activeAutosaveBaseFileName = nil
        transcriptCheckpointTask?.cancel()
        transcriptCheckpointTask = nil
        stopSpeaking()
        dubbingSpeechProgress.reset()
        translationTask?.cancel()
        translationTask = nil
        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = nil
        clearTranscribeOnlyNotice(resetActivation: clearsVisibleLines)

        if clearsVisibleLines {
            lines.removeAll()
        }
    }

    private func clearPendingTranslationPlaceholders(message: String) {
        for index in lines.indices where lines[index].translatedText == AppText.translating {
            let line = lines[index]
            lines[index] = CaptionLine(
                id: line.id,
                sourceText: line.sourceText,
                translatedText: message,
                translatedSourceText: line.sourceText,
                translationsBySentence: line.translationsBySentence,
                createdAt: line.createdAt,
                isFinal: line.isFinal,
                revision: line.revision + 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
        }

        if floatingDisplayTranslationText == AppText.translating {
            floatingDisplayTranslationText = message
        }
        if floatingQueuedTranslationText == AppText.translating {
            floatingQueuedTranslationText = message
        }
    }

    private func warmTranslationSession() {
        cancelTranslationSessionWarmup()
        guard !openAITranslationModel.isEnabled, !geminiTranslationModel.isEnabled else { return }

        let warmSourceLanguage = sourceLanguage
        let warmTargetLanguage = targetLanguage
        let warmSelectedModel = selectedModel
        let warmGeneration = pipelineLifecycle.generation
        let warmConfiguration = currentStartConfiguration()

        translationSessionWarmupGeneration = warmGeneration
        translationSessionWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let translationSessionPreparer {
                    try await translationSessionPreparer(
                        warmSourceLanguage,
                        warmTargetLanguage,
                        warmSelectedModel
                    )
                } else {
                    try await translator.prepare(
                        source: warmSourceLanguage,
                        target: warmTargetLanguage,
                        model: warmSelectedModel
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      translationSessionWarmupGeneration == warmGeneration,
                      pipelineLifecycle.acceptsSample(generation: warmGeneration),
                      currentStartConfiguration() == warmConfiguration
                else {
                    return
                }
                statusMessage = error.localizedDescription
            }

            if translationSessionWarmupGeneration == warmGeneration {
                translationSessionWarmupTask = nil
                translationSessionWarmupGeneration = nil
            }
        }
    }

    private func cancelTranslationSessionWarmup() {
        translationSessionWarmupTask?.cancel()
        translationSessionWarmupTask = nil
        translationSessionWarmupGeneration = nil
    }

    func refreshModelAvailability() {
        let sourceLanguage = sourceLanguage
        let targetLanguage = targetLanguage

        modelAvailabilityTask?.cancel()
        modelAvailabilityByModelID = Dictionary(
            uniqueKeysWithValues: IntelligenceModel.allCases.map {
                ($0.id, ModelAvailability.checking(for: $0))
            }
        )

        modelAvailabilityTask = Task { [weak self, sourceLanguage, targetLanguage] in
            let availabilityByModelID = await self?.modelAvailabilityProvider(sourceLanguage, targetLanguage) ?? [:]
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.modelAvailabilityByModelID = availabilityByModelID
            }
        }
    }

    private func restoreSelectedSettings() {
        isRestoringSelectedSettings = true
        defer { isRestoringSelectedSettings = false }

        let defaults = UserDefaults.standard
        if let sourceLanguageID = defaults.string(forKey: SettingsKey.sourceLanguageID),
           let language = LanguageOption.supported.first(where: { $0.id == sourceLanguageID }) {
            sourceLanguage = language
        }
        if let targetLanguageID = defaults.string(forKey: SettingsKey.targetLanguageID),
           let language = LanguageOption.supported.first(where: { $0.id == targetLanguageID }) {
            targetLanguage = language
        }
        if let modelID = defaults.string(forKey: SettingsKey.selectedModelID),
           let model = IntelligenceModel(rawValue: modelID) {
            selectedModel = model == .appleOnDevice ? .appleSystem : model
        }
        if let modelID = defaults.string(forKey: SettingsKey.openAITranscriptionModelID),
           let model = OpenAIRealtimeTranscriptionModel(rawValue: modelID) {
            openAITranscriptionModel = model
        }
        if defaults.string(forKey: SettingsKey.openAITranslationModelID) == "gpt-realtime-translate-only" {
            openAITranslationModel = .gptRealtimeTranslate
        } else if let modelID = defaults.string(forKey: SettingsKey.openAITranslationModelID),
                  let model = OpenAIRealtimeTranslationModel(rawValue: modelID) {
            openAITranslationModel = (model.isEnabled && !model.isSupportedLiveTranslationModel)
                ? .gptRealtimeTranslate
                : model
        }
        if let modelID = defaults.string(forKey: SettingsKey.geminiTranslationModelID),
           let model = GeminiTranslationModel(rawValue: modelID) {
            geminiTranslationModel = model
        }
        if defaults.object(forKey: SettingsKey.appleVoiceOutputEnabled) != nil {
            appleVoiceOutputEnabled = defaults.bool(forKey: SettingsKey.appleVoiceOutputEnabled)
        }
        if defaults.object(forKey: SettingsKey.providerVoiceOutputEnabled) != nil {
            providerVoiceOutputEnabled = defaults.bool(forKey: SettingsKey.providerVoiceOutputEnabled)
        } else if defaults.object(forKey: SettingsKey.isDubbingEnabled) != nil {
            providerVoiceOutputEnabled = defaults.bool(forKey: SettingsKey.isDubbingEnabled)
        }
        if defaults.object(forKey: SettingsKey.translatedVoiceVolume) != nil {
            translatedVoiceVolume = Self.clampedVolume(defaults.double(forKey: SettingsKey.translatedVoiceVolume))
        }
        if defaults.object(forKey: SettingsKey.isTranscriptLintEnabled) != nil {
            isTranscriptLintEnabled = defaults.bool(forKey: SettingsKey.isTranscriptLintEnabled)
        }
        if let modeID = defaults.string(forKey: SettingsKey.floatingCaptionDisplayMode),
           let mode = FloatingCaptionDisplayMode(rawValue: modeID) {
            floatingCaptionDisplayMode = mode
        }
        if let sizeID = defaults.string(forKey: SettingsKey.floatingCaptionTextSize),
           let size = FloatingCaptionTextSize(rawValue: sizeID) {
            floatingCaptionTextSize = size
        }
        if let lineCountID = defaults.string(forKey: SettingsKey.floatingCaptionLineCount),
           let rawValue = Int(lineCountID),
           let lineCount = FloatingCaptionLineCount(rawValue: rawValue) {
            floatingCaptionLineCount = lineCount
        }
        if defaults.object(forKey: SettingsKey.keepsFloatingCaptionAboveOtherWindows) != nil {
            keepsFloatingCaptionAboveOtherWindows = defaults.bool(forKey: SettingsKey.keepsFloatingCaptionAboveOtherWindows)
        }
        if defaults.object(forKey: SettingsKey.sentencePanelBackgroundOpacity) != nil {
            sentencePanelBackgroundOpacity = min(max(defaults.double(forKey: SettingsKey.sentencePanelBackgroundOpacity), 0.1), 1)
        }
        if defaults.object(forKey: SettingsKey.sentencePanelFontSize) != nil {
            sentencePanelFontSize = min(max(defaults.double(forKey: SettingsKey.sentencePanelFontSize), 11), 28)
        }
        if defaults.object(forKey: SettingsKey.paragraphBreakSilenceInterval) != nil {
            paragraphBreakSilenceInterval = min(
                max(defaults.double(forKey: SettingsKey.paragraphBreakSilenceInterval), 1),
                15
            )
        }
        if let contentModeID = defaults.string(forKey: SettingsKey.savedTranscriptContentMode),
           let contentMode = SavedTranscriptContentMode(rawValue: contentModeID) {
            savedTranscriptContentMode = contentMode
        }
        if let durationModeID = defaults.string(forKey: SettingsKey.sessionDurationMode),
           let durationMode = SessionDurationMode(rawValue: durationModeID) {
            sessionDurationMode = durationMode
        }
        if let audioInputSourceID = defaults.string(forKey: SettingsKey.audioInputSource),
           let source = AudioInputSource(rawValue: audioInputSourceID) {
            audioInputSource = source
        }
        if let deviceID = defaults.string(forKey: SettingsKey.selectedMicrophoneInputDeviceID) {
            selectedMicrophoneInputDeviceID = deviceID
        }
        isAppleSourceAutoDetectionEnabled = isAppleSourceAutoDetectionAvailable
            && defaults.bool(forKey: SettingsKey.isAppleSourceAutoDetectionEnabled)
        refreshMicrophoneInputDevices()
        let restoredGPTTranscriptionMode =
            defaults.string(forKey: SettingsKey.openAITranscriptionModelID)
            == OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue
        if restoredGPTTranscriptionMode {
            selectedModel = .appleSpeechOnly
            openAITranslationModel = .off
            geminiTranslationModel = .off
            openAITranscriptionModel = .gptLiveTranscribe
            floatingCaptionDisplayMode = .original
            isDubbingEnabled = false
        } else if openAITranslationModel.isEnabled {
            openAITranscriptionModel = .off
        } else if openAITranscriptionModel == .gptRealtimeWhisper {
            openAITranscriptionModel = .off
        }
        if restoredGPTTranscriptionMode {
            applyVoiceOutputDefault(false)
        } else {
            applyRestoredVoiceOutputPreference()
        }
    }

    private func persistSelectedSettings() {
        guard !isRestoringSelectedSettings else { return }

        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage.id, forKey: SettingsKey.sourceLanguageID)
        defaults.set(targetLanguage.id, forKey: SettingsKey.targetLanguageID)
        defaults.set(selectedModel.id, forKey: SettingsKey.selectedModelID)
        defaults.set(openAITranscriptionModel.id, forKey: SettingsKey.openAITranscriptionModelID)
        defaults.set(openAITranslationModel.id, forKey: SettingsKey.openAITranslationModelID)
        defaults.set(geminiTranslationModel.id, forKey: SettingsKey.geminiTranslationModelID)
        defaults.set(isDubbingEnabled, forKey: SettingsKey.isDubbingEnabled)
        defaults.set(appleVoiceOutputEnabled, forKey: SettingsKey.appleVoiceOutputEnabled)
        defaults.set(providerVoiceOutputEnabled, forKey: SettingsKey.providerVoiceOutputEnabled)
        defaults.set(translatedVoiceVolume, forKey: SettingsKey.translatedVoiceVolume)
        defaults.set(isTranscriptLintEnabled, forKey: SettingsKey.isTranscriptLintEnabled)
        defaults.set(floatingCaptionDisplayMode.id, forKey: SettingsKey.floatingCaptionDisplayMode)
        defaults.set(floatingCaptionTextSize.id, forKey: SettingsKey.floatingCaptionTextSize)
        defaults.set(floatingCaptionLineCount.id, forKey: SettingsKey.floatingCaptionLineCount)
        defaults.set(keepsFloatingCaptionAboveOtherWindows, forKey: SettingsKey.keepsFloatingCaptionAboveOtherWindows)
        defaults.set(sentencePanelBackgroundOpacity, forKey: SettingsKey.sentencePanelBackgroundOpacity)
        defaults.set(sentencePanelFontSize, forKey: SettingsKey.sentencePanelFontSize)
        defaults.set(paragraphBreakSilenceInterval, forKey: SettingsKey.paragraphBreakSilenceInterval)
        defaults.set(savedTranscriptContentMode.id, forKey: SettingsKey.savedTranscriptContentMode)
        defaults.set(sessionDurationMode.id, forKey: SettingsKey.sessionDurationMode)
        defaults.set(audioInputSource.id, forKey: SettingsKey.audioInputSource)
        defaults.set(selectedMicrophoneInputDeviceID, forKey: SettingsKey.selectedMicrophoneInputDeviceID)
        defaults.set(isAppleSourceAutoDetectionEnabled, forKey: SettingsKey.isAppleSourceAutoDetectionEnabled)
    }

    private func stopCapture() async {
        await systemAudioCapture.stop()
        await microphoneAudioCapture.stop()
    }

    private func floatingCaptionText(from text: String?) -> String {
        guard let text else { return "" }

        return text.floatingCaptionTail(
            maxLines: floatingCaptionLineCount.rawValue,
            lineWidthUnits: floatingCaptionTextSize.floatingLineWidthUnits
        )
    }

    private func loadSavedTranscripts() {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: transcriptsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let transcriptFiles = fileURLs
                .filter { $0.pathExtension == "txt" }
                .compactMap { fileURL -> SavedTranscriptFile? in
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    return SavedTranscriptFile(
                        fileName: fileURL.lastPathComponent,
                        previewText: transcriptPreview(fileURL: fileURL),
                        updatedAt: values?.contentModificationDate ?? Date.distantPast
                    )
                }
            savedTranscripts = groupedSavedTranscripts(from: transcriptFiles)
            sortSavedTranscripts()
        } catch {
            savedTranscripts = []
        }
    }

    private func transcriptPreview(fileURL: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: 4_096)) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadTranscriptText(fileName: String) -> String? {
        try? String(contentsOf: transcriptURL(fileName: fileName), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func groupedSavedTranscripts(from files: [SavedTranscriptFile]) -> [SavedTranscript] {
        var standaloneTranscripts: [SavedTranscript] = []
        var partialTranscripts: [String: PartialSavedTranscript] = [:]

        for file in files {
            if let variant = transcriptVariantInfo(file.fileName) {
                var partial = partialTranscripts[variant.baseFileName] ?? PartialSavedTranscript()
                switch variant.part {
                case .original:
                    partial.original = file
                case .translation:
                    partial.translation = file
                }
                partialTranscripts[variant.baseFileName] = partial
            } else {
                standaloneTranscripts.append(
                    SavedTranscript(
                        fileName: file.fileName,
                        sourceText: file.previewText,
                        updatedAt: file.updatedAt
                    )
                )
            }
        }

        for (baseFileName, partial) in partialTranscripts {
            if let original = partial.original, let translation = partial.translation {
                standaloneTranscripts.append(
                    SavedTranscript(
                        id: baseFileName,
                        sourceFileName: original.fileName,
                        translationFileName: translation.fileName,
                        sourceText: original.previewText,
                        translatedText: translation.previewText,
                        updatedAt: max(original.updatedAt, translation.updatedAt)
                    )
                )
            } else if let original = partial.original {
                standaloneTranscripts.append(
                    SavedTranscript(
                        fileName: original.fileName,
                        sourceText: original.previewText,
                        updatedAt: original.updatedAt
                    )
                )
            } else if let translation = partial.translation {
                standaloneTranscripts.append(
                    SavedTranscript(
                        fileName: translation.fileName,
                        sourceText: translation.previewText,
                        updatedAt: translation.updatedAt
                    )
                )
            }
        }

        return standaloneTranscripts
    }

    private func stageTranscriptForSave(_ sourceText: String, translatedText: String? = nil) {
        let sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        activeAutosaveSourceText = sourceText
        if let translatedText {
            let translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translatedText.isEmpty, translatedText != AppText.translating {
                activeAutosaveTranslatedText = translatedText
            }
        }
        scheduleTranscriptCheckpointIfNeeded()
    }

    private func scheduleTranscriptCheckpointIfNeeded() {
        guard isRunning, transcriptCheckpointTask == nil else { return }

        let intervalMilliseconds = max(Int(transcriptCheckpointInterval * 1_000), 1)
        transcriptCheckpointTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
                guard !Task.isCancelled, self.isRunning else { break }
                if !self.isPaused {
                    _ = self.checkpointPendingTranscriptSave()
                }
            }
        }
    }

    @discardableResult
    private func checkpointPendingTranscriptSave() -> Bool {
        persistPendingTranscriptSave(clearsStagedText: false, reloadsLibrary: false)
    }

    @discardableResult
    private func flushPendingTranscriptSave() -> Bool {
        persistPendingTranscriptSave(clearsStagedText: true, reloadsLibrary: true)
    }

    @discardableResult
    private func persistPendingTranscriptSave(
        clearsStagedText: Bool,
        reloadsLibrary: Bool
    ) -> Bool {
        let currentSourceText = visibleTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentSourceText.isEmpty {
            activeAutosaveSourceText = currentSourceText
        }

        let sourceText = activeAutosaveSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return false }

        let updatedAt = Date()
        let baseFileName = activeAutosaveBaseFileName
            ?? makeTranscriptFileName(for: sourceText, date: updatedAt)
        activeAutosaveBaseFileName = baseFileName
        let savedFiles = savedTranscriptFiles(
            sourceText: sourceText,
            translatedText: activeAutosaveTranslatedText,
            baseFileName: baseFileName
        )

        for savedFile in savedFiles {
            guard writeTranscriptText(savedFile.text, fileName: savedFile.fileName) else {
                return false
            }
        }

        if clearsStagedText {
            activeAutosaveSourceText = ""
            activeAutosaveTranslatedText = ""
            activeAutosaveBaseFileName = nil
        }
        if reloadsLibrary {
            loadSavedTranscripts()
        }
        return true
    }

    private func savedTranscriptFiles(
        sourceText: String,
        translatedText: String,
        baseFileName: String
    ) -> [(fileName: String, text: String)] {
        let sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch savedTranscriptContentMode {
        case .original:
            return [(baseFileName, sourceText)]
        case .translation:
            return [(baseFileName, translatedText.isEmpty ? sourceText : translatedText)]
        case .originalAndTranslation:
            var files = [
                (transcriptVariantFileName(baseFileName, suffix: "original"), sourceText)
            ]
            if !translatedText.isEmpty {
                files.append(
                    (transcriptVariantFileName(baseFileName, suffix: "translation"), translatedText)
                )
            }
            return files
        }
    }

    @discardableResult
    private func writeTranscriptText(_ text: String, fileName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: transcriptsDirectoryURL,
                withIntermediateDirectories: true
            )
            try text.write(
                to: transcriptURL(fileName: fileName),
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            statusMessage = AppText.saveLibraryFailed(error.localizedDescription)
            return false
        }
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastSequence += 1

        let sequence = toastSequence
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard toastSequence == sequence else { return }
            toastMessage = nil
        }
    }

    private func sortSavedTranscripts() {
        savedTranscripts.sort { $0.updatedAt > $1.updatedAt }
    }

    private var transcriptsDirectoryURL: URL {
        if let transcriptsDirectoryOverride {
            return transcriptsDirectoryOverride
        }

        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("AirTranslate", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func transcriptURL(fileName: String) -> URL {
        transcriptsDirectoryURL.appendingPathComponent(fileName)
    }

    private func transcriptVariantFileName(_ fileName: String, suffix: String) -> String {
        let stem = fileName.hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
        return "\(stem)_\(suffix).txt"
    }

    private func legacyTranscriptVariantFileName(_ fileName: String, suffix: String) -> String {
        let stem = fileName.hasSuffix(".txt") ? String(fileName.dropLast(4)) : fileName
        return "\(stem)-\(suffix).txt"
    }

    private func transcriptVariantInfo(_ fileName: String) -> (baseFileName: String, part: SavedTranscriptPart)? {
        let variants: [(suffix: String, part: SavedTranscriptPart)] = [
            ("_original.txt", .original),
            ("_translation.txt", .translation),
            ("-original.txt", .original),
            ("-translation.txt", .translation)
        ]

        for variant in variants where fileName.hasSuffix(variant.suffix) {
            let stem = String(fileName.dropLast(variant.suffix.count))
            return ("\(stem).txt", variant.part)
        }

        return nil
    }

    private func makeTranscriptFileName(for sourceText: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: date)
        let baseName = "\(timestamp)_\(shortFileTitle(from: sourceText))"
        var fileName = "\(baseName).txt"
        var suffix = 2

        while transcriptFileExists(fileName) {
            fileName = "\(baseName)_\(suffix).txt"
            suffix += 1
        }

        return fileName
    }

    private func transcriptFileExists(_ fileName: String) -> Bool {
        let fileNames = [
            fileName,
            transcriptVariantFileName(fileName, suffix: "original"),
            transcriptVariantFileName(fileName, suffix: "translation"),
            legacyTranscriptVariantFileName(fileName, suffix: "original"),
            legacyTranscriptVariantFileName(fileName, suffix: "translation")
        ]
        return fileNames.contains { FileManager.default.fileExists(atPath: transcriptURL(fileName: $0).path) }
    }

    private func shortFileTitle(from sourceText: String) -> String {
        let firstLine = sourceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? AppText.untitledTranscript
        let allowedCharacters = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "-_"))
        let readableText = String(firstLine.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        })
        let sanitized = readableText
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))

        guard !sanitized.isEmpty else {
            return AppText.untitledTranscript.replacingOccurrences(of: " ", with: "-")
        }

        return String(sanitized.prefix(32))
    }

    private func appendCaption(
        sourceText: String,
        recognizedLanguage: LanguageOption,
        confidence: Double,
        isFinal: Bool
    ) {
        guard isRunning, !isPaused else { return }
        guard sourceText != lastRecognizedText || isFinal != lastRecognizedWasFinal else { return }

        let now = Date()
        let hadLongSilence = now.timeIntervalSince(lastRecognitionAt) > paragraphBreakSilenceInterval
        if shouldRequestAutoDetectionLanguageChange(
            recognizedLanguage: recognizedLanguage,
            confidence: confidence,
            hadLongSilence: hadLongSilence
        ) {
            pauseForAutoDetectionLanguageChange(
                detectedLanguage: recognizedLanguage,
                sourceText: sourceText,
                confidence: confidence
            )
            return
        }
        guard shouldAcceptRecognizedLanguage(
            recognizedLanguage: recognizedLanguage,
            confidence: confidence,
            hadLongSilence: hadLongSilence
        ) else {
            return
        }
        let direction = translationDirection(recognizedLanguage: recognizedLanguage)

        let updatedSourceText = accumulatedTranscript(
            incoming: sourceText,
            hadLongSilence: hadLongSilence,
            isFinal: isFinal,
            language: direction.source
        )
        guard !updatedSourceText.isEmpty else { return }

        lastRecognizedText = sourceText
        lastRecognizedWasFinal = isFinal
        lastRecognitionAt = now
        transcriptCleanupTask?.cancel()

        if let currentLineID,
           let index = lines.firstIndex(where: { $0.id == currentLineID }) {
            let existingLine = lines[index]
            let sourceLanguageChanged = sourceLanguageByLineID[existingLine.id] != direction.source
            sourceLanguageByLineID[existingLine.id] = direction.source
            guard updatedSourceText != existingLine.sourceText || sourceLanguageChanged else { return }
            if sourceLanguageChanged, updatedSourceText == existingLine.sourceText {
                pendingTranslationSourceText = ""
                requestTranslation(for: existingLine, source: direction.source, target: direction.target)
                return
            }

            if shouldPresentCaptionUpdate(sourceText: updatedSourceText, isFinal: isFinal) {
                clearPendingCaptionPresentation()
                presentCaptionLineUpdate(
                    lineID: existingLine.id,
                    sourceText: updatedSourceText,
                    isFinal: isFinal,
                    source: direction.source,
                    target: direction.target
                )
            } else {
                scheduleCaptionPresentation(
                    lineID: existingLine.id,
                    sourceText: updatedSourceText,
                    isFinal: isFinal,
                    source: direction.source,
                    target: direction.target
                )
            }
        } else {
            clearPendingCaptionPresentation()
            let line = CaptionLine(
                sourceText: updatedSourceText,
                translatedText: AppText.translating,
                createdAt: Date(),
                isFinal: isFinal,
                revision: 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
            currentLineID = line.id
            sourceLanguageByLineID[line.id] = direction.source
            lines.append(line)
            lastCaptionPresentationUpdateAt = Date()
            stageTranscriptForSave(line.sourceText)
            requestTranslation(for: line, source: direction.source, target: direction.target)
        }
    }

    private func enqueueRecognizedCaption(
        sourceText: String,
        recognizedLanguage: LanguageOption,
        confidence: Double
    ) {
        if !isLargeTranscriptRecognitionCoalescingActive {
            let currentSourceLength = lines.last?.sourceText.utf16.count ?? 0
            isLargeTranscriptRecognitionCoalescingActive = usesLongSessionMode
                || currentSourceLength >= Self.largeTranscriptPresentationCharacterLimit
                || sourceText.utf16.count >= Self.largeTranscriptPresentationCharacterLimit
        }

        guard isLargeTranscriptRecognitionCoalescingActive else {
            lastRecognizedCaptionDeliveryAt = Date()
            appendCaption(
                sourceText: sourceText,
                recognizedLanguage: recognizedLanguage,
                confidence: confidence,
                isFinal: false
            )
            return
        }

        pendingRecognizedCaption = PendingRecognizedCaption(
            sourceText: sourceText,
            recognizedLanguage: recognizedLanguage,
            confidence: confidence
        )
        guard recognizedCaptionDeliveryTask == nil else { return }

        let elapsed = Date().timeIntervalSince(lastRecognizedCaptionDeliveryAt)
        let delay = max(0, Self.largeTranscriptRecognitionDeliveryInterval - elapsed)
        guard delay > 0 else {
            flushPendingRecognizedCaption()
            return
        }

        recognizedCaptionDeliveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard !Task.isCancelled else { return }
            self?.flushPendingRecognizedCaption()
        }
    }

    private func flushPendingRecognizedCaption() {
        recognizedCaptionDeliveryTask?.cancel()
        recognizedCaptionDeliveryTask = nil
        guard let pendingRecognizedCaption else { return }

        self.pendingRecognizedCaption = nil
        lastRecognizedCaptionDeliveryAt = Date()
        appendCaption(
            sourceText: pendingRecognizedCaption.sourceText,
            recognizedLanguage: pendingRecognizedCaption.recognizedLanguage,
            confidence: pendingRecognizedCaption.confidence,
            isFinal: false
        )
    }

    private var currentAutoDetectedSourceLanguage: LanguageOption? {
        if let currentPartialLanguage {
            return currentPartialLanguage
        }

        if let currentLineID,
           let lineLanguage = sourceLanguageByLineID[currentLineID] {
            return lineLanguage
        }

        return nil
    }

    private func shouldRequestAutoDetectionLanguageChange(
        recognizedLanguage: LanguageOption,
        confidence: Double,
        hadLongSilence: Bool
    ) -> Bool {
        AutoDetectionLanguageChangePolicy.shouldRequestConfirmation(
            isAutoDetectionEnabled: isUsingAppleSourceAutoDetection,
            activeLanguage: currentAutoDetectedSourceLanguage,
            detectedLanguage: recognizedLanguage,
            confidence: confidence,
            hadLongSilence: hadLongSilence,
            hasVisibleTranscript: !visibleTranscript().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            minimumSwitchConfidence: Self.appleAutoDetectionLanguageSwitchMinimumConfidence
        )
    }

    private func pauseForAutoDetectionLanguageChange(
        detectedLanguage: LanguageOption,
        sourceText: String,
        confidence: Double
    ) {
        guard pendingAutoDetectionLanguageChange == nil,
              let currentLanguage = currentAutoDetectedSourceLanguage
        else {
            return
        }

        flushPendingCaptionPresentation()
        transcriptCleanupTask?.cancel()
        transcriptCleanupTask = nil
        commitCurrentPartial()
        organizeCurrentTranscript(sourceTextOverride: visibleTranscript())
        pendingAutoDetectionLanguageChange = AutoDetectionLanguageChangeConfirmation(
            currentLanguage: currentLanguage,
            detectedLanguage: detectedLanguage,
            targetLanguage: targetLanguage,
            sourceText: sourceText,
            confidence: confidence
        )
        setCaptionersPaused(true)
        stopSpeaking()
        isPaused = true
        statusMessage = AppText.autoDetectionLanguageChangePaused(
            current: currentLanguage.localizedTitle,
            detected: detectedLanguage.localizedTitle
        )
    }

    private func shouldPresentCaptionUpdate(sourceText: String, isFinal: Bool) -> Bool {
        let sourceLength = sourceText.utf16.count
        guard sourceLength >= Self.largeTranscriptPresentationCharacterLimit else { return true }

        let elapsed = Date().timeIntervalSince(lastCaptionPresentationUpdateAt)
        let interval = isFinal
            ? Self.largeTranscriptPresentationInterval / 2
            : Self.largeTranscriptPresentationInterval
        return elapsed >= interval
    }

    private func shouldAcceptRecognizedLanguage(
        recognizedLanguage: LanguageOption,
        confidence: Double,
        hadLongSilence: Bool
    ) -> Bool {
        guard isUsingAppleSourceAutoDetection else { return true }
        guard confidence >= Self.appleAutoDetectionMinimumConfidence else { return false }
        if currentPartialLanguage == nil,
           let appleAutoDetectionPreferredLanguage,
           appleAutoDetectionPreferredLanguage != recognizedLanguage {
            return confidence >= Self.appleAutoDetectionLanguageSwitchMinimumConfidence
        }
        guard let currentPartialLanguage else { return true }
        guard currentPartialLanguage != recognizedLanguage else { return true }

        return false
    }

    private func scheduleCaptionPresentation(
        lineID: UUID,
        sourceText: String,
        isFinal: Bool,
        source: LanguageOption,
        target: LanguageOption
    ) {
        pendingCaptionPresentation = PendingCaptionPresentation(
            lineID: lineID,
            sourceText: sourceText,
            isFinal: isFinal,
            source: source,
            target: target
        )
        captionPresentationTask?.cancel()

        let elapsed = Date().timeIntervalSince(lastCaptionPresentationUpdateAt)
        let delay = max(0, Self.largeTranscriptPresentationInterval - elapsed)
        captionPresentationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard !Task.isCancelled else { return }
            flushPendingCaptionPresentation()
        }
    }

    private func flushPendingCaptionPresentation() {
        guard let pendingCaptionPresentation else { return }

        self.pendingCaptionPresentation = nil
        captionPresentationTask?.cancel()
        captionPresentationTask = nil
        presentCaptionLineUpdate(
            lineID: pendingCaptionPresentation.lineID,
            sourceText: pendingCaptionPresentation.sourceText,
            isFinal: pendingCaptionPresentation.isFinal,
            source: pendingCaptionPresentation.source,
            target: pendingCaptionPresentation.target
        )
    }

    private func clearPendingCaptionPresentation() {
        pendingCaptionPresentation = nil
        captionPresentationTask?.cancel()
        captionPresentationTask = nil
    }

    private func presentCaptionLineUpdate(
        lineID: UUID,
        sourceText: String,
        isFinal: Bool,
        source: LanguageOption,
        target: LanguageOption
    ) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }

        let existingLine = lines[index]
        guard sourceText != existingLine.sourceText || isFinal != existingLine.isFinal else { return }

        let line = CaptionLine(
            id: existingLine.id,
            sourceText: sourceText,
            translatedText: existingLine.translatedText,
            translatedSourceText: existingLine.translatedSourceText,
            translationsBySentence: existingLine.translationsBySentence,
            createdAt: existingLine.createdAt,
            isFinal: isFinal,
            revision: existingLine.revision + 1,
            usesLongSessionDisplay: usesLongSessionMode
        )
        lines[index] = line
        lastCaptionPresentationUpdateAt = Date()
        stageTranscriptForSave(line.sourceText)
        requestTranslation(for: line, source: source, target: target)
    }

    private func accumulatedTranscript(
        incoming: String,
        hadLongSilence: Bool,
        isFinal: Bool,
        language: LanguageOption
    ) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return visibleTranscript() }

        if hadLongSilence, !currentPartialText.isEmpty {
            commitCurrentPartial()
            pendingParagraphBreakBeforePartial = !committedSourceText.isEmpty
            pendingFloatingParagraphBreakBeforePartial = !floatingCommittedSourceText.isEmpty
        }

        let incomingPartial = uncommittedIncomingText(
            from: trimmedIncoming,
            allowsCommittedRevision: !hadLongSilence,
            allowsCommittedReplay: !hadLongSilence,
            language: language
        )
        guard !incomingPartial.isEmpty else { return visibleTranscript() }

        if currentPartialText.isEmpty {
            currentPartialText = incomingPartial
            currentPartialLanguage = language
            setFloatingCurrentPartialText(incomingPartial)
            return visibleTranscript()
        }

        if currentPartialLanguage != language {
            commitCurrentPartial()
            pendingParagraphBreakBeforePartial = hadLongSilence && !committedSourceText.isEmpty
            pendingFloatingParagraphBreakBeforePartial = hadLongSilence && !floatingCommittedSourceText.isEmpty
            currentPartialText = incomingPartial
            currentPartialLanguage = language
            setFloatingCurrentPartialText(currentPartialText)
            return visibleTranscript()
        }

        if isRevisionOfCurrentPartial(incomingPartial) {
            currentPartialText = preferredPartialText(current: currentPartialText, incoming: incomingPartial)
            setFloatingCurrentPartialText(currentPartialText)
            return visibleTranscript()
        }

        if !hadLongSilence,
           !isFinal,
           isVolatileFragmentSuperseded(by: incomingPartial) {
            currentPartialText = incomingPartial
            setFloatingCurrentPartialText(currentPartialText)
            return visibleTranscript()
        }

        commitCurrentPartial()
        pendingParagraphBreakBeforePartial = hadLongSilence && !committedSourceText.isEmpty
        pendingFloatingParagraphBreakBeforePartial = hadLongSilence && !floatingCommittedSourceText.isEmpty
        currentPartialText = uncommittedIncomingText(
            from: trimmedIncoming,
            allowsCommittedRevision: true,
            allowsCommittedReplay: true,
            language: language
        )
        currentPartialLanguage = language
        setFloatingCurrentPartialText(currentPartialText)
        return visibleTranscript()
    }

    private func uncommittedIncomingText(
        from incoming: String,
        allowsCommittedRevision: Bool,
        allowsCommittedReplay: Bool,
        language: LanguageOption
    ) -> String {
        if allowsCommittedReplay,
           let replayTail = incomingTailAfterRecentCommittedReplay(incoming, language: language) {
            syncFloatingCommittedSourceTextToCommittedSourceText()
            return replayTail
        }

        if allowsCommittedReplay,
           TranscriptTextProcessor.committedTranscriptAlreadyMatches(incoming, in: committedSourceText) {
            return ""
        }

        if allowsCommittedRevision,
           replaceCommittedUnitsIfRevision(with: incoming, language: language, allowsBackfill: true) {
            syncFloatingCommittedSourceTextToCommittedSourceText()
            return ""
        }

        if let tail = incomingTailAfterCommittedText(
            incoming,
            allowsCommittedReplay: allowsCommittedReplay
        ) {
            return tail
        }

        return incoming
    }

    private func incomingTailAfterRecentCommittedReplay(_ incoming: String, language: LanguageOption) -> String? {
        guard let replay = TranscriptTextProcessor.incomingTailAfterRecentCommittedReplay(
            incoming,
            committedText: committedSourceText,
            languageID: language.id
        ) else {
            return nil
        }

        committedSourceText = replay.committedText
        return replay.tailText
    }

    private func incomingTailAfterCommittedText(
        _ incoming: String,
        allowsCommittedReplay: Bool
    ) -> String? {
        TranscriptTextProcessor.incomingTailAfterCommittedText(
            incoming,
            committedText: committedSourceText,
            allowsCommittedReplay: allowsCommittedReplay
        )
    }

    private func isRevisionOfCurrentPartial(_ incomingPartial: String) -> Bool {
        TranscriptTextProcessor.isRevisionOfCurrentPartial(
            current: currentPartialText,
            incoming: incomingPartial
        )
    }

    private func preferredPartialText(current: String, incoming: String) -> String {
        TranscriptTextProcessor.preferredPartialText(current: current, incoming: incoming)
    }

    private func isVolatileFragmentSuperseded(by incomingPartial: String) -> Bool {
        TranscriptTextProcessor.isVolatileFragmentSuperseded(
            current: currentPartialText,
            incoming: incomingPartial
        )
    }

    private func isWholeTextPrefix(_ prefix: String, of text: String) -> Bool {
        TranscriptTextProcessor.isWholeTextPrefix(prefix, of: text)
    }

    private func commitCurrentPartial() {
        let language = currentPartialLanguage ?? sourceLanguage
        let partial = isUsingOpenAIRealtime
            ? currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            : organizeTranscript(currentPartialText, language: language)
        guard !partial.isEmpty else { return }

        var didAppendCommittedPartial = false
        var didReplaceCommittedPartial = false
        if committedSourceText.isEmpty {
            committedSourceText = partial
            didAppendCommittedPartial = true
        } else if replaceCommittedUnitsIfRevision(with: partial, language: language, allowsBackfill: false) {
            // The speech recognizer can resend the last phrase with better wording after
            // cleanup. Treat that as a replacement, not a new line.
            didReplaceCommittedPartial = true
        } else if shouldAppendCommittedPartial(partial) {
            let separator = pendingParagraphBreakBeforePartial ? "\n\n" : "\n"
            committedSourceText += separator + partial
            didAppendCommittedPartial = true
        }
        pendingParagraphBreakBeforePartial = false
        currentPartialText = ""
        currentPartialLanguage = nil

        if didAppendCommittedPartial {
            commitFloatingCurrentPartial()
        } else if didReplaceCommittedPartial {
            syncFloatingCommittedSourceTextToCommittedSourceText(keepsCurrentPartial: false)
        } else {
            discardFloatingCurrentPartial()
        }
    }

    private func commitFloatingCurrentPartial() {
        let partial = floatingCurrentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return }

        if floatingCommittedSourceText.isEmpty {
            floatingCommittedSourceText = partial
        } else if shouldAppendCommittedPartial(
            partial,
            to: floatingCommittedSourceText,
            pendingParagraphBreak: pendingFloatingParagraphBreakBeforePartial
        ) {
            let separator = pendingFloatingParagraphBreakBeforePartial ? "\n\n" : "\n"
            floatingCommittedSourceText += separator + partial
        }
        pendingFloatingParagraphBreakBeforePartial = false
        floatingCurrentPartialText = ""
        refreshFloatingCaptionPresentation()
    }

    private func setFloatingCurrentPartialText(_ text: String) {
        floatingCurrentPartialText = text
        refreshFloatingCaptionPresentation()
    }

    private func syncFloatingCommittedSourceTextToCommittedSourceText(keepsCurrentPartial: Bool = true) {
        floatingCommittedSourceText = committedSourceText
        if !keepsCurrentPartial {
            floatingCurrentPartialText = ""
            pendingFloatingParagraphBreakBeforePartial = false
        }
        refreshFloatingCaptionPresentation()
    }

    private func discardFloatingCurrentPartial() {
        floatingCurrentPartialText = ""
        pendingFloatingParagraphBreakBeforePartial = false
        refreshFloatingCaptionPresentation()
    }

    private func rehydrateFloatingCaptionDisplayFromCurrentLine() {
        guard let line = lines.last else {
            floatingCommittedSourceText = ""
            floatingCurrentPartialText = ""
            pendingFloatingParagraphBreakBeforePartial = false
            floatingPresentedSourceText = ""
            floatingQueuedSourceText = ""
            floatingPresentedAt = Date.distantPast
            floatingPresentedUnreadLength = 0
            floatingDisplayTranslationText = ""
            floatingDisplayTranslationSourceText = ""
            floatingQueuedTranslationText = ""
            floatingQueuedTranslationSourceText = ""
            return
        }

        floatingCommittedSourceText = line.sourceText
        floatingCurrentPartialText = ""
        pendingFloatingParagraphBreakBeforePartial = false
        floatingPresentedSourceText = isUsingOpenAIRealtime
            ? realtimeFloatingCaptionText(from: line.sourceText)
            : line.sourceText
        floatingQueuedSourceText = ""
        floatingPresentedAt = Date()
        floatingPresentedUnreadLength = normalizedTranscriptForComparison(floatingPresentedSourceText).count

        let translatedText = line.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if translatedText.isEmpty || translatedText == AppText.translating {
            floatingDisplayTranslationText = ""
            floatingDisplayTranslationSourceText = ""
        } else {
            floatingDisplayTranslationText = isUsingOpenAIRealtime
                ? realtimeFloatingCaptionText(from: translatedText)
                : translatedText
            floatingDisplayTranslationSourceText = floatingPresentedSourceText
        }
        floatingQueuedTranslationText = ""
        floatingQueuedTranslationSourceText = ""
    }

    private func refreshFloatingCaptionPresentation() {
        let candidate = floatingVisibleSourceTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }

        if floatingPresentedSourceText.isEmpty {
            presentFloatingSourceText(candidate)
            return
        }

        let normalizedCandidate = normalizedTranscriptForComparison(candidate)
        let normalizedPresented = normalizedTranscriptForComparison(floatingPresentedSourceText)
        guard normalizedCandidate != normalizedPresented else { return }

        if isWholeTextPrefix(normalizedPresented, of: normalizedCandidate) {
            // Extensions keep the already-read text in place, so they can render
            // immediately. Keeping the dwell clock running prevents a stream of
            // extensions from postponing queued replacements forever.
            presentFloatingSourceText(candidate, resetsDwell: false)
            return
        }

        let now = Date()
        if canUpdateFloatingPresentationImmediately(now: now)
            || canAdvanceFloatingPresentation(now: now) {
            presentFloatingSourceText(candidate)
            return
        }

        floatingQueuedSourceText = candidate
        scheduleFloatingPresentationAdvance()
    }

    private func canUpdateFloatingPresentationImmediately(now: Date) -> Bool {
        now.timeIntervalSince(floatingPresentedAt) <= Self.floatingCaptionEarlyRevisionWindow
    }

    private func canAdvanceFloatingPresentation(now: Date = Date()) -> Bool {
        guard !floatingPresentedSourceText.isEmpty else { return true }
        return now.timeIntervalSince(floatingPresentedAt) >= floatingCaptionDwellDuration()
    }

    private func floatingCaptionDwellDuration() -> TimeInterval {
        let dwell = 0.9 + Double(floatingPresentedUnreadLength) / 28.0
        return min(
            max(Self.minimumFloatingCaptionDwell, dwell),
            Self.maximumFloatingCaptionDwell
        )
    }

    private func presentFloatingSourceText(_ text: String, resetsDwell: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let normalizedText = normalizedTranscriptForComparison(text)
        let normalizedPresented = normalizedTranscriptForComparison(floatingPresentedSourceText)
        let unreadLength = max(0, normalizedText.count - commonPrefixLength(normalizedPresented, normalizedText))
        floatingPresentedSourceText = text
        floatingQueuedSourceText = ""
        if resetsDwell {
            floatingPresentedAt = Date()
            floatingPresentedUnreadLength = unreadLength
        } else {
            floatingPresentedUnreadLength += unreadLength
        }
        if !floatingDisplayTranslationSourceText.isEmpty,
           !translationSource(floatingDisplayTranslationSourceText, matches: text) {
            floatingDisplayTranslationText = ""
            floatingDisplayTranslationSourceText = ""
        }
        promoteQueuedFloatingTranslationIfPossible()
    }

    private func scheduleFloatingPresentationAdvance() {
        floatingPresentationTask?.cancel()

        let remaining = max(
            0.05,
            floatingCaptionDwellDuration() - Date().timeIntervalSince(floatingPresentedAt)
        )
        let delayMilliseconds = max(50, Int(remaining * 1_000))
        floatingPresentationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            promoteQueuedFloatingPresentationIfReady()
        }
    }

    private func promoteQueuedFloatingPresentationIfReady() {
        guard canAdvanceFloatingPresentation() else {
            scheduleFloatingPresentationAdvance()
            return
        }

        if !floatingQueuedSourceText.isEmpty {
            presentFloatingSourceText(floatingQueuedSourceText)
        } else {
            promoteQueuedFloatingTranslationIfPossible()
        }

        if !floatingQueuedSourceText.isEmpty || !floatingQueuedTranslationText.isEmpty {
            scheduleFloatingPresentationAdvance()
        } else {
            floatingPresentationTask = nil
        }
    }

    private func replaceCommittedUnitsIfRevision(
        with text: String,
        language: LanguageOption,
        allowsBackfill: Bool
    ) -> Bool {
        guard let updatedText = TranscriptTextProcessor.committedTextByReplacingRevision(
            with: text,
            committedText: committedSourceText,
            languageID: language.id,
            allowsBackfill: allowsBackfill
        ) else {
            return false
        }

        committedSourceText = updatedText
        return true
    }

    private func shouldAppendCommittedPartial(_ partial: String) -> Bool {
        shouldAppendCommittedPartial(
            partial,
            to: committedSourceText,
            pendingParagraphBreak: pendingParagraphBreakBeforePartial
        )
    }

    private func shouldAppendCommittedPartial(
        _ partial: String,
        to committedText: String,
        pendingParagraphBreak: Bool
    ) -> Bool {
        TranscriptTextProcessor.shouldAppendCommittedPartial(
            partial,
            to: committedText,
            pendingParagraphBreak: pendingParagraphBreak
        )
    }

    private func transcriptUnits(from text: String) -> [TranscriptUnit] {
        TranscriptTextProcessor.transcriptUnits(from: text)
    }

    private func transcriptText(from units: [TranscriptUnit]) -> String {
        TranscriptTextProcessor.transcriptText(from: units)
    }

    private func realtimeFloatingCaptionText(from text: String) -> String {
        let units = transcriptUnits(from: text)
        guard let latestUnit = units.last else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return latestUnit.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTranscriptForComparison(_ text: String) -> String {
        TranscriptTextProcessor.normalizedForComparison(text)
    }

    private func visibleTranscript() -> String {
        let committed = committedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !committed.isEmpty else {
            return partial
        }
        guard !partial.isEmpty else {
            return committed
        }

        let separator = pendingParagraphBreakBeforePartial ? "\n\n" : "\n"
        return committed + separator + partial
    }

    private func floatingVisibleSourceTranscript() -> String {
        let committed = floatingCommittedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = floatingCurrentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isUsingOpenAIRealtime {
            if !partial.isEmpty {
                return realtimeFloatingCaptionText(from: partial)
            }
            return realtimeFloatingCaptionText(from: committed)
        }

        guard !committed.isEmpty else {
            return partial
        }
        guard !partial.isEmpty else {
            return committed
        }

        let separator = pendingFloatingParagraphBreakBeforePartial ? "\n\n" : "\n"
        return committed + separator + partial
    }

    private func scheduleTranscriptCleanup() {
        guard isRunning, currentLineID != nil else { return }
        guard !isUsingOpenAIRealtime else { return }
        guard Date().timeIntervalSince(lastRecognitionAt) > 1.5 else { return }

        if let pendingCleanup = transcriptCleanupTask, !pendingCleanup.isCancelled {
            return
        }
        transcriptCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            transcriptCleanupTask = nil
            organizeCurrentTranscript()
        }
    }

    private func organizeCurrentTranscript(sourceTextOverride: String? = nil) {
        guard !isUsingOpenAIRealtime else { return }

        if sourceTextOverride == nil {
            flushPendingCaptionPresentation()
        }

        guard isRunning,
              let currentLineID,
              let index = lines.firstIndex(where: { $0.id == currentLineID })
        else {
            return
        }

        let line = lines[index]
        let sourceText = sourceTextOverride ?? line.sourceText
        let sourceLanguage = sourceLanguageByLineID[line.id] ?? self.sourceLanguage
        let organizedSourceText = organizeTranscript(
            sourceText,
            language: sourceLanguage,
            appliesLint: isTranscriptLintEnabled
        )
        let organizedTranslatedText = organizeTranslatedText(line.translatedText)
        let sourceChanged = organizedSourceText != line.sourceText
        let translationChanged = organizedTranslatedText != line.translatedText
        let needsTranslationRefresh = line.translatedSourceText != organizedSourceText

        if !sourceChanged,
           !translationChanged,
           needsTranslationRefresh,
           pendingTranslationSourceText == organizedSourceText {
            return
        }

        guard sourceChanged || translationChanged || needsTranslationRefresh else {
            return
        }

        committedSourceText = organizedSourceText
        currentPartialText = ""
        lines[index] = CaptionLine(
            id: line.id,
            sourceText: organizedSourceText,
            translatedText: organizedTranslatedText,
            translatedSourceText: line.translatedSourceText,
            translationsBySentence: line.translationsBySentence,
            createdAt: line.createdAt,
            isFinal: line.isFinal,
            revision: line.revision + 1,
            usesLongSessionDisplay: usesLongSessionMode
        )

        // Keep floating captions stable while cleanup rewrites the saved transcript.
        let updatedLine = lines[index]
        sourceLanguageByLineID[updatedLine.id] = sourceLanguage
        stageTranscriptForSave(updatedLine.sourceText)
        if updatedLine.translatedSourceText != updatedLine.sourceText {
            requestTranslation(for: updatedLine, source: sourceLanguage, target: targetLanguage)
        }
    }

    private func organizeTranslatedText(_ text: String) -> String {
        guard text != AppText.translating else { return text }
        return organizeTranscript(text, language: targetLanguage)
    }

    private func organizeTranscript(_ text: String, language: LanguageOption) -> String {
        organizeTranscript(text, language: language, appliesLint: false)
    }

    private func organizeTranscript(
        _ text: String,
        language: LanguageOption,
        appliesLint: Bool
    ) -> String {
        if !appliesLint {
            return TranscriptTextProcessor.organizeTranscript(text, languageID: language.id)
        }

        return paragraphParts(from: text)
            .map {
                let organized = organizeParagraph($0, language: language)
                return lintParagraph(organized, language: language)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func organizeParagraph(_ text: String, language: LanguageOption) -> String {
        TranscriptTextProcessor.organizeParagraph(text, languageID: language.id)
    }

    private func lintParagraph(_ text: String, language: LanguageOption) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { lintLine(String($0), language: language) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func lintLine(_ text: String, language: LanguageOption) -> String {
        var linted = text
            .replacingOccurrences(of: #"(^|[\s,，])[,，]{1,}(\s*[,，]+)*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?。！？])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,.!?])(?=\S)"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        linted = correctUnknownWords(in: linted, language: language)

        if language.id == "en-US" {
            linted = capitalizeSentenceStarts(linted)
        }

        return linted.trimmingCharacters(in: CharacterSet(charactersIn: " ,，"))
    }

    private func correctUnknownWords(in text: String, language: LanguageOption) -> String {
        guard let spellLanguage = spellCheckerLanguage(for: language) else { return text }

        var corrected = text
        var searchLocation = 0

        while searchLocation < (corrected as NSString).length {
            var wordCount = 0
            let misspelledRange = spellChecker.checkSpelling(
                of: corrected,
                startingAt: searchLocation,
                language: spellLanguage,
                wrap: false,
                inSpellDocumentWithTag: spellDocumentTag,
                wordCount: &wordCount
            )
            guard misspelledRange.location != NSNotFound, misspelledRange.length > 0 else { break }

            let textValue = corrected as NSString
            let word = textValue.substring(with: misspelledRange)
            if let replacement = safeSpellingReplacement(
                for: word,
                in: corrected,
                range: misspelledRange,
                language: spellLanguage
            ) {
                corrected = textValue.replacingCharacters(in: misspelledRange, with: replacement)
                searchLocation = misspelledRange.location + (replacement as NSString).length
            } else {
                searchLocation = misspelledRange.location + misspelledRange.length
            }
        }

        return corrected
    }

    private func spellCheckerLanguage(for language: LanguageOption) -> String? {
        let availableLanguages = spellChecker.availableLanguages
        let normalizedID = language.id.replacingOccurrences(of: "-", with: "_")
        if availableLanguages.contains(language.id) {
            return language.id
        }
        if availableLanguages.contains(normalizedID) {
            return normalizedID
        }
        if let baseID = language.id.split(separator: "-").first.map(String.init),
           availableLanguages.contains(baseID) {
            return baseID
        }
        return nil
    }

    private func safeSpellingReplacement(
        for word: String,
        in text: String,
        range: NSRange,
        language: String
    ) -> String? {
        guard shouldCorrectSpelledWord(word, language: language),
              let guesses = spellChecker.guesses(
                  forWordRange: range,
                  in: text,
                  language: language,
                  inSpellDocumentWithTag: spellDocumentTag
              ),
              let replacement = guesses.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              isConservativeReplacement(original: word, replacement: replacement)
        else {
            return nil
        }

        return replacement
    }

    private func shouldCorrectSpelledWord(_ word: String, language: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard trimmed.count > 1 else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        guard trimmed.range(of: #"[/\\@#_]"#, options: .regularExpression) == nil else { return false }

        if language.hasPrefix("en"),
           let first = trimmed.first,
           first.isUppercase {
            return false
        }

        return true
    }

    private func isConservativeReplacement(original: String, replacement: String) -> Bool {
        guard !replacement.isEmpty, !replacement.contains("\n") else { return false }
        let originalLength = max((original as NSString).length, 1)
        let replacementLength = (replacement as NSString).length
        guard replacementLength <= originalLength + 4 else { return false }
        guard replacementLength * 3 >= originalLength else { return false }
        return true
    }

    private func capitalizeSentenceStarts(_ text: String) -> String {
        var result = ""
        var shouldCapitalize = true

        for character in text {
            if shouldCapitalize, character.isLetter {
                result.append(String(character).uppercased())
                shouldCapitalize = false
                continue
            }

            result.append(character)
            if ".!?".contains(character) {
                shouldCapitalize = true
            } else if !character.isWhitespace {
                shouldCapitalize = false
            }
        }

        return result
    }

    private func paragraphParts(from text: String) -> [String] {
        TranscriptTextProcessor.paragraphParts(from: text)
    }

    struct TranscriptTranslation: Sendable {
        let text: String
        let translationsBySentence: [String: String]
    }

    private func translateTranscript(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        progress: @escaping @MainActor @Sendable (TranscriptTranslation) -> Void = { _ in }
    ) async throws -> TranscriptTranslation {
        let sourceLanguageID = source.id
        let paragraphSegments = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return TranscriptTextProcessor.sentenceGroups(from: text, languageID: sourceLanguageID)
        }.value

        guard !paragraphSegments.isEmpty else { return TranscriptTranslation(text: "", translationsBySentence: [:]) }

        var translatedParagraphs: [String] = []
        var translationsBySentence: [String: String] = [:]
        var consecutiveCacheHitCount = 0
        for segments in paragraphSegments {
            var translatedSegments: [String] = []

            for segment in segments {
                try Task.checkCancellation()
                let cacheKey = translationCacheKey(segment: segment, source: source, target: target)
                if let cachedSegment = translationSegmentCache.value(forKey: cacheKey) {
                    consecutiveCacheHitCount += 1
                    if consecutiveCacheHitCount.isMultiple(of: Self.translationCacheHitYieldInterval) {
                        await Task.yield()
                        try Task.checkCancellation()
                    }
                    translatedSegments.append(cachedSegment)
                    translationsBySentence[segment] = cachedSegment
                    continue
                }
                consecutiveCacheHitCount = 0

                let translatedSegment: String
                if openAITranslationModel.isEnabled && !openAITranslationModel.usesRealtimeAudioTranslation {
                    let completedParagraphs = translatedParagraphs
                    let completedSegments = translatedSegments
                    translatedSegment = try await openAITranslator.translate(
                        segment,
                        source: source,
                        target: target,
                        model: openAITranslationModel,
                        progress: { partialSegment in
                            let partialText = (completedParagraphs + [(completedSegments + [partialSegment]).joined(separator: "\n")])
                                .joined(separator: "\n\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !partialText.isEmpty else { return }
                            progress(TranscriptTranslation(text: partialText, translationsBySentence: translationsBySentence))
                        }
                    )
                } else {
                    translatedSegment = try await translator.translate(
                        segment,
                        source: source,
                        target: target,
                        model: selectedModel
                    )
                }
                try Task.checkCancellation()
                let organizedSegment = organizeTranscript(translatedSegment, language: target)
                    .replacingOccurrences(of: "\n", with: " ")
                cacheTranslatedSegment(organizedSegment, forKey: cacheKey)
                translatedSegments.append(organizedSegment)
                translationsBySentence[segment] = organizedSegment

                let partialText = (translatedParagraphs + [translatedSegments.joined(separator: "\n")])
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !partialText.isEmpty {
                    progress(TranscriptTranslation(text: partialText, translationsBySentence: translationsBySentence))
                }
            }

            translatedParagraphs.append(translatedSegments.joined(separator: "\n"))
        }

        return TranscriptTranslation(
            text: translatedParagraphs.joined(separator: "\n\n"),
            translationsBySentence: translationsBySentence
        )
    }

    private func translationCacheKey(segment: String, source: LanguageOption, target: LanguageOption) -> String {
        "\(source.id)\t\(target.id)\t\(translationEngineCacheID)\t\(segment)"
    }

    private var translationEngineCacheID: String {
        if openAITranslationModel.isEnabled {
            return "openai:\(openAITranslationModel.id)"
        }
        return "apple:\(selectedModel.id)"
    }

    private func cacheTranslatedSegment(_ segment: String, forKey key: String) {
        translationSegmentCache.insert(segment, forKey: key)
    }

    private func resetTranslationCache() {
        translationSegmentCache.removeAll()
    }

    private func updateRealtimeTranslationSourceTranscript(_ text: String) {
        guard isRunning, !isPaused else { return }
        guard isUsingOpenAIRealtimeTranslation else { return }

        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            || !realtimeTranslationSourceText.isEmpty else { return }

        realtimeTranslationSourceText = accumulatedRealtimeText(
            current: realtimeTranslationSourceText,
            next: text
        )
        refreshOpenAIRealtimeTranslationLine()
    }

    private func appendRealtimeTranslationOnly(_ text: String) {
        guard isRunning, !isPaused else { return }
        guard isUsingOpenAIRealtimeTranslation else { return }

        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            || !realtimeTranslationOnlyText.isEmpty else { return }

        realtimeTranslationOnlyText = accumulatedRealtimeText(
            current: realtimeTranslationOnlyText,
            next: text
        )
        refreshOpenAIRealtimeTranslationLine()
    }

    private func refreshOpenAIRealtimeTranslationLine() {
        let inputText = realtimeTranslationSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = realtimeTranslationOnlyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.isEmpty || !translatedText.isEmpty else { return }

        lastRecognizedText = inputText.isEmpty ? translatedText : inputText
        lastRecognitionAt = Date()
        transcriptCleanupTask?.cancel()

        let sourceText = inputText.isEmpty ? AppText.openAIRealtimeTranslationOnlySource : inputText
        let visibleTranslatedText = translatedText.isEmpty ? AppText.translating : translatedText

        if let currentLineID,
           let index = lines.firstIndex(where: { $0.id == currentLineID }) {
            let existingLine = lines[index]
            lines[index] = CaptionLine(
                id: existingLine.id,
                sourceText: sourceText,
                translatedText: visibleTranslatedText,
                translatedSourceText: sourceText,
                createdAt: existingLine.createdAt,
                isFinal: false,
                revision: existingLine.revision + 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
        } else {
            let line = CaptionLine(
                sourceText: sourceText,
                translatedText: visibleTranslatedText,
                translatedSourceText: sourceText,
                createdAt: Date(),
                isFinal: false,
                revision: 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
            currentLineID = line.id
            lines.append(line)
        }

        if !inputText.isEmpty {
            presentFloatingSourceText(inputText)
        }
        if !translatedText.isEmpty {
            stageTranscriptForSave(sourceText, translatedText: translatedText)
            updateFloatingTranslationPresentation(translatedText, sourceText: sourceText)
            speakTranslatedDeltaIfNeeded(translatedText)
        }
    }

    private func updateGeminiLiveInputTranscript(_ text: String) {
        guard isRunning, !isPaused else { return }
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            || !geminiLiveInputTranscriptText.isEmpty else { return }

        geminiLiveInputTranscriptText = accumulatedRealtimeText(
            current: geminiLiveInputTranscriptText,
            next: text
        )
        refreshGeminiLiveCaptionLine()
    }

    private func updateGeminiLiveOutputTranscript(_ text: String) {
        guard isRunning, !isPaused else { return }
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            || !geminiLiveOutputTranscriptText.isEmpty else { return }

        geminiLiveOutputTranscriptText = accumulatedRealtimeText(
            current: geminiLiveOutputTranscriptText,
            next: text
        )
        refreshGeminiLiveCaptionLine()
    }

    private func accumulatedRealtimeText(current: String, next: String) -> String {
        if next.hasPrefix(current) {
            return next
        }
        if current.hasSuffix(next) {
            return current
        }
        return current + next
    }

    private func refreshGeminiLiveCaptionLine() {
        let inputText = geminiLiveInputTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText = geminiLiveOutputTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.isEmpty || !outputText.isEmpty else { return }

        lastRecognizedText = inputText.isEmpty ? outputText : inputText
        lastRecognitionAt = Date()
        transcriptCleanupTask?.cancel()

        let sourceText = inputText.isEmpty ? AppText.geminiLiveTranslationSource : inputText
        let translatedText = outputText.isEmpty ? AppText.translating : outputText

        if let currentLineID,
           let index = lines.firstIndex(where: { $0.id == currentLineID }) {
            let existingLine = lines[index]
            lines[index] = CaptionLine(
                id: existingLine.id,
                sourceText: sourceText,
                translatedText: translatedText,
                translatedSourceText: sourceText,
                createdAt: existingLine.createdAt,
                isFinal: false,
                revision: existingLine.revision + 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
            sourceLanguageByLineID[existingLine.id] = sourceLanguage
        } else {
            let line = CaptionLine(
                sourceText: sourceText,
                translatedText: translatedText,
                translatedSourceText: sourceText,
                createdAt: Date(),
                isFinal: false,
                revision: 1,
                usesLongSessionDisplay: usesLongSessionMode
            )
            currentLineID = line.id
            sourceLanguageByLineID[line.id] = sourceLanguage
            lines.append(line)
        }

        if !inputText.isEmpty {
            stageTranscriptForSave(inputText, translatedText: outputText)
            presentFloatingSourceText(inputText)
        }
        if !outputText.isEmpty {
            updateFloatingTranslationPresentation(outputText, sourceText: sourceText)
            speakTranslatedDeltaIfNeeded(outputText)
        }
    }

    private func requestTranslation(for line: CaptionLine, source: LanguageOption, target: LanguageOption) {
        guard !openAITranslationModel.usesRealtimeAudioTranslation else { return }
        guard !isUsingGeminiTranslation else { return }

        guard !isTranscribeOnlyMode else {
            showTranscribeOnlyNoticeForCurrentActivation()
            return
        }

        guard source.id != target.id else {
            markTranslationUnavailable(
                AppText.sameLanguageTranslationUnavailable,
                for: line,
                matching: line.sourceText
            )
            return
        }

        let sourceText = line.sourceText
        guard pendingTranslationSourceText != sourceText else { return }
        pendingTranslationSourceText = sourceText
        if latestTranslationRequest == nil {
            translationBurstStartedAt = Date()
        }
        latestTranslationRequest = TranslationRequest(
            line: line,
            sourceText: sourceText,
            translationSourceText: sourceText,
            source: source,
            target: target
        )

        guard translationTask == nil else {
            return
        }

        translationTaskGeneration += 1
        let generation = translationTaskGeneration
        translationTask = Task { @MainActor in
            await processPendingTranslationRequests(generation: generation)
        }
    }

    private func processPendingTranslationRequests(generation: Int) async {
        while !Task.isCancelled, let request = latestTranslationRequest {
            latestTranslationRequest = nil

            do {
                let delay = translationDebounceDelay(for: request.sourceText)
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }

                if latestTranslationRequest != nil {
                    continue
                }

                translationBurstStartedAt = .distantPast
                let translationSourceText = try await preparedTranslationSourceText(
                    request.translationSourceText,
                    language: request.source
                )
                try Task.checkCancellation()
                if latestTranslationRequest != nil {
                    continue
                }
                let translation = try await translateTranscript(
                    translationSourceText,
                    source: request.source,
                    target: request.target,
                    progress: { [weak self] partial in
                        self?.updateTranslation(
                            partial,
                            for: request.line,
                            matching: request.sourceText,
                            finalizesRequest: false
                        )
                    }
                )
                try Task.checkCancellation()
                updateTranslation(translation, for: request.line, matching: request.sourceText)
            } catch is CancellationError {
                // A cancelled loop can resume after a newer loop was registered;
                // only clear its own registration to avoid spawning a concurrent loop.
                if generation == translationTaskGeneration {
                    translationTask = nil
                }
                return
            } catch {
                if pendingTranslationSourceText == request.sourceText {
                    pendingTranslationSourceText = ""
                }
                markTranslationUnavailable(error.localizedDescription, for: request.line, matching: request.sourceText)
            }
        }

        if generation == translationTaskGeneration {
            translationTask = nil
        }
    }

    private func preparedTranslationSourceText(
        _ sourceText: String,
        language: LanguageOption
    ) async throws -> String {
        guard usesLongSessionMode, !isUsingOpenAIRealtime else { return sourceText }

        let languageID = language.id
        let organizedSourceText = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return TranscriptTextProcessor.organizeTranscript(sourceText, languageID: languageID)
        }.value
        guard !organizedSourceText.isEmpty else { return sourceText }
        return organizedSourceText
    }

    private func translationDebounceDelay(for sourceText: String) -> Int {
        if usesLongSessionMode {
            let sourceLength = sourceText.utf16.count
            if sourceLength >= Self.veryLargeTranscriptTranslationCharacterLimit {
                return 900
            }
            if sourceLength >= Self.largeTranscriptTranslationCharacterLimit {
                return 450
            }
        }

        guard translationBurstStartedAt != .distantPast else { return 45 }
        let burstAge = Date().timeIntervalSince(translationBurstStartedAt)
        return burstAge >= 0.45 ? 0 : 70
    }

    nonisolated static func isCompatibleLiveSource(current: String, requested: String) -> Bool {
        let currentText = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedText = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedText.isEmpty else { return currentText.isEmpty }
        if currentText == requestedText || currentText.hasPrefix(requestedText) {
            return true
        }

        let normalizedCurrentText = currentText.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedRequestedText = requestedText.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedCurrentText == normalizedRequestedText
            || normalizedCurrentText.hasPrefix(normalizedRequestedText)
    }

    private func updateTranslation(
        _ translation: TranscriptTranslation,
        for line: CaptionLine,
        matching sourceText: String,
        finalizesRequest: Bool = true
    ) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        let currentSourceText = lines[index].sourceText
        guard Self.isCompatibleLiveSource(current: currentSourceText, requested: sourceText) else {
            if finalizesRequest, pendingTranslationSourceText == sourceText {
                pendingTranslationSourceText = ""
            }
            return
        }
        let translatedText = translation.text
        let organizedTranslatedText = organizeTranscript(translatedText, language: targetLanguage)
        let floatingTranslatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalizesRequest, pendingTranslationSourceText == sourceText {
            pendingTranslationSourceText = ""
        }
        stageTranscriptForSave(currentSourceText, translatedText: organizedTranslatedText)

        lines[index] = CaptionLine(
            id: line.id,
            sourceText: currentSourceText,
            translatedText: organizedTranslatedText,
            translatedSourceText: sourceText,
            translationsBySentence: lines[index].translationsBySentence.merging(translation.translationsBySentence) { $1 },
            createdAt: line.createdAt,
            isFinal: line.isFinal,
            revision: lines[index].revision + 1,
            usesLongSessionDisplay: usesLongSessionMode
        )

        updateFloatingTranslationPresentation(floatingTranslatedText, sourceText: sourceText)
        speakTranslatedDeltaIfNeeded(organizedTranslatedText, isFinal: finalizesRequest)
    }

    private func markTranslationUnavailable(_ message: String, for line: CaptionLine, matching sourceText: String) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else {
            statusMessage = message
            return
        }
        let currentSourceText = lines[index].sourceText
        guard Self.isCompatibleLiveSource(current: currentSourceText, requested: sourceText) else {
            if lines[index].translatedText == AppText.translating {
                let line = lines[index]
                lines[index] = CaptionLine(
                    id: line.id,
                    sourceText: line.sourceText,
                    translatedText: message,
                    translatedSourceText: line.sourceText,
                    translationsBySentence: line.translationsBySentence,
                    createdAt: line.createdAt,
                    isFinal: line.isFinal,
                    revision: line.revision + 1,
                    usesLongSessionDisplay: usesLongSessionMode
                )
            }
            statusMessage = message
            return
        }

        let existingTranslation = lines[index].translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingTranslation.isEmpty, existingTranslation != AppText.translating {
            if pendingTranslationSourceText == sourceText {
                pendingTranslationSourceText = ""
            }
            statusMessage = message
            return
        }

        if pendingTranslationSourceText == sourceText {
            pendingTranslationSourceText = ""
        }

        lines[index] = CaptionLine(
            id: line.id,
            sourceText: currentSourceText,
            translatedText: message,
            translatedSourceText: sourceText,
            translationsBySentence: lines[index].translationsBySentence,
            createdAt: line.createdAt,
            isFinal: line.isFinal,
            revision: lines[index].revision + 1,
            usesLongSessionDisplay: usesLongSessionMode
        )
        updateFloatingTranslationPresentation(message, sourceText: sourceText)
        statusMessage = message
    }

    private func updateFloatingTranslationPresentation(_ translatedText: String, sourceText: String) {
        let displaySourceText = isUsingOpenAIRealtime
            ? realtimeFloatingCaptionText(from: sourceText)
            : sourceText
        let displayTranslatedText = isUsingOpenAIRealtime
            ? realtimeFloatingCaptionText(from: translatedText)
            : translatedText

        guard !displaySourceText.isEmpty,
              !displayTranslatedText.isEmpty,
              displayTranslatedText != AppText.translating
        else {
            return
        }

        if shouldUpdateFloatingTranslationDisplay(for: displaySourceText) {
            if floatingDisplayTranslationText.isEmpty
                || canAdvanceFloatingPresentation()
                || isWholeTextPrefix(
                    normalizedTranscriptForComparison(floatingDisplayTranslationText),
                    of: normalizedTranscriptForComparison(displayTranslatedText)
                ) {
                floatingDisplayTranslationText = displayTranslatedText
                floatingDisplayTranslationSourceText = displaySourceText
            } else {
                floatingQueuedTranslationText = displayTranslatedText
                floatingQueuedTranslationSourceText = displaySourceText
                scheduleFloatingPresentationAdvance()
            }
            return
        }

        if shouldUpdateQueuedFloatingTranslationDisplay(for: displaySourceText) {
            floatingQueuedTranslationText = displayTranslatedText
            floatingQueuedTranslationSourceText = displaySourceText
            scheduleFloatingPresentationAdvance()
        }
    }

    private func promoteQueuedFloatingTranslationIfPossible() {
        guard !floatingQueuedTranslationText.isEmpty else { return }
        guard shouldUpdateFloatingTranslationDisplay(for: floatingQueuedTranslationSourceText) else {
            if floatingQueuedSourceText.isEmpty {
                floatingQueuedTranslationText = ""
                floatingQueuedTranslationSourceText = ""
            }
            return
        }

        floatingDisplayTranslationText = floatingQueuedTranslationText
        floatingDisplayTranslationSourceText = floatingQueuedTranslationSourceText
        floatingQueuedTranslationText = ""
        floatingQueuedTranslationSourceText = ""
    }

    private func shouldUpdateFloatingTranslationDisplay(for sourceText: String) -> Bool {
        translationSource(sourceText, matches: floatingPresentedSourceText)
    }

    private func shouldUpdateQueuedFloatingTranslationDisplay(for sourceText: String) -> Bool {
        translationSource(sourceText, matches: floatingQueuedSourceText)
    }

    private func translationSource(_ sourceText: String, matches displaySourceText: String) -> Bool {
        guard !displaySourceText.isEmpty else { return false }

        if sourceText == displaySourceText || isWholeTextPrefix(sourceText, of: displaySourceText) {
            return true
        }

        let normalizedSourceText = normalizedTranscriptForComparison(sourceText)
        let normalizedDisplaySourceText = normalizedTranscriptForComparison(displaySourceText)
        if normalizedSourceText == normalizedDisplaySourceText
            || isWholeTextPrefix(normalizedSourceText, of: normalizedDisplaySourceText) {
            return true
        }

        let organizedDisplaySourceText = organizeTranscript(
            displaySourceText,
            language: sourceLanguage,
            appliesLint: false
        )
        let normalizedOrganizedDisplaySourceText = normalizedTranscriptForComparison(organizedDisplaySourceText)
        return normalizedSourceText == normalizedOrganizedDisplaySourceText
            || isWholeTextPrefix(normalizedSourceText, of: normalizedOrganizedDisplaySourceText)
    }

    private func translationDirection(recognizedLanguage: LanguageOption) -> (source: LanguageOption, target: LanguageOption) {
        (isUsingAppleSourceAutoDetection ? recognizedLanguage : sourceLanguage, targetLanguage)
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speechOutput.speak(text, language: targetLanguage)
    }

    private func speakTranslatedDeltaIfNeeded(_ translatedText: String, isFinal: Bool = false) {
        guard isRunning, !isPaused, isDubbingEnabled else { return }
        guard !isUsingProviderRealtimeTranslation else { return }
        guard translatedText != AppText.translating else { return }

        guard let unspokenText = dubbingSpeechProgress.unspokenText(
            from: translatedText,
            languageID: targetLanguage.id,
            isFinal: isFinal
        ) else { return }

        speak(unspokenText)
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        for (leftCharacter, rightCharacter) in zip(lhs, rhs) {
            guard leftCharacter == rightCharacter else { break }
            length += 1
        }
        return length
    }

    private func resetDubbingProgress() {
        dubbingSpeechProgress.reset()
        stopSpeaking()
    }

    private func primeDubbingBaselineToCurrentTranslation() {
        dubbingSpeechProgress.prime(
            with: lines.last?.translatedText ?? "",
            languageID: targetLanguage.id
        )
    }

    private func stopSpeaking() {
        speechOutput.stop()
        openAIRealtimeAudioOutput.stop()
    }

    private func applyTranslatedVoiceVolume() {
        speechOutput.setVolume(translatedVoiceVolume)
        openAIRealtimeAudioOutput.setVolume(translatedVoiceVolume)
    }

    private static func clampedVolume(_ volume: Double, minimum: Double = 0) -> Double {
        min(max(volume, minimum), 1)
    }

    private func activeGeneration(
        for transcriber: LiveSpeechTranscriber,
        requiresRunning: Bool
    ) -> UInt64? {
        guard let generation = activeCaptionerGeneration else {
            // Presentation-policy tests and preview harnesses can intentionally
            // drive the delegate while manually owning `isRunning`. Production
            // starts always publish a captioner generation before setting it.
            guard requiresRunning,
                  isRunning,
                  pipelineLifecycle.phase == .stopped
            else {
                return nil
            }
            return pipelineLifecycle.generation
        }
        let isCurrentProducer = transcriber === self.transcriber
            || openAITranscriber.ownsDelegateProxy(transcriber)
        guard isCurrentProducer else { return nil }
        if requiresRunning {
            return pipelineLifecycle.acceptsSample(generation: generation) ? generation : nil
        }
        return pipelineLifecycle.isActive(generation: generation) ? generation : nil
    }

    private func activeGeneration(
        for service: GeminiLiveTranslationService,
        requiresRunning: Bool
    ) -> UInt64? {
        guard let generation = activeCaptionerGeneration else {
            guard requiresRunning,
                  isRunning,
                  pipelineLifecycle.phase == .stopped
            else {
                return nil
            }
            return pipelineLifecycle.generation
        }
        guard service === geminiLiveTranslator else {
            return nil
        }
        if requiresRunning {
            return pipelineLifecycle.acceptsSample(generation: generation) ? generation : nil
        }
        return pipelineLifecycle.isActive(generation: generation) ? generation : nil
    }

#if DEBUG
    func beginPermissionSuspendedStartForTesting() -> UInt64? {
        guard !isRunning, !isStarting else { return nil }

        invalidateCaptureStartAttempt()
        let configuration = currentStartConfiguration()
        let generation = pipelineLifecycle.beginStart(configuration: configuration)
        activeCaptureStartGeneration = generation
        isStarting = true
        statusMessage = AppText.checkingSpeechPermission
        captureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeCaptureStartAttempt(generation: generation) }
            do {
                await withCheckedContinuation { continuation in
                    self.permissionSuspendedStartContinuations[generation] = continuation
                }
                self.permissionSuspendedStartContinuations[generation] = nil
                try self.validatePipelineStart(
                    generation: generation,
                    configuration: configuration
                )
            } catch let error as CancellationError {
                await self.handleCancelledCaptureStart(
                    generation: generation,
                    error: error
                )
            } catch {
                guard self.pipelineLifecycle.fail(generation: generation) else { return }
                self.isStarting = false
                self.isRunning = false
                self.stopCaptioners()
                await self.stopCapture()
                self.statusMessage = AppText.startFailed(error.localizedDescription)
            }
        }
        return generation
    }

    func resumePermissionSuspendedStartForTesting() {
        guard permissionSuspendedStartContinuations.count == 1,
              let generation = permissionSuspendedStartContinuations.keys.first
        else {
            return
        }
        resumePermissionSuspendedStartForTesting(generation: generation)
    }

    func resumePermissionSuspendedStartForTesting(generation: UInt64) {
        let continuation = permissionSuspendedStartContinuations.removeValue(forKey: generation)
        continuation?.resume()
    }

    var isPermissionSuspendedStartForTesting: Bool {
        !permissionSuspendedStartContinuations.isEmpty
    }

    func isPermissionSuspendedStartForTesting(generation: UInt64) -> Bool {
        permissionSuspendedStartContinuations[generation] != nil
    }

    func simulatePipelineStartConfigurationErrorForTesting(
        generation: UInt64
    ) async {
        await handlePipelineStartError(
            .configurationChanged,
            generation: generation
        )
    }

    func activateLiveCallbackPipelineForTesting() -> (
        generation: UInt64,
        transcriber: LiveSpeechTranscriber,
        openAITranscriber: OpenAIRealtimeTranscriber
    ) {
        pipelineLifecycle.stop()
        stopCaptioners()

        let configuration = currentStartConfiguration()
        let generation = pipelineLifecycle.beginStart(configuration: configuration)
        transcriber = LiveSpeechTranscriber()
        transcriber.delegate = self
        openAITranscriber = OpenAIRealtimeTranscriber()
        openAITranscriber.delegate = self
        configureOpenAITerminalTranscriptDelivery(for: openAITranscriber)
        activeCaptionerGeneration = generation
        _ = pipelineLifecycle.markRunning(
            generation: generation,
            currentConfiguration: configuration
        )
        isStarting = false
        isRunning = true
        return (generation, transcriber, openAITranscriber)
    }

    func warmTranslationSessionForTesting() {
        warmTranslationSession()
    }

    var systemAudioCaptureForTesting: SystemAudioCapture {
        systemAudioCapture
    }

    func simulateSystemAudioStartFailureForTesting(_ error: Error) async -> UInt64? {
        guard !isRunning, !isStarting, audioInputSource == .systemAudio else {
            return nil
        }

        let configuration = currentStartConfiguration()
        let generation = pipelineLifecycle.beginStart(configuration: configuration)
        activeCaptureStartGeneration = generation
        isStarting = true
        statusMessage = AppText.startingCapture(for: .systemAudio)
        await handleCaptureStartFailure(
            error,
            generation: generation,
            configuration: configuration
        )
        completeCaptureStartAttempt(generation: generation)
        return generation
    }
#endif
}

extension TranslationSessionStore: SystemAudioCaptureDelegate {
    nonisolated func systemAudioCapture(
        _ capture: SystemAudioCapture,
        didOutput sampleBuffer: CMSampleBuffer,
        generation: UInt64
    ) {
        audioSamplePipelineRegistry.append(sampleBuffer, generation: generation)
    }

    nonisolated func systemAudioCapture(
        _ capture: SystemAudioCapture,
        didReceiveAudioSampleCount count: Int,
        level: Float?,
        generation: UInt64
    ) {
        Task { @MainActor in
            guard capture === systemAudioCapture,
                  pipelineLifecycle.acceptsSample(generation: generation)
            else {
                return
            }
            audioSampleCount = count
            latestAudioLevel = level
            guard !isPaused else {
                statusMessage = AppText.paused
                return
            }
            if isRunning, lines.isEmpty {
                statusMessage = audioStatusMessage(sampleCount: count, level: level)
            }
            if let level, level < -50 {
                scheduleTranscriptCleanup()
            }
        }
    }

    nonisolated func systemAudioCapture(
        _ capture: SystemAudioCapture,
        didFail error: Error,
        generation: UInt64
    ) {
        Task { @MainActor in
            guard capture === systemAudioCapture else { return }
            handleFatalPipelineError(error, generation: generation)
        }
    }

    nonisolated func systemAudioCaptureDidStopByUser(
        _ capture: SystemAudioCapture,
        generation: UInt64
    ) {
        Task { @MainActor in
            guard capture === systemAudioCapture else { return }
            handleSystemAudioCaptureStoppedByUser(generation: generation)
        }
    }

    private func audioStatusMessage(sampleCount: Int, level: Float?) -> String {
        guard let level else {
            return AppText.receivingAudioWaiting(sampleCount: sampleCount, source: audioInputSource)
        }

        let roundedLevel = Int(level.rounded())
        if level < -55 {
            return AppText.receivingSilentAudio(
                sampleCount: sampleCount,
                level: roundedLevel,
                source: audioInputSource
            )
        }

        return AppText.receivingAudioTranscribing(
            sampleCount: sampleCount,
            level: roundedLevel,
            source: audioInputSource
        )
    }
}

extension TranslationSessionStore: MicrophoneAudioCaptureDelegate {
    nonisolated func microphoneAudioCapture(
        _ capture: MicrophoneAudioCapture,
        didOutput sampleBuffer: CMSampleBuffer,
        generation: UInt64
    ) {
        audioSamplePipelineRegistry.append(sampleBuffer, generation: generation)
    }

    nonisolated func microphoneAudioCapture(
        _ capture: MicrophoneAudioCapture,
        didReceiveAudioSampleCount count: Int,
        level: Float?,
        generation: UInt64
    ) {
        Task { @MainActor in
            guard capture === microphoneAudioCapture,
                  pipelineLifecycle.acceptsSample(generation: generation)
            else {
                return
            }
            audioSampleCount = count
            latestAudioLevel = level
            guard !isPaused else {
                statusMessage = AppText.paused
                return
            }
            if isRunning, lines.isEmpty {
                statusMessage = audioStatusMessage(sampleCount: count, level: level)
            }
            if let level, level < -50 {
                scheduleTranscriptCleanup()
            }
        }
    }

    nonisolated func microphoneAudioCapture(
        _ capture: MicrophoneAudioCapture,
        didFail error: Error,
        generation: UInt64
    ) {
        Task { @MainActor in
            guard capture === microphoneAudioCapture else { return }
            handleFatalPipelineError(error, generation: generation)
        }
    }
}

extension TranslationSessionStore: LiveSpeechTranscriberDelegate {
    nonisolated func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        Task { @MainActor in
            guard activeGeneration(for: transcriber, requiresRunning: true) != nil else {
                return
            }
            enqueueRecognizedCaption(
                sourceText: text,
                recognizedLanguage: language,
                confidence: confidence
            )
        }
    }

    nonisolated func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didTranslate text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        Task { @MainActor in
            guard activeGeneration(for: transcriber, requiresRunning: true) != nil else {
                return
            }
            appendRealtimeTranslationOnly(text)
        }
    }

    nonisolated func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognizeSourceTranscript text: String,
        confidence: Double
    ) {
        Task { @MainActor in
            guard activeGeneration(for: transcriber, requiresRunning: true) != nil else {
                return
            }
            updateRealtimeTranslationSourceTranscript(text)
        }
    }

    nonisolated func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    ) {
        Task { @MainActor in
            guard activeGeneration(for: transcriber, requiresRunning: true) != nil,
                  isRunning,
                  !isPaused,
                  isDubbingEnabled,
                  openAITranslationModel.usesRealtimeAudioTranslation
            else {
                return
            }

            openAIRealtimeAudioOutput.playPCM16Base64(audio, sampleRate: sampleRate)
        }
    }

    nonisolated func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {
        Task { @MainActor in
            guard let generation = activeGeneration(
                for: transcriber,
                requiresRunning: false
            ) else {
                return
            }
            handleFatalPipelineError(error, generation: generation)
        }
    }
}

extension TranslationSessionStore: GeminiLiveTranslationServiceDelegate {
    nonisolated func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveInputTranscript text: String,
        languageCode _: String?
    ) {
        Task { @MainActor in
            guard activeGeneration(for: service, requiresRunning: true) != nil else {
                return
            }
            updateGeminiLiveInputTranscript(text)
        }
    }

    nonisolated func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didReceiveOutputTranscript text: String,
        languageCode _: String?
    ) {
        Task { @MainActor in
            guard activeGeneration(for: service, requiresRunning: true) != nil else {
                return
            }
            updateGeminiLiveOutputTranscript(text)
        }
    }

    nonisolated func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didOutputAudioPCM16Base64 audio: String,
        sampleRate: Double
    ) {
        Task { @MainActor in
            guard activeGeneration(for: service, requiresRunning: true) != nil,
                  isRunning,
                  !isPaused,
                  isDubbingEnabled,
                  isUsingGeminiTranslation
            else {
                return
            }

            openAIRealtimeAudioOutput.playPCM16Base64(audio, sampleRate: sampleRate)
        }
    }

    nonisolated func geminiLiveTranslationServiceDidInterruptOutputAudio(
        _ service: GeminiLiveTranslationService
    ) {
        Task { @MainActor in
            guard activeGeneration(for: service, requiresRunning: true) != nil else {
                return
            }
            openAIRealtimeAudioOutput.stop()
        }
    }

    nonisolated func geminiLiveTranslationService(
        _ service: GeminiLiveTranslationService,
        didFail error: Error
    ) {
        Task { @MainActor in
            guard let generation = activeGeneration(
                for: service,
                requiresRunning: false
            ) else {
                return
            }
            handleFatalPipelineError(error, generation: generation)
        }
    }
}
