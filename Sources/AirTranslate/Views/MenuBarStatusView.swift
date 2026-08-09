import SwiftUI

struct MenuBarStatusView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            actionGrid

            Divider()

            displayModeGrid

            Divider()

            captionFormatControls

            Divider()

            appControls
        }
        .padding(12)
        .frame(width: 330)
        .background(.regularMaterial)
        .onAppear {
            syncFloatingCaptionVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingCaptionWindowController.visibilityDidChangeNotification)) { _ in
            syncFloatingCaptionVisibility()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: statusSymbolName)
                .font(.system(size: AirTranslateDesign.iconLarge, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppText.floatingCaptions)
                    .font(.headline)

                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private var actionGrid: some View {
        VStack(spacing: 2) {
            Button {
                toggleCapture()
            } label: {
                IconPanelButtonLabel(
                    systemImage: capturePhase.actionSystemImage,
                    title: capturePhase.actionTitle,
                    subtitle: capturePhase.actionSubtitle(statusMessage: session.statusMessage),
                    accentColor: captureActionColor,
                    isSelected: capturePhase == .idle
                )
            }
            .buttonStyle(AirTranslatePressButtonStyle())
            .help(capturePhase.actionTitle)
            .accessibilityLabel(capturePhase.actionTitle)
            .accessibilityValue(capturePhase.actionSubtitle(statusMessage: session.statusMessage))

            Button {
                toggleFloatingCaptions()
            } label: {
                IconPanelButtonLabel(
                    systemImage: isFloatingCaptionVisible ? "captions.bubble.fill" : "captions.bubble",
                    title: isFloatingCaptionVisible
                        ? AppText.localized(english: "Hide captions", korean: "자막 숨기기", japanese: "字幕を隠す", chineseSimplified: "隐藏字幕")
                        : AppText.localized(english: "Show captions", korean: "자막 보기", japanese: "字幕を表示", chineseSimplified: "显示字幕"),
                    subtitle: isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff,
                    accentColor: isFloatingCaptionVisible ? .green : .secondary,
                    isSelected: isFloatingCaptionVisible
                )
            }
            .buttonStyle(AirTranslatePressButtonStyle())
            .help(isFloatingCaptionVisible ? AppText.hideFloatingCaptions : AppText.showFloatingCaptions)
            .accessibilityLabel(isFloatingCaptionVisible ? AppText.hideFloatingCaptions : AppText.showFloatingCaptions)
            .accessibilityValue(isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff)

            Button {
                openWindow(id: AirTranslateWindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                IconPanelButtonLabel(
                    systemImage: "macwindow",
                    title: AppText.localized(english: "Open AirTranslate", korean: "AirTranslate 열기", japanese: "AirTranslateを開く", chineseSimplified: "打开 AirTranslate"),
                    subtitle: AppText.localized(english: "Main window", korean: "메인 윈도우", japanese: "メインウインドウ", chineseSimplified: "主窗口"),
                    accentColor: .secondary
                )
            }
            .buttonStyle(AirTranslatePressButtonStyle())
            .help(AppText.openMainWindow)

            if session.isRunning {
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    IconPanelButtonLabel(
                        systemImage: session.isPaused ? "play.fill" : "pause.fill",
                        title: session.isPaused ? AppText.resume : AppText.pause,
                        subtitle: session.isPaused ? AppText.paused : AppText.menuBarRunningTitle,
                        accentColor: session.isPaused ? .accentColor : .orange,
                        isSelected: session.isPaused
                    )
                }
                .buttonStyle(AirTranslatePressButtonStyle())
            }
        }
    }

    private var displayModeGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlSectionHeader(
                systemImage: "rectangle.split.2x1",
                title: AppText.floatingDisplay
            )

            HStack(spacing: 8) {
                ForEach(session.availableFloatingCaptionDisplayModes) { mode in
                    Button {
                        session.floatingCaptionDisplayMode = mode
                    } label: {
                        IconChoiceLabel(
                            systemImage: mode.systemImage,
                            title: compactDisplayTitle(for: mode),
                            isSelected: session.floatingCaptionDisplayMode == mode
                        )
                    }
                    .buttonStyle(AirTranslatePressButtonStyle())
                    .help(mode.title)
                    .accessibilityLabel(mode.title)
                    .accessibilityValue(session.floatingCaptionDisplayMode == mode ? AppText.localized(english: "Selected", korean: "선택됨", japanese: "選択中", chineseSimplified: "已选择") : "")
                }
            }
        }
    }

    private var captionFormatControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlSectionHeader(
                systemImage: "slider.horizontal.3",
                title: AppText.localized(english: "Caption Style", korean: "자막 스타일", japanese: "字幕スタイル", chineseSimplified: "字幕样式")
            )

            HStack(spacing: 8) {
                Menu {
                    ForEach(FloatingCaptionTextSize.allCases) { size in
                        Button(size.title) {
                            session.floatingCaptionTextSize = size
                        }
                    }
                } label: {
                    IconMenuLabel(
                        systemImage: "textformat.size",
                        title: AppText.localized(english: "Size", korean: "크기", japanese: "サイズ", chineseSimplified: "大小"),
                        value: session.floatingCaptionTextSize.title
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help(AppText.floatingTextSize)

                Menu {
                    ForEach(FloatingCaptionLineCount.allCases) { lineCount in
                        Button(lineCount.title) {
                            session.floatingCaptionLineCount = lineCount
                        }
                    }
                } label: {
                    IconMenuLabel(
                        systemImage: "line.3.horizontal",
                        title: AppText.localized(english: "Lines", korean: "줄 수", japanese: "行数", chineseSimplified: "行数"),
                        value: session.floatingCaptionLineCount.title
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help(AppText.floatingLineCount)
            }
        }
    }

    private var appControls: some View {
        HStack(spacing: 12) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label(
                    AppText.localized(english: "Settings", korean: "설정", japanese: "設定", chineseSimplified: "设置"),
                    systemImage: "gearshape"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppText.localized(english: "Open Settings", korean: "설정 열기", japanese: "設定を開く", chineseSimplified: "打开设置"))

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label(
                    AppText.localized(english: "Quit", korean: "종료", japanese: "終了", chineseSimplified: "退出"),
                    systemImage: "power"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppText.localized(english: "Quit AirTranslate", korean: "AirTranslate 종료", japanese: "AirTranslateを終了", chineseSimplified: "退出 AirTranslate"))
        }
    }

    private var statusSymbolName: String {
        switch capturePhase {
        case .idle:
            "captions.bubble.fill"
        case .starting:
            "hourglass.circle.fill"
        case .running:
            "waveform.circle.fill"
        case .paused:
            "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch capturePhase {
        case .idle:
            .secondary
        case .starting, .paused:
            .orange
        case .running:
            .green
        }
    }

    private var capturePhase: MenuBarCapturePhase {
        MenuBarCapturePhase(
            isRunning: session.isRunning,
            isStarting: session.isStarting,
            isPaused: session.isPaused
        )
    }

    private var captureActionColor: Color {
        switch capturePhase {
        case .idle:
            .accentColor
        case .starting, .running, .paused:
            .red
        }
    }

    private func toggleFloatingCaptions() {
        FloatingCaptionWindowController.toggle(session: session)
        syncFloatingCaptionVisibility()
    }

    private func toggleCapture() {
        if capturePhase != .idle {
            session.stop()
        } else {
            session.start()
        }
    }

    private func syncFloatingCaptionVisibility() {
        isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen
    }

    private func compactDisplayTitle(for mode: FloatingCaptionDisplayMode) -> String {
        switch mode {
        case .original:
            AppText.originalOnly
        case .originalAndTranslation:
            AppText.localized(english: "Both", korean: "원문+번역", japanese: "両方", chineseSimplified: "两者")
        case .translation:
            AppText.translationOnly
        }
    }
}

