# Changelog

All notable changes to AirTranslate are documented in this file.

## Unreleased

No unreleased changes yet.

## 1.5.1 - 2026-08-09

### Added

- Added per-permission rows with available status or System Settings verification guidance, focused settings actions and refresh, translation-asset progress/error/retry states, and app version/build details.

### Changed

- Redesigned the main workspace, sidebar, menu bar, floating captions, transcript library, and all Settings panes around one minimal visual system for spacing, icons, surfaces, selection, and hover feedback.
- Settings now explain saved-versus-replacement API keys, show a floating-caption preview that follows the selected display mode, and make control dependencies easier to understand.
- Improved keyboard navigation, selection identity, accessibility labels and values, and Reduce Motion behavior across the redesigned surfaces.

### Fixed

- Disabled the translated-voice volume control whenever voice output is unavailable or off, with an explicit explanation of the dependency.
- Consolidated API-key persistence behind the session store so Settings no longer performs duplicate Keychain writes.
- Made failed translation-language assets downloadable again and preserved each Settings pane's scroll identity while switching sections.

## 1.5.0 - 2026-08-02

### Added

- Added the optional `gpt-live-transcribe` GPT Transcription mode for source-language captions. It requires a user-provided OpenAI API key; Apple Mode remains the default local-first path.
- Added focused regression coverage for GPT transcription selection and restore behavior, session configuration locking, permission cancellation, external capture stops, and speech-input backpressure.

### Changed

- Apple Mode now treats a start attempt as one generation-scoped session: permission waits, warm-up work, and callbacks from an old attempt cannot alter a newer session.
- Settings remain locked while a capture start is in flight and are restored after a blocked, cancelled, or failed start.

### Fixed

- Fixed Apple system-audio sessions so an external user stop saves the transcript, releases the session state, and allows a clean restart.
- Fixed live speech input backpressure so audio is never silently discarded; the app stops with a visible controlled error instead.
- Fixed stale OpenAI and Gemini connection callbacks and provider errors from overriding the active session, and keep user-visible provider failures free of raw connection details.

## 1.4.2 - 2026-07-31

### Fixed

- Fixed local and release app signing so the signed bundle embeds the required microphone audio-input entitlement under Hardened Runtime.
- Fixed the privacy-reset helper to reset Microphone permission alongside the other AirTranslate capture permissions.
- Added a packaging permission check that verifies the release/debug entitlement split, embedded entitlement values, Hardened Runtime, and microphone usage descriptions.

## 1.4.1 - 2026-07-24

### Changed

- Translated speech output in Apple mode now waits for stable sentence boundaries during streaming and still speaks final translation text that arrives without punctuation.
- Dubbing progress is now tracked by a focused core helper so speech-output replay behavior can be tested independently from the main session store.

### Fixed

- Fixed Apple-mode translated speech repeating restored sentence tails after shorter streaming rewrites.
- Fixed translated speech replaying near-duplicate finalization variants or rereading text that was already visible when dubbing was enabled.
- Fixed short repeated suffixes such as repeated closing words being spoken again while still allowing legitimate repeated phrases later in the session.

## 1.4.0 - 2026-07-10

### Added

- Added 30-second in-session transcript checkpoints that update the same files without stopping capture.
- Added native macOS capture shortcuts for start/stop and pause/resume.
- Added focused regression coverage for long sessions, realtime transcript tails, provider retries, floating-window placement, and translated-speech backlog behavior.

### Changed

- Long Apple sessions now coalesce recognition and presentation updates automatically after 4,000 characters, move expensive translation preparation off the MainActor, and use a bounded LRU segment cache.
- Gemini Live now configures low-latency activity detection and buffers a bounded amount of audio while setup completes.
- OpenAI text translation now streams partial results, applies bounded request timeouts, and retries rate-limit or server failures once.
- Realtime translated audio and Apple speech output now bound stale backlog instead of drifting farther behind live captions.
- The main workspace, sidebar, menu bar, floating captions, and settings surfaces now use clearer state hierarchy, keyboard access, and reduced-motion behavior.

