import Foundation
import Observation
import SwiftUI
@preconcurrency import Translation

/// Downloads Apple Translation language assets for a pair that is supported but not installed.
///
/// `TranslationSession(installedSource:target:)` never downloads — it fails with `notInstalled`.
/// Only a session vended by SwiftUI's `translationTask` makes the system offer the download,
/// so requests are parked here and executed by `TranslationAssetDownloadHost` in an open window.
@MainActor
@Observable
final class TranslationAssetDownloader {
    static let shared = TranslationAssetDownloader()

    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var pending: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var hostCount = 0

    func download(source: LanguageOption, target: LanguageOption) async throws {
        guard hostCount > 0 else { throw TranslationAssetDownloadError.noHostWindow }
        guard pending == nil else { throw TranslationAssetDownloadError.alreadyInProgress }

        defer {
            pending = nil
            configuration = nil
        }
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: source.id),
                target: Locale.Language(identifier: target.id)
            )
        }
    }

    fileprivate func perform(_ session: TranslationSession) async {
        guard let continuation = pending else { return }
        pending = nil
        do {
            try await session.prepareTranslation()
            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
    }

    fileprivate func registerHost() {
        hostCount += 1
    }

    fileprivate func unregisterHost() {
        hostCount -= 1
        guard hostCount == 0, let continuation = pending else { return }
        pending = nil
        configuration = nil
        continuation.resume(throwing: TranslationAssetDownloadError.noHostWindow)
    }
}

enum TranslationAssetDownloadError: LocalizedError {
    case noHostWindow
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .noHostWindow:
            AppText.translationDownloadNeedsOpenWindow
        case .alreadyInProgress:
            AppText.translationDownloadAlreadyInProgress
        }
    }
}

/// Invisible carrier of the system download prompt; place it in every window that can start a download.
struct TranslationAssetDownloadHost: View {
    private let downloader = TranslationAssetDownloader.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .translationTask(downloader.configuration) { session in
                await downloader.perform(session)
            }
            .onAppear { downloader.registerHost() }
            .onDisappear { downloader.unregisterHost() }
    }
}