enum MenuBarCapturePhase: Equatable {
    case idle
    case starting
    case running
    case paused

    init(isRunning: Bool, isStarting: Bool, isPaused: Bool) {
        if isStarting {
            self = .starting
        } else if isRunning {
            self = isPaused ? .paused : .running
        } else {
            self = .idle
        }
    }

    var actionSystemImage: String {
        switch self {
        case .idle:
            "play.fill"
        case .starting:
            "xmark"
        case .running, .paused:
            "stop.fill"
        }
    }

    var actionTitle: String {
        switch self {
        case .idle:
            AppText.start
        case .starting:
            AppText.cancel
        case .running, .paused:
            AppText.stop
        }
    }

    func actionSubtitle(statusMessage: String) -> String {
        switch self {
        case .idle:
            AppText.ready
        case .starting:
            statusMessage
        case .running:
            AppText.menuBarRunningTitle
        case .paused:
            AppText.paused
        }
    }
}

private struct ControlSectionHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct IconPanelButtonLabel: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let accentColor: Color
    var isSelected = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: AirTranslateDesign.iconRegular, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 38)
        .airTranslateInteractiveSurface(isSelected: isSelected, tint: accentColor)
        .contentShape(RoundedRectangle(cornerRadius: AirTranslateDesign.controlRadius, style: .continuous))
    }
}

private struct IconChoiceLabel: View {
    let systemImage: String
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: AirTranslateDesign.iconSmall, weight: .semibold))

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 34)
        .airTranslateInteractiveSurface(isSelected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: AirTranslateDesign.controlRadius, style: .continuous))
    }
}

private struct IconMenuLabel: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: AirTranslateDesign.iconRegular, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 40)
        .airTranslateInteractiveSurface()
        .contentShape(RoundedRectangle(cornerRadius: AirTranslateDesign.controlRadius, style: .continuous))
    }
}
