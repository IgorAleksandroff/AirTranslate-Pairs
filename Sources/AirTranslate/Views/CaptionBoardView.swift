import AppKit
import SwiftUI

struct CaptionBoardView: View {
    @Bindable var session: TranslationSessionStore
    @State private var isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CaptionBoardHeader(
                session: session,
                isFloatingCaptionVisible: isFloatingCaptionVisible
            )

            CaptionTranscriptFeed(session: session)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncFloatingCaptionVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingCaptionWindowController.visibilityDidChangeNotification)) { _ in
            syncFloatingCaptionVisibility()
        }
    }

    private func syncFloatingCaptionVisibility() {
        isFloatingCaptionVisible = FloatingCaptionWindowController.isOpen
    }
}

private struct CaptionBoardHeader: View {
    @Bindable var session: TranslationSessionStore
    let isFloatingCaptionVisible: Bool

    var body: some View {
        SessionOverviewCard(
            session: session,
            title: AppText.transcriptWorkspace,
            subtitle: session.languageSummary,
            isRunning: session.isRunning,
            isStarting: session.isStarting,
            isPaused: session.isPaused,
            statusMessage: session.statusMessage,
            isFloatingCaptionVisible: isFloatingCaptionVisible
        )
    }
}

private struct CaptionTranscriptFeed: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var longSessionAutoScrollTask: Task<Void, Never>?

    private struct LatestLineKey: Equatable {
        let id: UUID
        let revision: Int
    }

    private var latestLineKey: LatestLineKey? {
        session.lines.last.map { LatestLineKey(id: $0.id, revision: $0.revision) }
    }

    var body: some View {
        if !session.hasTranscriptContent && !session.isRunning {
            ContentUnavailableView(
                AppText.noCaptionsYet,
                systemImage: "captions.bubble",
                description: Text(AppText.noCaptionsDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        } else {
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.shouldShowTranscript && session.lines.isEmpty {
                        Text(AppText.waitingForTranscript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            }
                    }

                    ForEach(session.lines) { line in
                        CaptionLineView(
                            line: line,
                            showsTranslationPane: session.shouldShowTranslationPane
                        )
                            .equatable()
                            .id(line.id)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity)
                            )
                    }
                }
                .padding(.vertical, 4)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
                    value: session.lines.count
                )
            }
            .onChange(of: latestLineKey) { oldValue, newValue in
                guard let newValue else { return }

                if newValue.id != oldValue?.id {
                    longSessionAutoScrollTask?.cancel()
                    longSessionAutoScrollTask = nil
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        proxy.scrollTo(newValue.id, anchor: .bottom)
                    }
                } else {
                    scrollToLatestRevision(newValue.id, proxy: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            longSessionAutoScrollTask?.cancel()
            longSessionAutoScrollTask = nil
        }
    }

    private func scrollToLatestRevision(_ id: UUID, proxy: ScrollViewProxy) {
        guard session.shouldCoalesceTranscriptAutoScroll else {
            proxy.scrollTo(id, anchor: .bottom)
            return
        }

        longSessionAutoScrollTask?.cancel()
        longSessionAutoScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(id, anchor: .bottom)
            longSessionAutoScrollTask = nil
        }
    }
}

private struct CaptionLineView: View, Equatable {
    let line: CaptionLine
    let showsTranslationPane: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line.id == rhs.line.id
            && lhs.line.revision == rhs.line.revision
            && lhs.showsTranslationPane == rhs.showsTranslationPane
    }

    var body: some View {
        Group {
            if showsTranslationPane {
                HStack(alignment: .top, spacing: 16) {
                    originalPane
                    translationPane
                }
            } else {
                originalPane
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var originalPane: some View {
        TranscriptPane(
            title: AppText.original,
            description: AppText.originalDescription,
            text: line.sourceText,
            displayText: line.sourceDisplayText,
            isPrimary: true
        )
    }

    private var translationPane: some View {
        TranscriptPane(
            title: AppText.translation,
            description: AppText.translationDescription,
            text: line.translatedText,
            displayText: line.translatedDisplayText,
            isPrimary: false
        )
    }
}

private struct TranscriptPane: View {
    let title: String
    let description: String
    let text: String
    let displayText: String
    let isPrimary: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTextOverflowing = false
    @State private var isReadingBack = false
    @State private var isCopyFeedbackVisible = false
    @State private var copyFeedbackToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Button {
                    if copyText() {
                        showCopyFeedback()
                    }
                } label: {
                    Image(systemName: isCopyFeedbackVisible ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCopyFeedbackVisible ? Color.accentColor : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isCopyFeedbackVisible ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isCopyFeedbackVisible ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08))
                        }
                }
                .buttonStyle(TranscriptPaneCopyButtonStyle())
                .controlSize(.small)
                .help(isCopyFeedbackVisible ? AppText.copied : AppText.copyTranscriptPane(title))
                .accessibilityLabel(AppText.copyTranscriptPane(title))
                .accessibilityValue(isCopyFeedbackVisible ? AppText.copied : AppText.copy)
                .disabled(!canCopy)
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollableTranscriptText(
                text: displayText,
                weight: isPrimary ? .regular : .medium,
                accessibilityLabel: title,
                isOverflowing: $isTextOverflowing,
                isReadingBack: $isReadingBack
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask {
                if isTextOverflowing && isReadingBack {
                    TranscriptScrollFadeMask()
                } else {
                    Rectangle()
                }
            }
        }
        .padding(18)
        .frame(height: 360, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .task(id: copyFeedbackToken) {
            guard isCopyFeedbackVisible else { return }

            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isCopyFeedbackVisible = false
            }
        }
    }

    private var canCopy: Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
            && text != AppText.translating
    }

    private func copyText() -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText != AppText.translating else { return false }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmedText, forType: .string)
        return true
    }

    private func showCopyFeedback() {
        copyFeedbackToken += 1

        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) {
            isCopyFeedbackVisible = true
        }
    }
}

