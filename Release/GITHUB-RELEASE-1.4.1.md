# AirTranslate 1.4.1

Translated-speech replay fixes for Apple mode dubbing.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Changed

- Apple-mode translated speech now waits for stable sentence boundaries during streaming before speaking a partial translation.
- Final translation text that arrives without punctuation still speaks immediately when the request completes.
- Dubbing speech progress is now covered by focused AirTranslateCore regression tests.

## Fixed

- Fixed translated speech repeating the tail of a restored sentence after a shorter streaming rewrite.
- Fixed near-duplicate finalization variants being spoken again.
- Fixed translated speech rereading text that was already visible when dubbing was enabled.
- Fixed short suffix replays while preserving legitimate later repeated phrases in the same session.

## Verification

- 132 automated tests across 16 suites passed with the repository's Xcode toolchain.
- Release-prep checks completed locally: `swift build -c release`, `./script/build_and_run.sh --verify`, `./Release/build_open_source_release.sh all`, update-set audit, DMG verification, checksum validation, app metadata inspection, code signature integrity, and source/artifact secret scans.

## Download

- For most users: Download `AirTranslate.dmg`, open it, and drag `AirTranslate.app` to Applications.
- For ZIP users: Download `AirTranslate-1.4.1.zip`.
- Versioned DMG assets are also attached as `AirTranslate-1.4.1.dmg` and `AirTranslate-1.4.1.dmg.sha256`.

## GitHub Links

- Repository: https://github.com/himomohi/AirTranslate
- AirTranslate 1.4.1 release: https://github.com/himomohi/AirTranslate/releases/tag/v1.4.1
- Latest DMG download: https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License.

This build uses an ad-hoc code signature and is not Apple-notarized. macOS may show an unidentified-developer warning on first launch. If that happens, Control-click or right-click `AirTranslate.app`, choose **Open**, then confirm **Open**.

You can verify the stable DMG with `AirTranslate.dmg.sha256`.

Older GitHub Releases remain available for users who need a previous version.
