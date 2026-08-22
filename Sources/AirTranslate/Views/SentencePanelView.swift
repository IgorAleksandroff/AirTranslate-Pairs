import SwiftUI

struct SentencePanelView: View {
    @Bindable var session: TranslationSessionStore

    private struct Entry: Identifiable {
        let pair: SentencePair
        var id: String { pair.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            if entries.isEmpty {
                Text(AppText.noFloatingCaptionsYet)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(session.sentencePanelBackgroundOpacity))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.white.opacity(0.45))
            Text(AppText.sentencePanel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button {
                SentencePanelWindowController.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(AppText.hideSentencePanel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .background {
            FloatingCaptionDragSurface()
        }
    }

    private func row(_ entry: Entry) -> some View {
        AlignedSentencePairView(
            pair: entry.pair,
            alignments: session.wordAlignments,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage,
            style: .init(
                sourceFont: .system(size: fontSize, weight: .regular),
                translationFont: .system(size: fontSize, weight: .regular),
                sourceColor: .white.opacity(0.96),
                translationColor: .white.opacity(0.6),
                pendingColor: .white.opacity(0.35),
                translationMinimumLines: 1
            ),
            axis: .vertical
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.bottom, entry.pair.startsParagraph ? 10 : 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(entry.pair.startsParagraph ? 0.22 : 0.09))
                .frame(height: 1)
                .padding(.horizontal, 10)
        }
    }

    private var fontSize: CGFloat {
        CGFloat(session.sentencePanelFontSize)
    }

    // Newest sentence first; the in-progress tail is the first entry.
    private var entries: [Entry] {
        let languageID = session.sourceLanguage.id
        return session.lines.reversed().flatMap { line in
            line.sentencePairs(sourceLanguageID: languageID).reversed().map(Entry.init)
        }
    }
}
