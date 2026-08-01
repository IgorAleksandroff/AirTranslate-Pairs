import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.openSettings) private var openSettings
    @State private var isLibraryPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandHeader
                quickSettingsCard
                detailsCard
                if shouldShowAPIKeyCard {
                    apiKeyCard
                }
                storageRow
            }
            .padding(20)
        }
        .navigationTitle("AirTranslate")
        .sheet(isPresented: $isLibraryPresented) {
            TranscriptLibraryView(session: session)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            AppIconMark()

            VStack(alignment: .leading, spacing: 8) {
                Text(AppText.appName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                SidebarSessionStatus(session: session)
            }

            Spacer(minLength: 0)

            SidebarPermissionActionButton(session: session)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var quickSettingsCard: some View {
        SidebarCard(
            title: quickSettingsTitle,
            headerAccessory: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        ) {
            VStack(spacing: 0) {
                QuickSettingRow(
                    title: AppText.localized(english: "Language", korean: "언어", japanese: "言語", chineseSimplified: "语言"),
                    systemImage: "globe"
                ) {
                SidebarLanguageRouteControl(
                    title: session.languageSummary,
                    isAutoSourceEnabled: session.isAppleSourceAutoDetectionEnabled || usesOpenAIAutoLanguageFlow,
                    sourceSelection: quickSourceLanguageBinding,
                    targetSelection: quickTargetLanguageBinding,
                    isTranscribeOnlyMode: session.isTranscribeOnlyMode,
                    isDisabled: isSessionConfigurationLocked,
                    swap: swapQuickLanguagePairIfConfigurationUnlocked
                )
                }

                SidebarDivider()

                QuickSettingRow(
                    title: AppText.localized(english: "Audio", korean: "오디오", japanese: "オーディオ", chineseSimplified: "音频"),
                    systemImage: "mic"
                ) {
                    Picker(AppText.audioInputSource, selection: audioInputSourceBinding) {
                        ForEach(AudioInputSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .disabled(isSessionConfigurationLocked)
                    .accessibilityLabel(AppText.audioInputSource)
                }

                if session.audioInputSource == .microphone {
                    MicrophoneInputDevicePicker(
                        selection: microphoneInputDeviceBinding,
                        devices: session.microphoneInputDevices,
                        isDisabled: isSessionConfigurationLocked
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }

                SidebarDivider()

                QuickSettingRow(
                    title: AppText.localized(english: "Output", korean: "출력", japanese: "出力", chineseSimplified: "输出"),
                    systemImage: "viewfinder"
                ) {
                    if session.isUsingGPTTranscriptionMode {
                        Text(AppText.gptTranscriptionSourceOnly)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if usesAPIModeOutputControl {
                        SidebarLiveTranslationButton(
                            isDisabled: isSessionConfigurationLocked,
                            action: useTranslationModeIfConfigurationUnlocked
                        )
                    } else {
                        Picker(AppText.outputMode, selection: liveOutputModeBinding) {
                            ForEach(LiveOutputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.large)
                        .disabled(isSessionConfigurationLocked)
                        .accessibilityLabel(AppText.outputMode)
                    }
                }

                if !session.isUsingGPTTranscriptionMode {
                    SidebarVoiceOutputToggle(
                        isOn: dubbingEnabledBinding,
                        isDisabled: isSessionConfigurationLocked
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, -4)
                    .padding(.bottom, session.isDubbingEnabled ? 8 : 13)
                }

                if !session.isUsingGPTTranscriptionMode, session.isDubbingEnabled {
                    SidebarVolumeControls(
                        volume: translatedVoiceVolumeBinding,
                        isDisabled: isSessionConfigurationLocked
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, -4)
                    .padding(.bottom, 13)
                }
            }
        }
        .onAppear {
            session.refreshModelAvailability()
            guard !isSessionConfigurationLocked else { return }
            session.refreshMicrophoneInputDevices()
            if usesOpenAIAutoLanguageFlow {
                session.usePreferredLanguageForOpenAIOutput()
            }
        }
    }

    private var detailsCard: some View {
        let title = AppText.localized(
            english: "Details",
            korean: "세부 설정",
            japanese: "詳細設定",
            chineseSimplified: "详细设置"
        )
        let value = "\(ProcessingEngine.current(for: session).title) · \(session.sessionDurationMode.title)"

        return Button(title) {
            openSettings()
        }
        .buttonStyle(.plain)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 16)
        .padding(.trailing, 52)
        .padding(.top, 16)
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .overlay(alignment: .bottomLeading) {
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 16)
                .padding(.bottom, 18)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "gearshape")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .help(AppText.configureTranslationSettings)
        .accessibilityValue("\(AppText.configureTranslationSettings), \(value)")
    }

    private var apiKeyCard: some View {
        Button(missingAPIKeyTitle) {
            session.requestAPIKeySettings()
            openSettings()
        }
        .buttonStyle(.plain)
        .font(.headline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 74)
        .padding(.trailing, 44)
        .padding(.top, 15)
        .padding(.bottom, 43)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28))
        }
        .overlay(alignment: .leading) {
            Image(systemName: "key.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 42, height: 42)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, 16)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Text(SettingsSidebarCopy.apiKeyAction)
                .font(.callout)
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .padding(.leading, 74)
                .padding(.bottom, 17)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .help(missingAPIKeyTitle)
        .accessibilityValue(SettingsSidebarCopy.apiKeyAction)
        .accessibilityHint(SettingsSidebarCopy.apiKeyAction)
    }

    private var storageRow: some View {
        Button(AppText.library) {
            isLibraryPresented = true
        }
        .buttonStyle(.plain)
        .font(.headline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 74)
        .padding(.trailing, 44)
        .padding(.top, 15)
        .padding(.bottom, 43)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .overlay(alignment: .leading) {
            Image(systemName: "tray.full")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, 16)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Text(AppText.manageSavedTranscripts)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 74)
                .padding(.bottom, 17)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .help(AppText.manageSavedTranscripts)
        .accessibilityValue(AppText.manageSavedTranscripts)
    }

    private var quickSettingsTitle: String {
        AppText.localized(
            english: "Quick Settings",
            korean: "빠른 설정",
            japanese: "クイック設定",
            chineseSimplified: "快速设置"
        )
    }

    private var isSessionConfigurationLocked: Bool {
        SidebarSessionConfigurationAccess.isLocked(
            isRunning: session.isRunning,
            isStarting: session.isStarting
        )
    }

    private var liveOutputModeBinding: Binding<LiveOutputMode> {
        Binding(
            get: {
                session.liveOutputMode
            },
            set: { mode in
                guard !isSessionConfigurationLocked else { return }
                session.useLiveOutputMode(mode)
            }
        )
    }

    private var audioInputSourceBinding: Binding<AudioInputSource> {
        lockedSessionConfigurationBinding($session.audioInputSource)
    }

    private var microphoneInputDeviceBinding: Binding<String> {
        lockedSessionConfigurationBinding($session.selectedMicrophoneInputDeviceID)
    }

    private var dubbingEnabledBinding: Binding<Bool> {
        lockedSessionConfigurationBinding($session.isDubbingEnabled)
    }

    private var translatedVoiceVolumeBinding: Binding<Double> {
        lockedSessionConfigurationBinding($session.translatedVoiceVolume)
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

    private var quickSourceLanguageBinding: Binding<LanguageOption> {
        Binding {
            session.sourceLanguage
        } set: { language in
            guard !isSessionConfigurationLocked else { return }
            session.useQuickSourceLanguage(language)
        }
    }

    private var quickTargetLanguageBinding: Binding<LanguageOption> {
        Binding {
            session.targetLanguage
        } set: { language in
            guard !isSessionConfigurationLocked else { return }
            session.useQuickTargetLanguage(language)
        }
    }

    private func useTranslationModeIfConfigurationUnlocked() {
        guard !isSessionConfigurationLocked else { return }
        session.useTranslationMode()
    }

    private func swapQuickLanguagePairIfConfigurationUnlocked() {
        guard !isSessionConfigurationLocked else { return }
        session.swapQuickLanguagePair()
    }

    private var usesOpenAIAutoLanguageFlow: Bool {
        ProcessingEngine.current(for: session) == .gpt && session.isUsingOpenAIRealtimeTranslation
    }

    private var usesAPIModeOutputControl: Bool {
        ProcessingEngine.current(for: session) != .apple
    }

    private var shouldShowAPIKeyCard: Bool {
        switch ProcessingEngine.current(for: session) {
        case .gpt, .gptTranscription:
            !session.hasOpenAIAPIKey
        case .gemini:
            !session.hasGeminiAPIKey
        case .apple:
            false
        }
    }

    private var missingAPIKeyTitle: String {
        switch ProcessingEngine.current(for: session) {
        case .gpt, .gptTranscription:
            AppText.openAIAPIKeyNotConfigured
        case .gemini:
            AppText.geminiAPIKeyNotConfigured
        case .apple:
            AppText.openAIAPIKeyNotConfigured
        }
    }

}

enum SidebarSessionConfigurationAccess {
    static func isLocked(isRunning: Bool, isStarting: Bool) -> Bool {
        isRunning || isStarting
    }
}

private enum SettingsSidebarCopy {
    static let apiKeyAction = AppText.localized(
        english: "Add API key",
        korean: "API 키 입력",
        japanese: "APIキーを入力",
        chineseSimplified: "输入 API key"
    )
    static let liveTranslationVolume = AppText.localized(
        english: "Volume",
        korean: "음량",
        japanese: "音量",
        chineseSimplified: "音量"
    )
}

private enum ProcessingEngine: String, CaseIterable, Identifiable {
    case apple
    case gpt
    case gptTranscription
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            AppText.localized(
                english: "Apple Mode",
                korean: "Apple 기본 모드",
                japanese: "Apple標準モード",
                chineseSimplified: "Apple 默认模式"
            )
        case .gpt:
            AppText.localized(
                english: "GPT Mode",
                korean: "GPT 모드",
                japanese: "GPTモード",
                chineseSimplified: "GPT 模式"
            )
        case .gptTranscription:
            AppText.gptTranscriptionMode
        case .gemini:
            AppText.localized(
                english: "Gemini Live",
                korean: "Gemini Live",
                japanese: "Gemini Live",
                chineseSimplified: "Gemini Live"
            )
        }
    }

    @MainActor
    static func current(for session: TranslationSessionStore) -> ProcessingEngine {
        if session.isUsingGPTTranscriptionMode {
            return .gptTranscription
        }
        if session.openAITranscriptionModel.isEnabled || session.openAITranslationModel.isEnabled {
            return .gpt
        }
        if session.isUsingGeminiTranslation {
            return .gemini
        }
        return .apple
    }
}

private struct SidebarSessionStatus: View {
    let session: TranslationSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusPill(
                title: statusTitle,
                symbolName: statusSymbolName,
                color: statusColor
            )

            if showsDetail {
                Text(session.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.statusMessage)
            }
        }
    }

    private var showsDetail: Bool {
        (session.isRunning || session.isPaused) && session.statusMessage != statusTitle
    }

    private var statusTitle: String {
        if session.isPaused {
            return AppText.paused
        }
        if session.isRunning {
            return AppText.listening
        }
        return session.statusMessage
    }

    private var statusSymbolName: String {
        if session.isPaused {
            return "pause.circle.fill"
        }
        if session.isRunning {
            return "waveform.circle.fill"
        }
        if session.statusMessage == AppText.ready {
            return "circle.fill"
        }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if session.isPaused {
            return .orange
        }
        if session.isRunning {
            return .green
        }
        if session.statusMessage == AppText.ready {
            return .green
        }
        return .secondary
    }
}

