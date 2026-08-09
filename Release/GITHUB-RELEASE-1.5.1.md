# AirTranslate 1.5.1

AirTranslate 1.5.1 gives the macOS app a more consistent, minimal interface and makes every Settings section easier to understand and operate without changing the local-first Apple Mode default.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Added

- Added separate rows for Screen Recording, System Audio Recording, Microphone, and Speech Recognition, showing available status or directing users to verify it in System Settings, with focused actions and a refresh control.
- Added translation-language asset states for download requirement, progress, failure, and retry.
- Added visible app version and build details to the About section.

## Changed

- The main workspace, sidebar, menu bar, floating captions, transcript library, and all Settings sections now share a minimal design system for spacing, icon sizing, surfaces, selection, hover, and pressed feedback.
- Settings now distinguish saved API keys from replacement input, keep the floating-caption preview synchronized with its display mode, and explain unavailable controls in context.
- Keyboard navigation, Settings selection identity, accessibility labels and values, and Reduce Motion behavior are clearer and more consistent.

## Fixed

- The translated-voice volume control is now disabled while voice output is unavailable or off.
- API-key persistence now has one session-store writer instead of duplicate Settings-level Keychain writes.
- Startup now checks only non-secret Keychain metadata without showing authentication UI; the actual key is read only when an opted-in provider mode needs it.
- Failed translation-language assets can be downloaded again, and switching Settings sections no longer reuses an unrelated scroll position.

## Scope

- Apple Mode remains the default local-first transcription and translation path.
- GPT Realtime, GPT Transcription, and Gemini Live remain opt-in and continue to require user-provided API keys where applicable.
- This release changes interface presentation and Settings clarity; it does not broaden the app's data collection or add a backend account system.
- This release does not change the existing ad-hoc signing and non-notarized distribution status.

## Verification

- The release branch is verified with the repository's tests, release build, packaging permission checks, and an actual app launch.
- All nine Settings sections are reviewed in the running app for layout, keyboard navigation, visible state, and accessibility metadata.
- Release artifacts are rebuilt from the tagged source and checked for expected contents, checksum consistency, code-signature integrity, and sensitive files or secret patterns before upload.
- macOS Gatekeeper may still show an unidentified-developer warning because these open-source artifacts are ad-hoc signed and not Apple-notarized.

## Download

- [Repository](https://github.com/himomohi/AirTranslate)
- [AirTranslate 1.5.1 release](https://github.com/himomohi/AirTranslate/releases/tag/v1.5.1)
- [Latest stable DMG download](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License. Release DMG and ZIP artifacts are ad-hoc signed and are not Apple-notarized; macOS may show an unidentified-developer warning on first launch.