### Fixed

- Fixed suppressed realtime transcript tails and empty completion events losing the last recognized words.
- Fixed pause, stop, and app termination paths so pending caption text is flushed before saving.
- Fixed floating caption windows reopening outside the visible area after display changes.
- Fixed Gemini connection failures potentially exposing an authenticated WebSocket URL in user-visible error text.

## 1.3.6 - 2026-06-13

### Added

- Added Gemini 3.5 Live Translate mode for direct live audio translation with input and output transcripts.
- Added Gemini API key storage and missing-key guidance alongside the existing OpenAI key workflow.
- Added a compact LIVE Translation entry point for API-backed GPT and Gemini modes.
- Added sidebar voice-output controls with a single volume slider for translated speech.

### Changed

- GPT mode now uses the realtime translation path only and shows source transcript updates returned by the realtime session.
- API-backed modes now use a shared translated-audio output path and default voice output on.
- Apple basic mode keeps voice output off by default while still allowing users to enable it manually.
- Settings and sidebar mode controls were redesigned so Apple, GPT Realtime, and Gemini Live are clearly separated.

### Fixed

- Fixed the quick source-language button path so changing the source language no longer silently switches to Transcribe Only mode.
- Fixed GPT realtime translation sessions not showing the original transcript.
- Fixed translated audio playback so GPT and Gemini live modes output the translated voice through one speaker path.
- Fixed Apple basic-mode translated speech output lowering the Mac system volume.

## 1.3.5 - 2026-06-13

### Changed

- Saved transcript history now loads lightweight previews first and opens full text only when a transcript is selected.
- Realtime GPT transcript updates are coalesced to reduce MainActor and UI churn during long sessions.
- Realtime audio send backlog is bounded so stalled websocket sends cannot accumulate without limit.
- Capture start now waits for previous stop teardown before opening a new capture session.

### Fixed

- Very large transcript panes now render a bounded display tail even in standard session mode while preserving the full saved text.
- GPT translated audio output now decodes base64 audio on the audio queue instead of the MainActor path.

## 1.3.4 - 2026-05-26

### Changed

- Floating caption wrapping now scales with the selected text size so larger caption fonts keep more usable text on screen.

### Applied Pull Requests

- Applied `lidge-jun` / YEEE's PR #6, "fix: scale floating caption wrapping by text size", as the 1.3.4 user-facing floating-caption improvement.

## 1.3.3 - 2026-05-26

### Added

- Added a clearer Transcribe Only output mode that hides the translation pane and keeps the live workspace focused on the original transcript.

### Changed

- Floating captions now preserve readable line wrapping while streaming and stay original-only while Transcribe Only mode is active.
- Transcribe Only mode now keeps its hidden target language synchronized with the visible source language so changing the source language does not silently switch back to Translation mode.

### Fixed

- Prevented translation-only floating caption display choices from creating blank captions while Transcribe Only mode is active.

### Applied Pull Requests

- Applied `lidge-jun` / YEEE's PR #4, "fix: wrap floating captions while streaming", as part of the 1.3.3 floating-caption behavior.
- Applied `lidge-jun` / YEEE's PR #5, "fix: improve transcribe-only mode behavior", with follow-up fixes for hidden target-language sync and Transcribe Only floating-display limits.
- Included PR #7, "Release AirTranslate 1.3.3", by `himomohi` / Appcaster to ship the aligned version, release notes, artifacts, and harness record.
- Release preparation also includes `lidge-jun` / YEEE's PR #3, "docs: add repository structure guide".

## 1.3.2 - 2026-05-17

### Fixed

- Centered the empty transcript placeholder so the no-captions state no longer sits too high in the main workspace.

## 1.3.1 - 2026-05-16

### Changed

