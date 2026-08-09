import Foundation
import Testing
@testable import AirTranslate

@Suite(.serialized)
struct RunningAppVersionTests {
    @Test
    func resolvesTheExecutableLoadedByTheCurrentProcess() {
        let executableURL = RunningAppVersion.processExecutableURL()

        #expect(executableURL.isFileURL)
        #expect(executableURL.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: executableURL.path))
    }

    @Test
    func readsMetadataBesideTheRunningExecutableBeforeUsingFallbackBundleInfo() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contentsURL = rootURL
            .appendingPathComponent("AirTranslate.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let executableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("AirTranslate", isDirectory: false)
        let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleShortVersionString": "1.5.1",
                "CFBundleVersion": "151"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: infoURL)

        let version = RunningAppVersion.current(
            executableURL: executableURL,
            fallbackInfoDictionary: [
                "CFBundleShortVersionString": "1.4.1",
                "CFBundleVersion": "141"
            ]
        )

        #expect(version == RunningAppVersion(version: "1.5.1", build: "151"))
        #expect(version.summary == "1.5.1 (151)")
    }

    @Test
    func fallsBackWhenTheExecutableIsNotInsideAnAppBundle() {
        let version = RunningAppVersion.current(
            executableURL: URL(fileURLWithPath: "/tmp/AirTranslate"),
            fallbackInfoDictionary: [
                "CFBundleShortVersionString": "1.5.1",
                "CFBundleVersion": "151"
            ]
        )

        #expect(version.summary == "1.5.1 (151)")
    }

    @Test
    func omitsBlankMetadataValues() {
        let version = RunningAppVersion.current(
            executableURL: URL(fileURLWithPath: "/tmp/AirTranslate"),
            fallbackInfoDictionary: [
                "CFBundleShortVersionString": "",
                "CFBundleVersion": ""
            ]
        )

        #expect(version.summary == nil)
    }
}
