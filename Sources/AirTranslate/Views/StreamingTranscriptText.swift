import SwiftUI

struct StreamingTranscriptText: View {
    private static let maxAnimatedTextLength = 2_400
    private static let maxAnimatedDeltaLength = 360

    let text: String
    let font: Font
    var foregroundColor = Color.primary
    var isTextSelectionEnabled = true
    var lineLimit: Int?
    var textAlignment: TextAlignment = .leading
    var frameAlignment: Alignment = .topLeading
    var truncationMode: Text.TruncationMode = .head

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settledText = ""
    @State private var appearingText = ""
    @State private var appearingOpacity = 1.0
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        textView
            .onAppear {
                stream(to: text)
            }
            .onChange(of: text) { _, newText in
                stream(to: newText)
            }
            .onDisappear {
                streamTask?.cancel()
                streamTask = nil
                settle(to: text)
            }
    }

    @ViewBuilder
    private var textView: some View {
        if isTextSelectionEnabled {
            baseText.textSelection(.enabled)
        } else {
            baseText.textSelection(.disabled)
        }
    }

    private var baseText: some View {
        Text("\(Text(settledText))\(Text(appearingText).foregroundStyle(foregroundColor.opacity(appearingOpacity)))")
            .font(font)
            .foregroundStyle(foregroundColor)
            .lineLimit(lineLimit)
            .multilineTextAlignment(textAlignment)
            .truncationMode(truncationMode)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var visibleText: String {
        settledText + appearingText
    }

    private func stream(to newText: String) {
        streamTask?.cancel()
        let newTextLength = newText.count
        let visibleText = visibleText

        guard newText != visibleText else {
            return
        }

        guard !newText.isEmpty else {
            settle(to: "")
            return
        }

        guard !reduceMotion else {
            settle(to: newText)
            return
        }

        guard newTextLength <= Self.maxAnimatedTextLength else {
            settle(to: newText)
            return
        }

        guard newText.hasPrefix(visibleText), newTextLength > visibleText.count else {
            settle(to: newText)
            return
        }

        let remainingText = String(newText.dropFirst(visibleText.count))
        guard remainingText.count <= Self.maxAnimatedDeltaLength else {
            settle(to: newText)
            return
        }

        let chunks = StreamingChunkPolicy.chunks(for: remainingText)
        let delay = StreamingChunkPolicy.chunkDelayNanoseconds(chunkCount: chunks.count)
        let fadeDuration = Double(delay) / 1_000_000_000

        streamTask = Task { @MainActor in
            for chunk in chunks {
                if Task.isCancelled {
                    return
                }

                if !appearingText.isEmpty {
                    settledText += appearingText
                }

                appearingText = chunk
                appearingOpacity = 0.12

                withAnimation(.easeOut(duration: fadeDuration)) {
                    appearingOpacity = 1
                }

                try? await Task.sleep(nanoseconds: delay)
            }

            if Task.isCancelled {
                return
            }

            if !appearingText.isEmpty {
                settledText += appearingText
                appearingText = ""
                appearingOpacity = 1
            }
        }
    }

    private func settle(to finalText: String) {
        settledText = finalText
        appearingText = ""
        appearingOpacity = 1
    }
}

enum StreamingChunkPolicy {
    static let targetChunkCount = 14
    static let minimumChunkCharacters = 4
    static let maxChunkDelayNanoseconds: UInt64 = 18_000_000
    static let totalAnimationBudgetNanoseconds: UInt64 = 200_000_000

    static func chunks(for text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let maxCharacters = max(
            minimumChunkCharacters,
            (text.count + targetChunkCount - 1) / targetChunkCount
        )

        var chunks: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if current.count >= maxCharacters {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    static func chunkDelayNanoseconds(chunkCount: Int) -> UInt64 {
        guard chunkCount > 0 else { return 0 }
        return min(maxChunkDelayNanoseconds, totalAnimationBudgetNanoseconds / UInt64(chunkCount))
    }
}
