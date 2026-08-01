# AirTranslate 1.5.0

Apple Mode remains AirTranslate's default, local-first experience. This release makes its capture lifecycle more resilient and adds an optional GPT source-transcription mode for people who explicitly configure an OpenAI key.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Added

- Added **GPT Transcription** using `gpt-live-transcribe` for source-language captions without translation. It is opt-in and requires a user-provided OpenAI API key.
- Added regression coverage for mode selection and restoration, permission cancellation, stale callbacks, external capture stops, restart behavior, configuration locking, and speech-input backpressure.

## Changed

- Apple Mode start attempts now have generation-scoped ownership, so a late permission response, warm-up task, or callback from an older attempt cannot change a newer session.
- The app keeps session settings locked only while a start is in flight and reliably restores them after a blocked, cancelled, or failed start.

## Fixed

- An external user stop of system-audio capture now finishes normally: the transcript is saved, the session unlocks, and a later start works again.
- Speech-input backpressure now ends capture with a clear controlled error instead of silently discarding audio.
- Stale OpenAI and Gemini connection callbacks cannot overwrite the active session; provider failures are kept free of raw connection details in user-visible UI.

## Scope

- Apple Mode remains the default local-first transcription and translation path.
- GPT Transcription is separate from GPT live translation and is used only after the user selects it and supplies an OpenAI API key.
- This release does not change the existing ad-hoc signing and non-notarized distribution status.

## Verification

- The release branch passes the repository's Xcode toolchain tests and release build.
- Release artifacts are rebuilt from this tagged source, checked for expected contents, checksum consistency, code-signature integrity, and sensitive files or secret patterns before upload.
- macOS Gatekeeper may still show an unidentified-developer warning because these open-source artifacts are ad-hoc signed and not Apple-notarized.

## Download

- [Repository](https://github.com/himomohi/AirTranslate)
- [AirTranslate 1.5.0 release](https://github.com/himomohi/AirTranslate/releases/tag/v1.5.0)
- [Latest stable DMG download](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License. Release DMG and ZIP artifacts are ad-hoc signed and are not Apple-notarized; macOS may show an unidentified-developer warning on first launch.
