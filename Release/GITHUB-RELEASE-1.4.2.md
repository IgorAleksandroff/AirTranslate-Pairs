# AirTranslate 1.4.2

Microphone permission packaging and signing fix.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Fixed

- Signed local and release app bundles now embed `com.apple.security.device.audio-input` with the Boolean value `true` under Hardened Runtime, allowing macOS to present the microphone permission request when microphone capture is selected.
- Release signing uses the release entitlement file only; the debug-only `get-task-allow` entitlement remains separate.
- The privacy-reset helper now resets Microphone permission, and the packaging verifier checks the entitlement values, signing configuration, Hardened Runtime, and microphone usage descriptions before distribution.

## Scope

- This patch contains only the microphone permission and release-signing fix for GitHub Issue #10.
- It does not include unrelated work currently under development.

## Verification

- 132 automated tests across 16 suites passed with the repository's Xcode toolchain.
- Release build, latest app relaunch, packaging-permission checks, localized README parity, and the fail-closed update-set audit passed.
- Both DMGs, their checksums, ZIP/DMG contents, app version metadata, code-signature integrity, embedded `audio-input=true`, and source/artifact secret scans passed.
- After resetting only AirTranslate's Microphone permission, macOS displayed the consent prompt; choosing **Allow** moved the app into the active listening state.
- The release remains ad-hoc signed and is not Apple-notarized.

## Download

- [Repository](https://github.com/himomohi/AirTranslate)
- [AirTranslate 1.4.2 release](https://github.com/himomohi/AirTranslate/releases/tag/v1.4.2)
- [Latest stable DMG download](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License. Release DMG and ZIP artifacts are ad-hoc signed and are not Apple-notarized; macOS may show an unidentified-developer warning on first launch.
