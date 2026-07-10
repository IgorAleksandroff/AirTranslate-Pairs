# AirTranslate 1.4.0

Long-session responsiveness, lower live-translation latency, and clearer macOS-native controls.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Added

- Added 30-second transcript checkpoints while capture remains active.
- Added native macOS shortcuts: `Command-Return` for start/stop and `Shift-Command-Space` for pause/resume.
- Added regression coverage for long sessions, realtime transcript completion, provider retries, window placement, and speech backlog limits.

## Changed

- Apple basic mode now coalesces very long transcript updates, prepares large translation input off the MainActor, and uses a bounded LRU translation cache.
- Gemini Live now uses explicit low-latency voice activity detection and bounded pre-setup audio buffering.
- OpenAI text translation streams partial results and applies bounded timeouts and retry behavior.
- Realtime and synthesized translated speech now discard stale backlog instead of drifting progressively behind.
- Workspace, sidebar, menu bar, floating captions, and settings now provide clearer state labels, keyboard access, accessibility labels, and reduced-motion behavior.

## Fixed

- Preserved the last recognized words when realtime completion is empty or a throttled tail is still pending.
- Flushed pending captions before pause, stop, termination, and final transcript save.
- Repositioned floating captions when a previously used display is disconnected.
- Prevented authenticated Gemini WebSocket URLs from appearing in user-visible network errors.

## Verification

- 123 automated tests across 15 suites.
- 30-minute Apple basic-mode browser-audio session with stable GUI response and bounded memory.
- Release ZIP and DMG structure, checksums, app metadata, code signature integrity, and secret scans verified locally.

## Download

- For most users: Download `AirTranslate.dmg`, open it, and drag `AirTranslate.app` to Applications.
- For ZIP users: Download `AirTranslate-1.4.0.zip`.
- Versioned DMG assets are also attached as `AirTranslate-1.4.0.dmg` and `AirTranslate-1.4.0.dmg.sha256`.

## GitHub Links

- Repository: https://github.com/himomohi/AirTranslate
- AirTranslate 1.4.0 release: https://github.com/himomohi/AirTranslate/releases/tag/v1.4.0
- Latest DMG download: https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License.

This build uses an ad-hoc code signature and is not Apple-notarized. macOS may show an unidentified-developer warning on first launch. If that happens, Control-click or right-click `AirTranslate.app`, choose **Open**, then confirm **Open**.

You can verify the stable DMG with `AirTranslate.dmg.sha256`.

Older GitHub Releases remain available for users who need a previous version.
