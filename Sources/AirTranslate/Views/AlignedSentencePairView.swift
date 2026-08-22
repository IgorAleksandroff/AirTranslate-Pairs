import AppKit
import SwiftUI

/// Source and translation of one sentence with hover-linked word highlighting in both directions.
struct AlignedSentencePairView: View {
    struct Style {
        var sourceFont: Font
        var translationFont: Font
        var sourceColor: Color
        var translationColor: Color
        var pendingColor: Color
        /// Lines always reserved for the translation (at least one), so the row does not jump when it arrives.
        var translationMinimumLines: Int
    }

    let pair: SentencePair
    let alignments: WordAlignmentStore
    let sourceLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let style: Style
    let axis: Axis

    @State private var hoveredSource: Int?
    @State private var hoveredTarget: Int?

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(alignment: .leading, spacing: 3) {
                    sourceText
                    translationText
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    sourceText.frame(maxWidth: .infinity, alignment: .leading)
                    translationText.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .contextMenu {
            Button(AppText.copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pair.source + "\n" + (pair.translated ?? ""), forType: .string)
            }
        }
        .task(id: pair.translated) {
            guard let translated = pair.translated else { return }
            await alignments.requestAlignment(
                source: pair.source,
                target: translated,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
    }

    private var alignment: SentenceAlignment? {
        pair.translated.flatMap { alignments.alignment(source: pair.source, target: $0) }
    }

    private var sourceText: some View {
        WordFlowText(
            tokens: WordTokens.split(pair.source),
            font: style.sourceFont,
            color: style.sourceColor,
            hovered: hoveredSource,
            highlighted: hoveredTarget.flatMap { alignment?.targetToSource[$0] } ?? [],
            onHover: { hoveredSource = $0 }
        )
    }

    private var translationText: some View {
        ZStack(alignment: .topLeading) {
            translationPlaceholder
            if let translated = pair.translated {
                WordFlowText(
                    tokens: WordTokens.split(translated),
                    font: style.translationFont,
                    color: style.translationColor,
                    hovered: hoveredTarget,
                    highlighted: hoveredSource.flatMap { alignment?.sourceToTarget[$0] } ?? [],
                    onHover: { hoveredTarget = $0 }
                )
            } else {
                Text("…")
                    .font(style.translationFont)
                    .foregroundStyle(style.pendingColor)
                    .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // Invisible text of the reserved line count sets the minimum height with the real font metrics.
    private var translationPlaceholder: some View {
        Text(Array(repeating: "…", count: max(style.translationMinimumLines, 1)).joined(separator: "\n"))
            .font(style.translationFont)
            .padding(.vertical, 1)
            .hidden()
            .accessibilityHidden(true)
    }
}