private struct TranscriptPaneCopyButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.88 : 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct TranscriptScrollFadeMask: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)

            Rectangle()
                .fill(.black)

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
        }
    }
}

private struct ScrollableTranscriptText: NSViewRepresentable {
    let text: String
    let weight: NSFont.Weight
    let accessibilityLabel: String
    @Binding var isOverflowing: Bool
    @Binding var isReadingBack: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isOverflowing: $isOverflowing, isReadingBack: $isReadingBack)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.setAccessibilityLabel(accessibilityLabel)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(accessibilityLabel)

        scrollView.documentView = textView
        context.coordinator.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let contentWidth = scrollView.contentSize.width
        let textChanged = textView.string != text
        let widthChanged = abs(context.coordinator.lastContentWidth - contentWidth) > 0.5
        let weightChanged = context.coordinator.lastWeight != weight
        guard textChanged || widthChanged || weightChanged else { return }

        let shouldStayPinnedToBottom = isPinnedToBottom(scrollView)
        if textChanged {
            textView.string = text
        }

        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        textView.textColor = .labelColor
        scrollView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let documentHeight = updateDocumentSize(textView, in: scrollView)
        context.coordinator.recordLayoutInput(
            contentWidth: contentWidth,
            weight: weight
        )
        let isOverflowing = documentHeight > scrollView.contentSize.height + 1
        context.coordinator.updateState(
            isOverflowing: isOverflowing,
            isReadingBack: isOverflowing && !shouldStayPinnedToBottom
        )

        if shouldStayPinnedToBottom {
            textView.scrollToEndOfDocument(nil)
            context.coordinator.updateState(isOverflowing: isOverflowing, isReadingBack: false)
        }
    }

    private func updateDocumentSize(_ textView: NSTextView, in scrollView: NSScrollView) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            textView.frame.size = scrollView.contentSize
            return scrollView.contentSize.height
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
        textView.frame.size = NSSize(
            width: scrollView.contentSize.width,
            height: max(scrollView.contentSize.height, usedHeight)
        )
        return usedHeight
    }

    private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }

        let visibleMaxY = scrollView.contentView.bounds.maxY
        let documentHeight = documentView.bounds.height
        return documentHeight <= scrollView.contentSize.height || documentHeight - visibleMaxY < 24
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isOverflowing: Binding<Bool>
        private var isReadingBack: Binding<Bool>
        private weak var scrollView: NSScrollView?
        var lastContentWidth: CGFloat = -1
        var lastWeight: NSFont.Weight?

        init(isOverflowing: Binding<Bool>, isReadingBack: Binding<Bool>) {
            self.isOverflowing = isOverflowing
            self.isReadingBack = isReadingBack
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to scrollView: NSScrollView) {
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func updateState(isOverflowing: Bool, isReadingBack: Bool) {
            guard self.isOverflowing.wrappedValue != isOverflowing
                || self.isReadingBack.wrappedValue != isReadingBack
            else {
                return
            }

            self.isOverflowing.wrappedValue = isOverflowing
            self.isReadingBack.wrappedValue = isReadingBack
        }

        func recordLayoutInput(contentWidth: CGFloat, weight: NSFont.Weight) {
            lastContentWidth = contentWidth
            lastWeight = weight
        }

        @objc private func contentBoundsDidChange() {
            guard let scrollView else { return }
            let isOverflowing = hasOverflow(scrollView)
            updateState(
                isOverflowing: isOverflowing,
                isReadingBack: isOverflowing && !isPinnedToBottom(scrollView)
            )
        }

        private func hasOverflow(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return false }
            return documentView.bounds.height > scrollView.contentSize.height + 1
        }

        private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }

            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = documentView.bounds.height
            return documentHeight <= scrollView.contentSize.height || documentHeight - visibleMaxY < 24
        }
    }
}