private struct SidebarPermissionActionButton: View {
    let session: TranslationSessionStore

    var body: some View {
        if needsPermissionAction {
            Button {
                session.openPrivacySettings()
            } label: {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(AppText.openPrivacySettings)
            .accessibilityLabel(AppText.openPrivacySettings)
        }
    }

    private var needsPermissionAction: Bool {
        session.statusMessage.localizedCaseInsensitiveContains("permission")
            || session.statusMessage.localizedCaseInsensitiveContains("권한")
    }
}

private struct StatusPill: View {
    let title: String
    let symbolName: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        } icon: {
            Image(systemName: symbolName)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct QuickSettingRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 86, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
            .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    }
}

private struct SidebarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

private struct SidebarLanguageRouteControl: View {
    let title: String
    let isAutoSourceEnabled: Bool
    @Binding var sourceSelection: LanguageOption
    @Binding var targetSelection: LanguageOption
    let isTranscribeOnlyMode: Bool
    let isDisabled: Bool
    let swap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if !isAutoSourceEnabled {
                    Picker(AppText.from, selection: $sourceSelection) {
                        ForEach(LanguageOption.supported) { language in
                            Text(language.localizedTitle).tag(language)
                        }
                    }
                }

                if !isTranscribeOnlyMode {
                    Picker(AppText.to, selection: $targetSelection) {
                        ForEach(targetLanguageOptions) { language in
                            Text(language.localizedTitle).tag(language)
                        }
                    }
                }
            } label: {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(title)
            .accessibilityLabel(languageRouteAccessibilityLabel)
            .accessibilityValue(title)

            if !isTranscribeOnlyMode {
                Button {
                    swap()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isDisabled || isAutoSourceEnabled)
                .help(AppText.swapLanguages)
                .accessibilityLabel(AppText.swapLanguages)
            }
        }
    }

    private var languageRouteAccessibilityLabel: String {
        isTranscribeOnlyMode
            ? AppText.from
            : AppText.localized(
                english: "Language pair",
                korean: "언어 조합",
                japanese: "言語ペア",
                chineseSimplified: "语言组合"
            )
    }

    private var targetLanguageOptions: [LanguageOption] {
        LanguageOption.supported.filter { $0 != sourceSelection }
    }
}

