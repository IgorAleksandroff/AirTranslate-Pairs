import SwiftUI

struct SettingsView: View {
    @Bindable var session: TranslationSessionStore
    @SceneStorage("AirTranslate.SettingsView.selectedCategory") private var selectedCategoryID = SettingsCategory.general.rawValue
    @State private var openAIAPIKey = ""
    @State private var openAIKeyFeedback: APIKeyFeedback?
    @State private var isConfirmingOpenAIKeyRemoval = false
    @State private var geminiAPIKey = ""
    @State private var geminiKeyFeedback: APIKeyFeedback?
    @State private var isConfirmingGeminiKeyRemoval = false

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selectedCategory)
                .frame(width: 260)

            Divider()
                .opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsPageHeader(category: selectedCategory.wrappedValue)

                    selectedContent
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 44)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: applyRequestedSettingsCategory)
        .onChange(of: session.requestedSettingsCategoryID) { _, _ in
            applyRequestedSettingsCategory()
        }
    }

    private var selectedCategory: Binding<SettingsCategory> {
        Binding {
            SettingsCategory(rawValue: selectedCategoryID) ?? .general
        } set: { category in
            selectedCategoryID = category.rawValue
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedCategory.wrappedValue {
        case .general:
            generalSettings
        case .apiKeys:
            apiKeySettings
        case .audio:
            audioSettings
        case .output:
            outputSettings
        case .transcript:
            transcriptSettings
        case .floatingCaptions:
            floatingCaptionSettings
        case .assets:
            assetSettings
        case .permissions:
            permissionSettings
        case .info:
            infoSettings
        }
    }

    private var generalSettings: some View {
        SettingsGroup(title: SettingsCopy.modeSettings) {
            if isSessionConfigurationLocked {
                SettingsNoticeRow(text: SettingsCopy.captureRunningDisabledReason, systemImage: "pause.circle")
            }

            SettingsControlRow(
                title: SettingsCopy.processingEngine,
                detail: SettingsCopy.processingEngineDetail,
                systemImage: "switch.2"
            ) {
                Picker(SettingsCopy.processingEngine, selection: processingModeSelection) {
                    ForEach(SettingsProcessingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                .disabled(isSessionConfigurationLocked)
            }

            if (processingModeSelection.wrappedValue == .openAI || processingModeSelection.wrappedValue == .gptTranscription), !session.hasOpenAIAPIKey {
                SettingsNoticeActionRow(
                    text: AppText.openAIAPIKeyRequiredForGPTMode,
                    systemImage: "key",
                    actionTitle: SettingsCopy.enterOpenAIAPIKey
                ) {
                    selectedCategory.wrappedValue = .apiKeys
                }
            }

            if processingModeSelection.wrappedValue == .openAI {
                SettingsControlRow(
                    title: SettingsCopy.gptRealtimeModel,
                    detail: SettingsCopy.gptRealtimeModelDetail,
                    systemImage: "waveform.badge.magnifyingglass"
                ) {
                    Picker(SettingsCopy.gptRealtimeModel, selection: openAIRealtimeModelSelection) {
                        ForEach(OpenAIRealtimeTranslationModel.liveTranslationCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                    .disabled(isSessionConfigurationLocked)
                    .accessibilityLabel(SettingsCopy.gptRealtimeModel)
                }

                SettingsNoticeRow(text: SettingsCopy.openAIVoiceAgentModelNotice, systemImage: "info.circle")
            }

            if processingModeSelection.wrappedValue == .gptTranscription {
                SettingsControlRow(
                    title: AppText.gptTranscriptionModel,
                    detail: AppText.gptTranscriptionModeDescription,
                    systemImage: "waveform.badge.mic"
                ) {
                    Text(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                SettingsNoticeRow(text: AppText.gptTranscriptionSourceOnly, systemImage: "text.quote")
            }

            if processingModeSelection.wrappedValue == .gemini, !session.hasGeminiAPIKey {
                SettingsNoticeActionRow(
                    text: AppText.geminiAPIKeyMissing,
                    systemImage: "key",
                    actionTitle: SettingsCopy.enterGeminiAPIKey
                ) {
                    selectedCategory.wrappedValue = .apiKeys
                }
            }

            SettingsControlRow(
                title: SettingsCopy.sessionWorkflow,
                detail: SettingsCopy.sessionWorkflowDetail,
                systemImage: "captions.bubble"
            ) {
                Picker(AppText.model, selection: modelSelection) {
                    ForEach(IntelligenceModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(isSessionConfigurationLocked || session.isUsingProviderRealtimeTranslation || session.isUsingGPTTranscriptionMode)
            }

            if session.isUsingProviderRealtimeTranslation {
                SettingsNoticeRow(text: SettingsCopy.realtimeTranslationOutputOnly, systemImage: "waveform")
            } else if session.isUsingGPTTranscriptionMode {
                SettingsNoticeRow(text: AppText.gptTranscriptionSourceOnly, systemImage: "text.quote")
            }

            SettingsValueRow(
                title: AppText.languages,
                detail: SettingsCopy.languagePairDetail,
                systemImage: "globe",
                value: session.languageSummary
            )

            SettingsValueRow(
                title: AppText.autoDetectInput,
                detail: SettingsCopy.autoDetectDetail,
                systemImage: "sparkles",
                value: AppText.localized(
                    english: "Coming soon",
                    korean: "지원 예정",
                    japanese: "近日対応",
                    chineseSimplified: "即将支持"
                )
            )
        }
    }

    private var apiSettings: some View {
        SettingsGroup(title: AppText.openAIAPIKey) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(session.hasOpenAIAPIKey ? Color.green : Color.secondary)
                        .frame(width: 24)

                    SecureField(AppText.openAIAPIKeyPlaceholder, text: $openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveOpenAIAPIKey)
                        .accessibilityLabel(AppText.openAIAPIKey)

                    Button {
                        saveOpenAIAPIKey()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(AppText.saveOpenAIAPIKey)
                    .accessibilityLabel(AppText.saveOpenAIAPIKey)

                    Button {
                        isConfirmingOpenAIKeyRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!session.hasOpenAIAPIKey)
                    .help(AppText.removeOpenAIAPIKey)
                    .accessibilityLabel(AppText.removeOpenAIAPIKey)
                    .confirmationDialog(
                        AppText.localized(
                            english: "Remove the saved OpenAI API key from Keychain?",
                            korean: "Keychain에 저장된 OpenAI API 키를 삭제할까요?",
                            japanese: "Keychainに保存されたOpenAI APIキーを削除しますか？",
                            chineseSimplified: "要从 Keychain 中删除已保存的 OpenAI API key 吗？"
                        ),
                        isPresented: $isConfirmingOpenAIKeyRemoval
                    ) {
                        Button(AppText.removeOpenAIAPIKey, role: .destructive) {
                            removeOpenAIAPIKey()
                        }
                        Button(AppText.cancel, role: .cancel) {}
                    }
                }

                APIKeyStatusRow(
                    feedback: $openAIKeyFeedback,
                    fallback: APIKeyFeedback(
                        kind: session.hasOpenAIAPIKey ? .success : .warning,
                        message: session.hasOpenAIAPIKey ? AppText.openAIAPIKeyConfigured : AppText.openAIAPIKeyNotConfigured
                    )
                )

                Text(AppText.openAIAPIKeyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)

            SettingsControlRow(
                title: SettingsCopy.currentGPTRealtimeModel,
                detail: SettingsCopy.currentGPTRealtimeModelDetail,
                systemImage: "waveform"
            ) {
                Text(session.openAITranslationModel.isEnabled ? session.openAITranslationModel.title : OpenAIRealtimeTranslationModel.gptRealtimeTranslate.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            SettingsValueRow(
                title: SettingsCopy.openAIVoiceAgentModels,
                detail: SettingsCopy.openAIVoiceAgentModelsDetail,
                systemImage: "person.wave.2",
                value: OpenAIRealtimeTranslationModel.voiceAgentCases.map(\.rawValue).joined(separator: ", ")
            )
        }
    }

    private var apiKeySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            apiSettings
            geminiSettings
        }
    }

    private var audioSettings: some View {
        SettingsGroup(title: AppText.audioInputSource) {
            if isSessionConfigurationLocked {
                SettingsNoticeRow(text: SettingsCopy.captureRunningDisabledReason, systemImage: "pause.circle")
            }

            SettingsControlRow(
                title: AppText.audioInputSource,
                detail: SettingsCopy.audioInputDetail,
                systemImage: "waveform.badge.magnifyingglass"
            ) {
                Picker(AppText.audioInputSource, selection: lockedSessionConfigurationBinding($session.audioInputSource)) {
                    ForEach(AudioInputSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(isSessionConfigurationLocked)
            }

            SettingsControlRow(
                title: AppText.microphoneInputDevice,
                detail: SettingsCopy.microphoneDeviceDetail,
                systemImage: "mic"
            ) {
                Picker(AppText.microphoneInputDevice, selection: lockedSessionConfigurationBinding($session.selectedMicrophoneInputDeviceID)) {
                    ForEach(session.microphoneInputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(isSessionConfigurationLocked || session.audioInputSource != .microphone)
            }
        }
    }

    private var outputSettings: some View {
        SettingsGroup(title: AppText.output) {
            if isSessionConfigurationLocked {
                SettingsNoticeRow(text: SettingsCopy.captureRunningDisabledReason, systemImage: "pause.circle")
            }

            if session.isUsingGPTTranscriptionMode {
                SettingsValueRow(
                    title: AppText.outputMode,
                    detail: AppText.gptTranscriptionModeDescription,
                    systemImage: "rectangle.split.2x1",
                    value: AppText.gptTranscriptionSourceOnly
                )
            } else {
                SettingsControlRow(
                    title: AppText.outputMode,
                    detail: SettingsCopy.outputModeDetail,
                    systemImage: "rectangle.split.2x1"
                ) {
                    Picker(AppText.outputMode, selection: liveOutputModeBinding) {
                        ForEach(LiveOutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(isSessionConfigurationLocked || session.isUsingProviderRealtimeTranslation)
                }
            }

            if session.isUsingProviderRealtimeTranslation {
                SettingsNoticeRow(text: SettingsCopy.realtimeTranslationOutputOnly, systemImage: "waveform")
            }

            if !session.isUsingGPTTranscriptionMode {
                SettingsToggleRow(
                    title: AppText.voiceOutput,
                    detail: SettingsCopy.dubbingDetail,
                    systemImage: "speaker.wave.2",
                    isOn: lockedSessionConfigurationBinding($session.isDubbingEnabled)
                )
                .disabled(isSessionConfigurationLocked)

                SettingsControlRow(
                    title: SettingsCopy.liveTranslationVolume,
                    detail: SettingsCopy.liveTranslationVolumeDetail,
                    systemImage: "speaker.wave.3"
                ) {
                    SettingsVolumeSlider(
                        value: lockedSessionConfigurationBinding($session.translatedVoiceVolume),
                        range: 0...1
                    )
                }
                .disabled(isSessionConfigurationLocked)
            }
        }
    }

    private var transcriptSettings: some View {
        SettingsGroup(title: AppText.transcript) {
            if isSessionConfigurationLocked {
                SettingsNoticeRow(text: SettingsCopy.captureRunningDisabledReason, systemImage: "pause.circle")
            }

            if session.isUsingOpenAIRealtime {
                SettingsNoticeRow(text: SettingsCopy.openAIRealtimeDisabledReason, systemImage: "info.circle")
            }

            SettingsControlRow(
                title: AppText.sessionLength,
                detail: session.sessionDurationMode.detail,
                systemImage: "timer"
            ) {
                Picker(AppText.sessionLength, selection: lockedSessionConfigurationBinding($session.sessionDurationMode)) {
                    ForEach(SessionDurationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(isSessionConfigurationLocked)
            }

            SettingsControlRow(
                title: AppText.paragraphBreakSilenceInterval,
                detail: AppText.paragraphBreakSilenceDescription,
                systemImage: "text.append"
            ) {
                Stepper(
                    AppText.seconds(session.paragraphBreakSilenceInterval),
                    value: lockedSessionConfigurationBinding($session.paragraphBreakSilenceInterval),
                    in: 1...15,
                    step: 0.5
                )
                .frame(width: 104)
                .disabled(isSessionConfigurationLocked)
            }

            SettingsToggleRow(
                title: AppText.transcriptLint,
                detail: AppText.transcriptLintDescription,
                systemImage: "wand.and.sparkles",
                isOn: lockedSessionConfigurationBinding($session.isTranscriptLintEnabled)
            )
            .disabled(isSessionConfigurationLocked || session.isUsingOpenAIRealtime)

            SettingsControlRow(
                title: AppText.savedTranscriptContent,
                detail: AppText.autoSaveDescription,
                systemImage: "archivebox"
            ) {
                Picker(AppText.savedTranscriptContent, selection: lockedSessionConfigurationBinding($session.savedTranscriptContentMode)) {
                    ForEach(SavedTranscriptContentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(isSessionConfigurationLocked)
            }
        }
    }

    private var floatingCaptionSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            FloatingCaptionPreview()

            SettingsGroup(title: SettingsCopy.displaySettings) {
                SettingsControlRow(
                    title: SettingsCopy.displayContent,
                    detail: AppText.floatingDisplayDescription,
                    systemImage: "captions.bubble"
                ) {
                    Picker(AppText.floatingDisplay, selection: $session.floatingCaptionDisplayMode) {
                        ForEach(session.availableFloatingCaptionDisplayModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .focusEffectDisabled()
                    .frame(width: 168)
                }

                SettingsControlRow(
                    title: AppText.floatingTextSize,
                    detail: SettingsCopy.floatingTextSizeDetail,
                    systemImage: "textformat.size"
                ) {
                    Picker(AppText.floatingTextSize, selection: $session.floatingCaptionTextSize) {
                        ForEach(FloatingCaptionTextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .focusEffectDisabled()
                    .frame(width: 232)
                }

                SettingsControlRow(
                    title: AppText.floatingLineCount,
                    detail: SettingsCopy.floatingLineCountDetail,
                    systemImage: "line.3.horizontal"
                ) {
                    Picker(AppText.floatingLineCount, selection: $session.floatingCaptionLineCount) {
                        ForEach(FloatingCaptionLineCount.allCases) { lineCount in
                            Text(lineCount.title).tag(lineCount)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .focusEffectDisabled()
                    .frame(width: 252)
                }

                SettingsToggleRow(
                    title: SettingsCopy.keepOnTop,
                    detail: SettingsCopy.keepOnTopDetail,
                    systemImage: "pin",
                    isOn: $session.keepsFloatingCaptionAboveOtherWindows
                )
            }

            Label(SettingsCopy.floatingFooter, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var assetSettings: some View {
        SettingsGroup(title: AppText.requiredAssets) {
            SettingsAssetAvailabilityRow(
                title: AppText.speechLanguagePack,
                availability: session.modelAvailability(for: .appleSpeechOnly)
            ) {
                session.downloadModelAssets(for: .appleSpeechOnly)
            }

            SettingsAssetAvailabilityRow(
                title: AppText.translationLanguagePack,
                availability: session.modelAvailability(for: .appleOnDevice)
            ) {
                session.downloadModelAssets(for: .appleOnDevice)
            }
        }
    }

    private var permissionSettings: some View {
        SettingsGroup(title: AppText.permissions) {
            SettingsValueRow(
                title: AppText.permissions,
                detail: AppText.permissionsHelp,
                systemImage: "hand.raised",
                value: SettingsCopy.required
            )

            HStack {
                Spacer()

                Button {
                    session.openPrivacySettings()
                } label: {
                    Label(AppText.openPrivacySettings, systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var infoSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: SettingsCopy.aboutAirTranslate) {
                SettingsValueRow(
                    title: AppText.appName,
                    detail: AppText.appTagline,
                    systemImage: "waveform.and.magnifyingglass",
                    value: SettingsCopy.localFirst
                )

                SettingsValueRow(
                    title: SettingsCopy.privacy,
                    detail: SettingsCopy.privacyDetail,
                    systemImage: "lock.shield",
                    value: SettingsCopy.keychain
                )
            }

        }
    }

    private var geminiSettings: some View {
        SettingsGroup(title: AppText.geminiModels) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(session.hasGeminiAPIKey ? Color.green : Color.secondary)
                        .frame(width: 24)

                    SecureField(AppText.geminiAPIKeyPlaceholder, text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveGeminiAPIKey)
                        .accessibilityLabel(AppText.geminiAPIKey)

                    Button {
                        saveGeminiAPIKey()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .disabled(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(AppText.saveGeminiAPIKey)
                    .accessibilityLabel(AppText.saveGeminiAPIKey)

                    Button {
                        isConfirmingGeminiKeyRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!session.hasGeminiAPIKey)
                    .help(AppText.removeGeminiAPIKey)
                    .accessibilityLabel(AppText.removeGeminiAPIKey)
                    .confirmationDialog(
                        AppText.localized(
                            english: "Remove the saved Gemini API key from Keychain?",
                            korean: "Keychain에 저장된 Gemini API 키를 삭제할까요?",
                            japanese: "Keychainに保存されたGemini APIキーを削除しますか？",
                            chineseSimplified: "要从 Keychain 中删除已保存的 Gemini API key 吗？"
                        ),
                        isPresented: $isConfirmingGeminiKeyRemoval
                    ) {
                        Button(AppText.removeGeminiAPIKey, role: .destructive) {
                            removeGeminiAPIKey()
                        }
                        Button(AppText.cancel, role: .cancel) {}
                    }
                }

                APIKeyStatusRow(
                    feedback: $geminiKeyFeedback,
                    fallback: APIKeyFeedback(
                        kind: session.hasGeminiAPIKey ? .success : .warning,
                        message: session.hasGeminiAPIKey ? AppText.geminiAPIKeyConfigured : AppText.geminiAPIKeyNotConfigured
                    )
                )

                Text(AppText.geminiAPIKeyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)

            SettingsControlRow(
                title: AppText.geminiTranslationModel,
                detail: SettingsCopy.geminiTranslationDetail,
                systemImage: "sparkles"
            ) {
                Text(GeminiTranslationModel.gemini35LiveTranslate.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selectedProcessingMode == .gemini ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    private var selectedProcessingMode: SettingsProcessingMode {
        if session.isUsingGPTTranscriptionMode {
            return .gptTranscription
        }
        if session.isUsingOpenAIRealtime {
            return .openAI
        }
        if session.isUsingGeminiTranslation {
            return .gemini
        }
        return .apple
    }

    private var isSessionConfigurationLocked: Bool {
        session.isRunning || session.isStarting
    }

    private func lockedSessionConfigurationBinding<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                guard !isSessionConfigurationLocked else { return }
                binding.wrappedValue = value
            }
        )
    }

    private var processingModeSelection: Binding<SettingsProcessingMode> {
        Binding {
            selectedProcessingMode
        } set: { mode in
            guard !isSessionConfigurationLocked else { return }
            switch mode {
            case .apple:
                session.useAppleDefaultMode()
            case .openAI:
                session.useGPTRealtimeMode()
            case .gptTranscription:
                session.useGPTTranscriptionMode()
            case .gemini:
                session.useGeminiTranslationMode()
            }
        }
    }

    private var liveOutputModeBinding: Binding<LiveOutputMode> {
        Binding {
            session.liveOutputMode
        } set: { mode in
            guard !isSessionConfigurationLocked else { return }
            session.useLiveOutputMode(mode)
        }
    }

    private var modelSelection: Binding<IntelligenceModel> {
        Binding {
            session.selectedModel
        } set: { model in
            guard !isSessionConfigurationLocked else { return }
            switch model {
            case .appleSpeechOnly:
                session.useTranscribeOnlyMode()
            case .appleSystem, .appleOnDevice:
                session.useTranslationMode()
            }
        }
    }

    private var openAIRealtimeModelSelection: Binding<OpenAIRealtimeTranslationModel> {
        Binding {
            session.openAITranslationModel.isSupportedLiveTranslationModel ? session.openAITranslationModel : .gptRealtimeTranslate
        } set: { model in
            guard !isSessionConfigurationLocked else { return }
            session.useGPTRealtimeMode(model: model)
        }
    }

    // Key operations run against the Keychain store directly so failures surface as
    // typed errors; the follow-up session call syncs published state and availability.
    private func saveOpenAIAPIKey() {
        let trimmedKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            openAIKeyFeedback = APIKeyFeedback(kind: .error, message: AppText.openAIAPIKeyEmpty)
            return
        }

        do {
            try OpenAIAPIKeyStore.saveAPIKey(trimmedKey)
        } catch {
            openAIKeyFeedback = APIKeyFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        session.saveOpenAIAPIKey(trimmedKey)
        openAIKeyFeedback = APIKeyFeedback(kind: .success, message: AppText.openAIAPIKeySaved)
        openAIAPIKey = ""
    }

    private func removeOpenAIAPIKey() {
        do {
            try OpenAIAPIKeyStore.deleteAPIKey()
        } catch {
            openAIKeyFeedback = APIKeyFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        session.removeOpenAIAPIKey()
        openAIKeyFeedback = APIKeyFeedback(kind: .warning, message: AppText.openAIAPIKeyRemoved)
        openAIAPIKey = ""
    }

    private func saveGeminiAPIKey() {
        let trimmedKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            geminiKeyFeedback = APIKeyFeedback(kind: .error, message: AppText.geminiAPIKeyEmpty)
            return
        }

        do {
            try GeminiAPIKeyStore.saveAPIKey(trimmedKey)
        } catch {
            geminiKeyFeedback = APIKeyFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        session.saveGeminiAPIKey(trimmedKey)
        geminiKeyFeedback = APIKeyFeedback(kind: .success, message: AppText.geminiAPIKeySaved)
        geminiAPIKey = ""
    }

    private func removeGeminiAPIKey() {
        do {
            try GeminiAPIKeyStore.deleteAPIKey()
        } catch {
            geminiKeyFeedback = APIKeyFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        session.removeGeminiAPIKey()
        geminiKeyFeedback = APIKeyFeedback(kind: .warning, message: AppText.geminiAPIKeyRemoved)
        geminiAPIKey = ""
    }

    private func applyRequestedSettingsCategory() {
        guard let requestedCategoryID = session.requestedSettingsCategoryID,
              let category = SettingsCategory(rawValue: requestedCategoryID)
        else { return }

        selectedCategory.wrappedValue = category
        session.requestedSettingsCategoryID = nil
    }
}

private struct APIKeyFeedback: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String
    private let token = UUID()

    var color: Color {
        switch kind {
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

private struct APIKeyStatusRow: View {
    @Binding var feedback: APIKeyFeedback?
    let fallback: APIKeyFeedback

    private var current: APIKeyFeedback {
        feedback ?? fallback
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(current.color)
                .frame(width: 7, height: 7)

            Text(current.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(current.color)
        }
        .padding(.leading, 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(current.message)
        .task(id: feedback) {
            guard feedback != nil else { return }
            guard (try? await Task.sleep(for: .seconds(6))) != nil else { return }
            feedback = nil
        }
    }
}

private enum SettingsProcessingMode: String, CaseIterable, Identifiable {
    case apple
    case openAI
    case gptTranscription
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            "Apple"
        case .openAI:
            AppText.localized(
                english: "GPT Translate",
                korean: "GPT 번역",
                japanese: "GPT翻訳",
                chineseSimplified: "GPT 翻译"
            )
        case .gptTranscription:
            AppText.localized(
                english: "GPT Transcribe",
                korean: "GPT 전사",
                japanese: "GPT文字起こし",
                chineseSimplified: "GPT 转写"
            )
        case .gemini:
            "Gemini"
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case apiKeys
    case audio
    case output
    case transcript
    case floatingCaptions
    case assets
    case permissions
    case info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            SettingsCopy.general
        case .apiKeys:
            SettingsCopy.apiKeys
        case .audio:
            SettingsCopy.audio
        case .output:
            AppText.output
        case .transcript:
            AppText.transcript
        case .floatingCaptions:
            AppText.floatingCaptions
        case .assets:
            SettingsCopy.assets
        case .permissions:
            AppText.permissions
        case .info:
            SettingsCopy.info
        }
    }

    var detail: String {
        switch self {
        case .general:
            SettingsCopy.generalDetail
        case .apiKeys:
            SettingsCopy.apiKeysDetail
        case .audio:
            SettingsCopy.audioDetail
        case .output:
            SettingsCopy.outputDetail
        case .transcript:
            SettingsCopy.transcriptDetail
        case .floatingCaptions:
            SettingsCopy.floatingDetail
        case .assets:
            SettingsCopy.assetsDetail
        case .permissions:
            SettingsCopy.permissionsDetail
        case .info:
            SettingsCopy.infoDetail
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "slider.horizontal.3"
        case .apiKeys:
            "key.fill"
        case .audio:
            "mic"
        case .output:
            "waveform"
        case .transcript:
            "doc.text"
        case .floatingCaptions:
            "captions.bubble"
        case .assets:
            "cube.box"
        case .permissions:
            "shield.lefthalf.filled"
        case .info:
            "info.circle"
        }
    }
}

private enum SettingsCopy {
    static let general = AppText.localized(english: "General", korean: "일반")
    static let apiKeys = AppText.localized(english: "API Keys", korean: "API 키")
    static let audio = AppText.localized(english: "Audio", korean: "오디오")
    static let assets = AppText.localized(english: "Assets", korean: "자산")
    static let info = AppText.localized(english: "Info", korean: "정보")
    static let generalDetail = AppText.localized(
        english: "Set the default translation mode and language behavior.",
        korean: "기본 번역 방식과 언어 동작을 설정합니다."
    )
    static let apiKeysDetail = AppText.localized(
        english: "Save provider keys for OpenAI and Gemini Live modes.",
        korean: "OpenAI와 Gemini Live 모드에 사용할 키를 저장합니다."
    )
    static let audioDetail = AppText.localized(
        english: "Choose where AirTranslate listens from.",
        korean: "AirTranslate가 어떤 오디오를 들을지 선택합니다."
    )
    static let outputDetail = AppText.localized(
        english: "Control what appears and whether translated speech plays.",
        korean: "표시할 결과와 번역 음성 출력을 조정합니다."
    )
    static let transcriptDetail = AppText.localized(
        english: "Tune paragraphing, long sessions, and saved transcript behavior.",
        korean: "문단 나누기, 긴 세션, 저장 기록 동작을 조정합니다."
    )
    static let floatingDetail = AppText.localized(
        english: "Configure the detachable floating caption window.",
        korean: "별도 창으로 표시되는 플로팅 자막을 설정합니다."
    )
    static let assetsDetail = AppText.localized(
        english: "Check local speech and translation assets.",
        korean: "로컬 음성 인식 및 번역 자산을 확인합니다."
    )
    static let permissionsDetail = AppText.localized(
        english: "Open macOS privacy controls required for capture.",
        korean: "캡처에 필요한 macOS 개인정보 보호 권한을 엽니다."
    )
    static let infoDetail = AppText.localized(
        english: "Review local-first behavior and privacy notes.",
        korean: "로컬 우선 동작과 개인정보 안내를 확인합니다."
    )
    static let modeSettings = AppText.localized(english: "Mode Settings", korean: "모드 설정")
    static let processingEngine = AppText.localized(english: "Processing Mode", korean: "처리 방식")
    static let processingEngineDetail = AppText.localized(
        english: "Choose exactly one active engine: local Apple mode, GPT Realtime, GPT Transcription, or Gemini Live Translate.",
        korean: "Apple 기본 모드, GPT Realtime, GPT 전사, Gemini 실시간 번역 중 하나만 활성화합니다.",
        japanese: "Appleローカルモード、GPT Realtime、GPT文字起こし、Gemini Live翻訳から1つだけ有効にします。",
        chineseSimplified: "仅启用一种处理方式：Apple 本地模式、GPT Realtime、GPT 转写或 Gemini 实时翻译。"
    )
    static let enterOpenAIAPIKey = AppText.localized(
        english: "Enter OpenAI API key",
        korean: "OpenAI API 키 입력",
        japanese: "OpenAI APIキーを入力",
        chineseSimplified: "输入 OpenAI API key"
    )
    static let enterGeminiAPIKey = AppText.localized(
        english: "Enter Gemini API key",
        korean: "Gemini API 키 입력",
        japanese: "Gemini APIキーを入力",
        chineseSimplified: "输入 Gemini API key"
    )
    static let sessionWorkflow = AppText.localized(english: "Session Workflow", korean: "세션 처리 방식")
    static let sessionWorkflowDetail = AppText.localized(
        english: "Apple mode can switch between translation and source-only transcription.",
        korean: "Apple 모드에서 번역 자막 또는 원문 전사만 중에서 선택합니다."
    )
    static let realtimeTranslationOutputOnly = AppText.localized(
        english: "API live translation modes are translation-only. Choose Apple or GPT Transcription for source-only captions.",
        korean: "API 실시간 번역 모드는 번역 전용입니다. 원문 자막만 필요하면 Apple 또는 GPT 전사를 선택하세요.",
        japanese: "APIライブ翻訳モードは翻訳専用です。原文字幕のみの場合はAppleまたはGPT文字起こしを選択してください。",
        chineseSimplified: "API 实时翻译模式仅用于翻译。若只需原文字幕，请选择 Apple 或 GPT 转写。"
    )
    static let languagePairDetail = AppText.localized(
        english: "Language pair is changed from the quick settings sidebar.",
        korean: "언어 조합은 빠른 설정 사이드바에서 변경합니다."
    )
    static let autoDetectDetail = AppText.localized(
        english: "Temporarily unavailable while automatic detection is improved.",
        korean: "자동 감지 개선 중이라 잠시 비활성화되어 있습니다."
    )
    static let captureRunningDisabledReason = AppText.localized(
        english: "Stop capture before changing this setting.",
        korean: "이 설정을 바꾸려면 먼저 캡처를 중지하세요."
    )
    static let openAIRealtimeDisabledReason = AppText.localized(
        english: "Transcript cleanup is disabled while OpenAI Realtime is active.",
        korean: "OpenAI Realtime이 켜져 있을 때는 기록 다듬기를 사용할 수 없습니다."
    )
    static let gptRealtimeModel = AppText.localized(
        english: "GPT Realtime Model",
        korean: "GPT Realtime 모델"
    )
    static let gptRealtimeModelDetail = AppText.localized(
        english: "Choose the translation-endpoint model used by GPT mode.",
        korean: "GPT 모드에서 사용할 번역 엔드포인트 모델을 선택합니다."
    )
    static let openAIVoiceAgentModelNotice = AppText.localized(
        english: "gpt-realtime-2.1 and 2.1-mini are voice-agent models for /v1/realtime. AirTranslate live interpretation uses gpt-realtime-translate on the translation endpoint.",
        korean: "gpt-realtime-2.1과 2.1-mini는 /v1/realtime용 보이스 에이전트 모델입니다. AirTranslate 실시간 통역은 번역 전용 엔드포인트의 gpt-realtime-translate를 사용합니다."
    )
    static let currentGPTRealtimeModel = AppText.localized(
        english: "Current GPT Realtime model",
        korean: "현재 GPT Realtime 모델"
    )
    static let currentGPTRealtimeModelDetail = AppText.localized(
        english: "Change this from General after selecting GPT Realtime.",
        korean: "GPT Realtime을 선택한 뒤 일반 설정에서 변경합니다."
    )
    static let openAIVoiceAgentModels = AppText.localized(
        english: "Voice-agent models",
        korean: "보이스 에이전트 모델"
    )
    static let openAIVoiceAgentModelsDetail = AppText.localized(
        english: "Documented OpenAI Realtime voice-agent models. They are not used for AirTranslate's live interpreter path yet.",
        korean: "공식 문서에 등록된 OpenAI Realtime 보이스 에이전트 모델입니다. 아직 AirTranslate의 실시간 통역 경로에는 사용하지 않습니다."
    )
    static let geminiTranslationDetail = AppText.localized(
        english: "Use Gemini 3.5 Live Translate for direct audio-to-live-translation sessions.",
        korean: "Gemini 3.5 Live Translate로 오디오를 직접 실시간 번역합니다."
    )
    static let audioInputDetail = AppText.localized(
        english: "Mac audio captures system playback. Microphone captures the selected input device.",
        korean: "PC 소리는 시스템 재생음을, 마이크는 선택한 입력 장치를 캡처합니다."
    )
    static let microphoneDeviceDetail = AppText.localized(
        english: "Available only when microphone input is selected.",
        korean: "마이크 입력을 선택했을 때 사용할 수 있습니다."
    )
    static let outputModeDetail = AppText.localized(
        english: "Translation shows source and target text. Transcribe Only keeps the source text.",
        korean: "번역은 원문과 번역을 표시하고, 전사만은 원문 기록만 유지합니다."
    )
    static let dubbingDetail = AppText.localized(
        english: "Speak translated output when a stable translated segment is available.",
        korean: "안정된 번역 문장이 생기면 번역 음성을 재생합니다."
    )
    static let liveTranslationVolume = AppText.localized(
        english: "Volume",
        korean: "음량"
    )
    static let liveTranslationVolumeDetail = AppText.localized(
        english: "Controls the translated speech AirTranslate plays in live translation modes.",
        korean: "실시간 번역 모드에서 AirTranslate가 재생하는 번역 음성 크기를 조절합니다."
    )
    static let displaySettings = AppText.localized(english: "Display Settings", korean: "표시 설정")
    static let displayContent = AppText.localized(english: "Display Content", korean: "표시 내용")
    static let floatingTextSizeDetail = AppText.localized(
        english: "Controls the optical size used in the floating caption window.",
        korean: "플로팅 자막 창에 쓰이는 글자 크기를 조정합니다."
    )
    static let floatingLineCountDetail = AppText.localized(
        english: "Limits how many wrapped lines stay visible at once.",
        korean: "한 번에 표시되는 줄 수를 제한합니다."
    )
    static let keepOnTop = AppText.localized(english: "Always On Top", korean: "항상 위에 표시")
    static let keepOnTopDetail = AppText.localized(
        english: "Keep floating captions above other windows.",
        korean: "다른 창 위에 플로팅 자막을 고정합니다."
    )
    static let floatingFooter = AppText.localized(
        english: "Floating captions appear in a separate movable window.",
        korean: "플로팅 자막은 별도 창으로 표시되며 원하는 위치로 이동할 수 있습니다."
    )
    static let floatingPreviewAccessibilityLabel = AppText.localized(
        english: "Floating caption preview. Original: We're going to focus on real-time translation. Translation: We will focus on real-time translation.",
        korean: "플로팅 자막 미리보기. 원문: We're going to focus on real-time translation. 번역: 우리는 실시간 번역에 집중할 것입니다."
    )
    static let required = AppText.localized(english: "Required", korean: "필수")
    static let aboutAirTranslate = AppText.localized(english: "About AirTranslate", korean: "AirTranslate 정보")
    static let localFirst = AppText.localized(english: "Local first", korean: "로컬 우선")
    static let privacy = AppText.localized(english: "Privacy", korean: "개인정보")
    static let privacyDetail = AppText.localized(
        english: "Apple mode runs locally. OpenAI and Gemini Live are used only after you provide a matching API key and select that mode.",
        korean: "Apple 모드는 로컬에서 실행됩니다. OpenAI와 Gemini Live는 해당 API 키를 저장하고 해당 모드를 선택했을 때만 사용됩니다."
    )
    static let keychain = "Keychain"
    static let sidebarHint = AppText.localized(
        english: "Opens this settings category.",
        korean: "이 설정 카테고리를 엽니다."
    )
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsCategory.allCases) { category in
                HStack(spacing: 14) {
                    Image(systemName: category.systemImage)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(selection == category ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 28)

                    Text(category.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selection == category ? Color.primary : Color.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .tag(category)
                .listRowSeparator(.hidden)
                .accessibilityLabel(category.title)
                .accessibilityHint(SettingsCopy.sidebarHint)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.primary.opacity(0.035))
    }
}

private struct SettingsPageHeader: View {
    let category: SettingsCategory

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: category.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(category.title)
                    .font(.title2.weight(.bold))

                Text(category.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct FloatingCaptionPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.localized(english: "Preview", korean: "미리보기"))
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor),
                                Color.accentColor.opacity(0.18),
                                Color.black.opacity(0.48)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.45)

                VStack(spacing: 10) {
                    Text("We're going to focus on real-time translation.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("우리는 실시간 번역에 집중할 것입니다.")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 8)
            }
            .frame(height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SettingsCopy.floatingPreviewAccessibilityLabel)
        }
    }
}

private struct SettingsNoticeRow: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.orange)
                .frame(width: 28, height: 28)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .settingsRowSeparator()
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsNoticeActionRow: View {
    let text: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.orange)
                .frame(width: 28, height: 28)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(action: action) {
                Label(actionTitle, systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(actionTitle)
        }
        .padding(.vertical, 9)
        .settingsRowSeparator()
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct SettingsControlRow<Trailing: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsRowLabel(title: title, detail: detail, systemImage: systemImage)

            Spacer(minLength: 16)

            trailing
                .controlSize(.regular)
        }
        .padding(.vertical, 9)
        .settingsRowSeparator()
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(title: title, detail: detail, systemImage: systemImage) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct SettingsVolumeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: 0.05)
                .frame(width: 150)

            Text("\(Int((value * 100).rounded()))%")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let value: String

    var body: some View {
        SettingsControlRow(title: title, detail: detail, systemImage: systemImage) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 208, alignment: .leading)
        .layoutPriority(1)
    }
}

private struct SettingsAssetAvailabilityRow: View {
    let title: String
    let availability: ModelAvailability
    let download: () -> Void

    var body: some View {
        SettingsControlRow(
            title: title,
            detail: availability.detail,
            systemImage: symbolName
        ) {
            if availability.state == .checking || availability.state == .downloading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(availability.state.title)
            } else if availability.state.canDownload {
                Button(AppText.download) {
                    download()
                }
                .accessibilityLabel("\(title) \(AppText.download)")
            } else {
                Text(availability.state.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .accessibilityLabel("\(title) \(availability.state.title)")
            }
        }
        .help(availability.detail)
    }

    private var symbolName: String {
        switch availability.state {
        case .checking:
            "clock"
        case .installed:
            "checkmark.seal.fill"
        case .downloadRequired, .downloading:
            "arrow.down.circle.fill"
        case .unsupported, .unavailable, .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch availability.state {
        case .checking:
            .secondary
        case .installed:
            .green
        case .downloadRequired, .downloading:
            .orange
        case .unsupported, .unavailable, .failed:
            .red
        }
    }
}

private extension View {
    func settingsRowSeparator() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 42)
        }
    }
}
