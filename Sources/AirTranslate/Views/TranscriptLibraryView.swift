import AppKit
import SwiftUI

private enum DraftEditorField: Hashable {
    case source
    case translation
}

struct TranscriptLibraryView: View {
    @Bindable var session: TranslationSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var focusedDraftEditor: DraftEditorField?
    @State private var draftEditorTextViews: [DraftEditorField: NSTextView] = [:]
    @State private var isDeleteSelectedConfirmationPresented = false
    @State private var isDeleteAllConfirmationPresented = false
    @State private var isCopyFeedbackVisible = false
    @State private var copyFeedbackToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(18)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 500)
        .confirmationDialog(
            AppText.deleteSavedTranscriptConfirmation,
            isPresented: $isDeleteSelectedConfirmationPresented
        ) {
            Button(AppText.deleteSavedTranscript, role: .destructive) {
                session.deleteSelectedTranscript()
            }
            Button(AppText.cancel, role: .cancel) {}
        }
        .confirmationDialog(
            AppText.deleteAllSavedTranscriptsConfirmation,
            isPresented: $isDeleteAllConfirmationPresented
        ) {
            Button(AppText.deleteAllSavedTranscripts, role: .destructive) {
                session.deleteAllSavedTranscripts()
            }
            Button(AppText.cancel, role: .cancel) {}
        }
        .onAppear {
            ensureSelection()
        }
        .onChange(of: session.savedTranscripts.count) { _, _ in
            ensureSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(AppText.savedTranscripts)
                    .font(.title3.weight(.semibold))

                Text(AppText.autoSaveDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Picker(AppText.savedTranscriptContent, selection: $session.savedTranscriptContentMode) {
                ForEach(SavedTranscriptContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)

            Button {
                session.openTranscriptsFolder()
            } label: {
                Label(AppText.openSaveFolder, systemImage: "folder")
            }

            Button(role: .destructive) {
                isDeleteAllConfirmationPresented = true
            } label: {
                Label(AppText.deleteAllSavedTranscripts, systemImage: "trash")
            }
            .disabled(session.savedTranscripts.isEmpty)
            .help(AppText.deleteAllSavedTranscriptsHelp)

            Button(AppText.close) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.savedTranscripts.isEmpty {
            ContentUnavailableView(
                AppText.savedEmpty,
                systemImage: "tray",
                description: Text(AppText.autoSaveDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                transcriptList
                    .frame(width: 260)

                Divider()

                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.savedTranscripts) { transcript in
                    Button {
                        session.selectSavedTranscript(transcript.id)
                    } label: {
                        TranscriptLibraryRow(
                            transcript: transcript,
                            isSelected: session.selectedSavedTranscriptID == transcript.id
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var editor: some View {
        if let selectedTranscript = session.selectedSavedTranscript {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(AppText.editSaved)
                        .font(.headline)

                    Spacer(minLength: 0)

                    Button {
                        session.polishSelectedTranscriptDraftWithFoundationModel()
                    } label: {
                        if session.isFoundationTranscriptCleanupRunning {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            Label(AppText.foundationModelCleanupShort, systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .disabled(!canCopyDraft || session.isFoundationTranscriptCleanupRunning)
                    .help(AppText.foundationModelCleanupHelp)
                    .accessibilityLabel(AppText.foundationModelCleanup)

                    Button {
                        if copyDraftText() {
                            showCopyFeedback()
                        }
                    } label: {
                        Image(systemName: isCopyFeedbackVisible ? "checkmark" : "clipboard")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCopyFeedbackVisible ? Color.accentColor : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isCopyFeedbackVisible ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(isCopyFeedbackVisible ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08))
                            }
                    }
                    .buttonStyle(.plain)
                    .help(isCopyFeedbackVisible ? AppText.copied : AppText.copy)
                    .accessibilityLabel(AppText.copy)
                    .disabled(!canCopyDraft)
                }

                draftEditor(for: selectedTranscript)

                HStack {
                    Button {
                        session.saveSelectedTranscriptEdits()
                    } label: {
                        Label(AppText.saveEdits, systemImage: "checkmark")
                    }
                    .keyboardShortcut("s", modifiers: [.command])

                    Spacer(minLength: 0)

                    Button(role: .destructive) {
                        isDeleteSelectedConfirmationPresented = true
                    } label: {
                        Label(AppText.deleteSavedTranscript, systemImage: "trash")
                    }
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView(AppText.noSavedTranscriptSelected, systemImage: "doc.text")
        }
    }

    @ViewBuilder
    private func draftEditor(for transcript: SavedTranscript) -> some View {
        if transcript.isOriginalAndTranslation {
            HStack(alignment: .top, spacing: 12) {
                draftEditorPane(
                    title: AppText.original,
                    text: $session.savedDraftSourceText,
                    field: .source
                )

                draftEditorPane(
                    title: AppText.translation,
                    text: $session.savedDraftTranslationText,
                    field: .translation
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            draftEditorPane(
                title: AppText.original,
                text: $session.savedDraftSourceText,
                field: .source
            )
        }
    }

    private func draftEditorPane(
        title: String,
        text: Binding<String>,
        field: DraftEditorField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                writingToolsButton(for: field)
                    .disabled(!hasDraftText(for: field))
            }

            WritingToolsTextEditor(
                text: text,
                field: field,
                focusedField: $focusedDraftEditor
            ) { field, textView in
                draftEditorTextViews[field] = textView
            }
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func writingToolsButton(for field: DraftEditorField) -> some View {
        Button {
            showWritingTools(for: field)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        }
        .buttonStyle(.plain)
        .help(AppText.appleIntelligenceWritingTools)
        .accessibilityLabel(AppText.appleIntelligenceWritingTools)
    }

    private var canCopyDraft: Bool {
        hasDraftText(for: .source) || hasDraftText(for: .translation)
    }

    private func hasDraftText(for field: DraftEditorField) -> Bool {
        let text = switch field {
        case .source:
            session.savedDraftSourceText
        case .translation:
            session.savedDraftTranslationText
        }
        return text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
    }

    private func copyDraftText() -> Bool {
        let sourceText = session.savedDraftSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = session.savedDraftTranslationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let copiedText: String

        if session.selectedSavedTranscript?.isOriginalAndTranslation == true, !translatedText.isEmpty {
            copiedText = "\(AppText.original)\n\(sourceText)\n\n\(AppText.translation)\n\(translatedText)"
        } else {
            copiedText = sourceText
        }

        guard !copiedText.isEmpty else { return false }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText, forType: .string)
        return true
    }

    private func showWritingTools(for field: DraftEditorField) {
        focusedDraftEditor = field
        DispatchQueue.main.async {
            guard let textView = draftEditorTextViews[field] else { return }
            textView.window?.makeFirstResponder(textView)
            NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: textView, from: nil)
        }
    }

    private func showCopyFeedback() {
        copyFeedbackToken += 1
        let token = copyFeedbackToken

        withAnimation(.snappy(duration: 0.16)) {
            isCopyFeedbackVisible = true
        }

        Task {
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                guard token == copyFeedbackToken else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    isCopyFeedbackVisible = false
                }
            }
        }
    }

    private func ensureSelection() {
        if let selectedSavedTranscriptID = session.selectedSavedTranscriptID,
           session.savedTranscripts.contains(where: { $0.id == selectedSavedTranscriptID }) {
            return
        }

        if let firstTranscript = session.savedTranscripts.first {
            session.selectSavedTranscript(firstTranscript.id)
        }
    }
}

private struct WritingToolsTextEditor: NSViewRepresentable {
    @Binding var text: String
    let field: DraftEditorField
    @Binding var focusedField: DraftEditorField?
    let onTextViewResolved: (DraftEditorField, NSTextView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.writingToolsBehavior = .complete
        textView.allowedWritingToolsResultOptions = .plainText

        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            onTextViewResolved(field, textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
        }

        if focusedField == field, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        DispatchQueue.main.async {
            onTextViewResolved(field, textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            coordinator.parent.onTextViewResolved(coordinator.parent.field, nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingToolsTextEditor
        weak var textView: NSTextView?

        init(_ parent: WritingToolsTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private struct TranscriptLibraryRow: View {
    let transcript: SavedTranscript
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: transcript.isOriginalAndTranslation ? "doc.on.doc.fill" : (isSelected ? "doc.text.fill" : "doc.text"))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.title)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    if transcript.isOriginalAndTranslation {
                        Text(AppText.originalAndTranslation)
                    }

                    Text(transcript.updatedAt, style: .date)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