private struct MicrophoneInputDevicePicker: View {
    @Binding var selection: String
    let devices: [MicrophoneInputDevice]
    let isDisabled: Bool

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button(device.name) {
                    selection = device.id
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)

                Text(AppText.microphoneInputDevice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 6)

                Text(selectedDeviceName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(AppText.microphoneInputDevice)
        .accessibilityLabel(AppText.microphoneInputDevice)
        .accessibilityValue(selectedDeviceName)
    }

    private var selectedDeviceName: String {
        devices.first { $0.id == selection }?.name ?? MicrophoneInputDevice.systemDefault.name
    }
}

private struct SidebarLiveTranslationButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(AppText.liveTranslation)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            } icon: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 12)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(AppText.liveTranslation)
        .accessibilityLabel(AppText.liveTranslation)
    }
}

private struct SidebarVoiceOutputToggle: View {
    @Binding var isOn: Bool
    let isDisabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                Text(AppText.voiceOutput)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } icon: {
                Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .disabled(isDisabled)
        .accessibilityLabel(AppText.voiceOutput)
        .accessibilityValue(isOn ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff)
    }
}

private struct SidebarVolumeControls: View {
    @Binding var volume: Double
    let isDisabled: Bool

    var body: some View {
        SidebarMiniVolumeSlider(
            title: SettingsSidebarCopy.liveTranslationVolume,
            systemImage: "speaker.wave.2",
            value: $volume,
            range: 0...1
        )
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .disabled(isDisabled)
        .accessibilityElement(children: .contain)
    }
}

private struct SidebarMiniVolumeSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } icon: {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.secondary)
            .frame(width: 58, alignment: .leading)

            Slider(value: $value, in: range, step: 0.05)
                .controlSize(.small)

            Text("\(Int((value * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded()))%")
    }
}

private struct AppIconMark: View {
    private var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    var body: some View {
        Image(nsImage: appIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 5, x: 0, y: 2)
            .accessibilityHidden(true)
    }
}

private struct SidebarCard<Content: View, HeaderAccessory: View>: View {
    let title: String?
    @ViewBuilder let headerAccessory: HeaderAccessory
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) where HeaderAccessory == EmptyView {
        self.title = title
        self.headerAccessory = EmptyView()
        self.content = content()
    }

    init(
        title: String? = nil,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    headerAccessory
                }
            }

            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}