private struct SessionOverviewCard: View {
    let session: TranslationSessionStore
    let title: String
    let subtitle: String
    let isRunning: Bool
    let isStarting: Bool
    let isPaused: Bool
    let statusMessage: String
    let isFloatingCaptionVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isFloatingCaptionVisible {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                }
                .help(headerIconHelp)
                .accessibilityLabel(title)
                .accessibilityValue(headerIconValue)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78),
                    value: isFloatingCaptionVisible
                )

            Group {
                if isRunning {
                    HeaderAudioLevelStrip(
                        session: session,
                        isPaused: isPaused
                    )
                } else {
                    HeaderStatusMessage(
                        statusMessage: statusMessage,
                        isStarting: isStarting,
                        isBlocked: isBlocked
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var headerIconHelp: String {
        "\(title) · \(subtitle) · \(AppText.floatingCaptions): \(floatingCaptionStateTitle)"
    }

    private var headerIconValue: String {
        "\(subtitle), \(AppText.floatingCaptions) \(floatingCaptionStateTitle)"
    }

    private var floatingCaptionStateTitle: String {
        isFloatingCaptionVisible ? AppText.floatingCaptionPowerOn : AppText.floatingCaptionPowerOff
    }

    private var isBlocked: Bool {
        !isRunning
            && !isStarting
            && statusMessage != AppText.ready
            && statusMessage != AppText.stopped
            && statusMessage != AppText.transcriptSavedToast
    }
}

private struct HeaderStatusMessage: View {
    let statusMessage: String
    let isStarting: Bool
    let isBlocked: Bool

    private var symbolName: String {
        if isStarting {
            return "clock"
        }
        if isBlocked {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var foregroundStyle: Color {
        if isStarting {
            return .accentColor
        }
        if isBlocked {
            return .orange
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            if isStarting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(foregroundStyle)
                    .frame(width: 16, height: 16)
            }

            Text(statusMessage)
                .font(.caption.weight(isBlocked ? .semibold : .medium))
                .foregroundStyle(foregroundStyle)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(foregroundStyle.opacity(isBlocked ? 0.12 : 0.08), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(foregroundStyle.opacity(isBlocked ? 0.28 : 0.14), lineWidth: 1)
        }
        .help(statusMessage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusMessage)
    }
}

private struct HeaderAudioLevelStrip: View {
    let session: TranslationSessionStore
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        isPaused ? AppText.paused : AppText.listening
    }

    private var foregroundStyle: Color {
        isPaused ? .orange : .green
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(foregroundStyle.opacity(isPaused ? 0.14 : 0.11))

            Capsule(style: .continuous)
                .strokeBorder(foregroundStyle.opacity(isPaused ? 0.34 : 0.42), lineWidth: 1)

            HStack(spacing: 8) {
                if isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(foregroundStyle)
                }

                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(1)

                if !isPaused {
                    AudioLevelWaveform(
                        level: session.latestAudioLevel,
                        date: Date(),
                        barCount: 8,
                        width: 62,
                        height: 20,
                        barWidth: 3.2,
                        barSpacing: 2.4
                    )
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 164, height: 34)
        .shadow(color: foregroundStyle.opacity(isPaused ? 0 : 0.18), radius: 12)
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .animation(
            reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82),
            value: isPaused
        )
    }

}

private struct AudioLevelWaveform: View {
    let level: Float?
    let date: Date
    var barCount = 5
    var width = 25.0
    var height = 24.0
    var barWidth = 3.8
    var barSpacing = 3.0

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(barFill(for: index))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private var normalizedLevel: Double {
        guard let level else { return 0.18 }

        let clampedLevel = min(max(Double(level), -60), -12)
        return (clampedLevel + 60) / 48
    }

    private func barHeight(for index: Int) -> Double {
        let centerDistance = abs(Double(index) - Double(barCount - 1) / 2)
        let centerBoost = max(0.54, 1 - (centerDistance * 0.055))
        let phase = date.timeIntervalSinceReferenceDate * 7.5 + Double(index) * 0.82
        let movement = (sin(phase) + 1) / 2
        let dynamicLevel = 0.18 + normalizedLevel * 0.82
        let computedHeight = 5 + (dynamicLevel * centerBoost * (0.66 + movement * 0.42) * (height - 5))

        return min(max(computedHeight, 5), height)
    }

    private func barFill(for index: Int) -> Color {
        let quietOpacity = 0.44 + Double(index) * 0.035
        return Color.green.opacity(min(0.92, 0.46 + normalizedLevel * quietOpacity))
    }
}
