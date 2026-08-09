import SwiftUI

struct FloatingCaptionWindowView: View {
    @Bindable var session: TranslationSessionStore

    var body: some View {
        ZStack {
            Color.clear

            VStack(spacing: 8) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                if hasVisibleCaptionText {
                    RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous)
                        .fill(.black.opacity(0.76))
                        .overlay {
                            RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.12))
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, idealWidth: 720, maxWidth: 960, minHeight: 90, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .overlay {
            FloatingCaptionDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            FloatingWindowConfigurator(
                preferredContentHeight: preferredHeight,
                keepsAboveOtherWindows: session.keepsFloatingCaptionAboveOtherWindows
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        switch session.floatingCaptionDisplayMode {
        case .original:
            subtitleText(sourceText, font: session.floatingCaptionTextSize.primaryFont)
            if !noticeText.isEmpty {
                noticeSubtitleText(noticeText)
            }
        case .originalAndTranslation:
            if !sourceText.isEmpty {
                subtitleText(sourceText, font: session.floatingCaptionTextSize.secondaryFont)
                    .opacity(0.82)
                if !translationText.isEmpty {
                    subtitleText(translationText, font: session.floatingCaptionTextSize.primaryFont)
                } else if !noticeText.isEmpty {
                    noticeSubtitleText(noticeText)
                } else {
                    subtitleText(" ", font: session.floatingCaptionTextSize.primaryFont)
                        .opacity(0)
                }
            } else if !translationText.isEmpty {
                subtitleText(translationText, font: session.floatingCaptionTextSize.primaryFont)
            } else if !noticeText.isEmpty {
                noticeSubtitleText(noticeText)
            } else {
                subtitleText(AppText.noFloatingCaptionsYet, font: session.floatingCaptionTextSize.primaryFont)
            }
        case .translation:
            if !translationText.isEmpty {
                subtitleText(translationText, font: session.floatingCaptionTextSize.primaryFont)
            } else if !noticeText.isEmpty {
                noticeSubtitleText(noticeText)
            } else if sourceText.isEmpty {
                subtitleText(AppText.noFloatingCaptionsYet, font: session.floatingCaptionTextSize.primaryFont)
            }
        }
    }

    private var sourceText: String {
        session.floatingSourceText
    }

    private var translationText: String {
        session.floatingTranslationText
    }

    private var noticeText: String {
        session.floatingNoticeText ?? ""
    }

    private var hasVisibleCaptionText: Bool {
        switch session.floatingCaptionDisplayMode {
        case .original, .originalAndTranslation:
            true
        case .translation:
            !translationText.isEmpty || !noticeText.isEmpty || sourceText.isEmpty
        }
    }

    private var lineLimit: Int {
        session.floatingCaptionLineCount.rawValue
    }

    private var preferredHeight: CGFloat {
        let textSize = session.floatingCaptionTextSize
        let lineCount = CGFloat(lineLimit)
        let primaryHeight = textSize.primaryLineHeight * lineCount + CGFloat(lineLimit - 1) * 5
        let secondaryHeight = textSize.secondaryLineHeight * lineCount + CGFloat(lineLimit - 1) * 5
        let textHeight: CGFloat

        switch session.floatingCaptionDisplayMode {
        case .original, .translation:
            textHeight = noticeText.isEmpty ? primaryHeight : primaryHeight + secondaryHeight + 8
        case .originalAndTranslation:
            textHeight = primaryHeight + secondaryHeight + 8
        }

        return min(max(90, textHeight + 28), 720)
    }

    private func subtitleText(_ text: String, font: Font) -> some View {
        StreamingTranscriptText(
            text: text.isEmpty ? AppText.noFloatingCaptionsYet : text,
            font: font,
            foregroundColor: .white,
            isTextSelectionEnabled: false,
            lineLimit: lineLimit,
            textAlignment: .center,
            frameAlignment: .center,
            truncationMode: .tail
        )
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .lineSpacing(5)
        .shadow(color: .black.opacity(0.95), radius: 3, x: 0, y: 1)
        .shadow(color: .black.opacity(0.65), radius: 8, x: 0, y: 2)
    }

    private func noticeSubtitleText(_ text: String) -> some View {
        subtitleText(text, font: session.floatingCaptionTextSize.secondaryFont)
            .opacity(0.78)
    }
}
