import Foundation

struct RunningAppVersion: Equatable {
    let version: String?
    let build: String?

    var summary: String? {
        switch (version, build) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, _):
            version
        case let (_, build?):
            build
        default:
            nil
        }
    }

    static func current(
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        fallbackInfoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> RunningAppVersion {
        let infoDictionary = packagedInfoDictionary(for: executableURL) ?? fallbackInfoDictionary
        return RunningAppVersion(
            version: normalizedString(
                infoDictionary["CFBundleShortVersionString"]
            ),
            build: normalizedString(
                infoDictionary["CFBundleVersion"]
            )
        )
    }

    private static func packagedInfoDictionary(for executableURL: URL) -> [String: Any]? {
        let infoURL = executableURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist", isDirectory: false)

        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let infoDictionary = propertyList as? [String: Any] else {
            return nil
        }

        return infoDictionary
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
