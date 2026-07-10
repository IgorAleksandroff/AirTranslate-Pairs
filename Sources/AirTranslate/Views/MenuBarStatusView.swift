import SwiftUI

struct MenuBarStatusView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            actionGrid

            Divider()

            displayModeGrid

            Divider()

            captionFormatControls

            Divider()

            appControls
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial)
        .onAppear {
            syncFloatingCaptionVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingCaptionWindowController.visibilityDidChangeNotification)) { _ in
            syncFloatingCaptionVisibility()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusSymbolName)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
            Button {
                toggleFloatingCaptions()
            } label: {
                IconPanelButtonLabel(
                    systemImage: isFloatingCaptionVisible ? "captions.bubble.fill" : "captions.bubble",
                    title: isFloatingCaptionVisible
                        ? AppText.localized(english: "Hide", korean: "숨김", japanese: "非表示", chineseSimplified: "隐藏")
                        : AppText.localized(english: "Show", korean: "보기", japanese: "表示", chineseSimplified: "显示"),
                    subtitle: isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff,
                    accentColor: isFloatingCaptionVisible ? .green : .secondary,
                    isSelected: isFloatingCaptionVisible
                )
            }
            .buttonStyle(.plain)
            .help(isFloatingCaptionVisible ? AppText.hideFloatingCaptions : AppText.showFloatingCaptions)
            .accessibilityLabel(isFloatingCaptionVisible ? AppText.hideFloatingCaptions : AppText.showFloatingCaptions)
            .accessibilityValue(isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff)

            Button {
                openWindow(id: AirTranslateWindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                IconPanelButtonLabel(
                    systemImage: "macwindow",
                    title: AppText.localized(english: "App", korean: "앱", japanese: "アプリ", chineseSimplified: "应用"),
                    subtitle: AppText.localized(english: "Main", korean: "메인", japanese: "メイン", chineseSimplified: "主窗口"),
                    accentColor: .secondary
                )
            }
            .buttonStyle(.plain)
            .help(AppText.openMainWindow)

            Button {
                toggleCapture()
            } label: {
                IconPanelButtonLabel(
                    systemImage: session.isRunning ? "stop.fill" : "play.fill",
                    title: session.isRunning ? AppText.stop : AppText.start,
                    subtitle: session.isRunning ? AppText.menuBarRunningTitle : AppText.ready,
                    accentColor: session.isRunning ? .red : .accentColor,
                    isSelected: !session.isRunning
                )
            }
            .buttonStyle(.plain)

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
                .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
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
        if session.isPaused {
            return "pause.circle.fill"
        }
        if session.isRunning {
            return "waveform.circle.fill"
        }
        return "captions.bubble.fill"
    }

    private var statusColor: Color {
        if session.isPaused {
            return .orange
        }
        if session.isRunning {
            return .green
        }
        return .secondary
    }

    private func toggleFloatingCaptions() {
        FloatingCaptionWindowController.toggle(session: session)
        syncFloatingCaptionVisibility()
    }

    private func toggleCapture() {
        if session.isRunning {
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
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(width: 30, height: 30)
                .background(accentColor.opacity(isSelected ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.quaternary.opacity(isSelected ? 0.7 : 0.42), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor.opacity(isSelected ? 0.48 : 0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IconChoiceLabel: View {
    let systemImage: String
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IconMenuLabel: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
