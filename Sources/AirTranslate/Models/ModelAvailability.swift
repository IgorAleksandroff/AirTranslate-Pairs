import Foundation

enum ModelAvailabilityState {
    case checking
    case installed
    case downloadRequired
    case downloading
    case unsupported
    case unavailable
    case failed

    var title: String {
        switch self {
        case .checking:
            AppText.modelStatusChecking
        case .installed:
            AppText.modelStatusInstalled
        case .downloadRequired:
            AppText.modelStatusDownloadRequired
        case .downloading:
            AppText.modelStatusDownloading
        case .unsupported:
            AppText.modelStatusUnsupported
        case .unavailable:
            AppText.modelStatusUnavailable
        case .failed:
            AppText.modelStatusFailed
        }
    }

    var canDownload: Bool {
        self == .downloadRequired || self == .failed
    }
}

struct ModelAvailability: Equatable {
    let state: ModelAvailabilityState
    let detail: String

    static func checking(for model: IntelligenceModel) -> ModelAvailability {
        ModelAvailability(state: .checking, detail: model.checkingDetail)
    }
}