- Temporarily disabled Apple basic-mode source-language auto-detection while the mid-session language-switch behavior is improved.
- Added an in-app notice when the disabled auto-detect toggle is clicked.
- Updated release packaging metadata for the 1.3.1 hotfix build.

### Fixed

- Prevented previously saved auto-detect settings from enabling the feature in the current build.

## 1.3.0 - 2026-05-16

### Added

- Added input support for built-in, Bluetooth, and AirPods microphones.
- Added source-language auto-detection for Apple basic mode when the input stream makes source language inference possible.

### Changed

- Improved microphone pipeline handling for long-running sessions to reduce duplicate input spikes.

### Fixed

- Fixed unstable microphone source behavior that could duplicate incoming segments.
- Improved input handling when switching between system audio and microphone capture.

## 1.2.1 - 2026-05-14

### Changed

- Apple mode now resets GPT transcription and translation model state when selected.
- Apple and GPT mode switching now uses shared session helpers to keep visible mode and internal processing state aligned.

### Fixed

- Fixed Apple default mode translation staying inactive while live transcription continued.
- Translation unavailable states now appear in the translation output instead of leaving the pane stuck on `Translating...`.

## 1.2.0 - 2026-05-13

### Added

- Added optional OpenAI Realtime transcription and translation modes for GPT-powered captions.
- Added a realtime translation-only model path with optional translated audio playback.
- Added macOS Keychain storage for user-provided OpenAI API keys.
- Added English, Korean, Japanese, and Simplified Chinese README files.
- Added separate Apple Intelligence Writing Tools buttons for the original and translation panes in the saved transcript editor.
- Added grouped saved transcript display for original-plus-translation saves.

### Changed

- GPT realtime floating captions now show only the current live caption unit instead of the accumulated transcript, so the overlay behaves more like movie subtitles.
- GPT realtime delta handling now builds the current utterance before publishing it to the caption flow.
- GPT modes disable transcript lint cleanup so realtime model output is not rewritten by Apple spell-check cleanup.
- Saved `Original + Translation` transcripts are now stored as separate `*_original.txt` and `*_translation.txt` files that share the same base name.
- The library presents those paired files as one saved transcript and shows original and translation editors in the same detail section.
- The saved transcript editor now uses plain `NSTextView` editors for Writing Tools so macOS treats each pane as editable plain text.
- The library row hit area now spans the full row, making saved transcript selection easier.

### Fixed

- Reduced duplicate source and translation text after paragraph cleanup or settings changes.
- Fixed GPT realtime floating captions so the overlay shows only the current live caption unit instead of the accumulated transcript.

## 1.1.0 - 2026-05-10

### Added

- Added a centered live audio waveform meter that reacts to captured system-audio decibel levels while capture is running.
- Added visible hover, pressed, active, and short click-confirmation feedback to the header transport controls.

### Changed

- Moved the live audio waveform out of the right-side button cluster into a wider center header area.
- Increased audio-level reporting frequency so the waveform responds more smoothly to current input.
- Kept stop, pause/resume, and floating-caption controls grouped on the right while preserving accessibility labels and values.

## 2026-05-09 - Library Modal UI

### Added

- Added a saved transcript content selector for original, original plus translation, or translation-only output.
- Added a confirmation-protected delete-all action for saved transcript files.

### Changed

- Moved saved transcript management out of the sidebar into a focused modal library view.
- Kept the sidebar storage area as a compact entry point for opening saved transcript management.

## 2026-05-09 - Transcript Control and Stability

### Added

- Added a settings control for the silence interval that starts a new transcript paragraph.
- The paragraph break interval keeps the previous default of 5 seconds and can now be adjusted from 1 to 15 seconds in 0.5 second steps.

### Fixed

- Limited live speech analyzer input buffering to the latest 32 audio chunks so delayed analysis cannot grow an unbounded queue.
- Limited the live translation segment cache to 240 recent entries and reset it when the session, language, or model changes.
- Disabled streaming text animation for long transcript updates to reduce SwiftUI layout and attributed-text work during long sessions.
