# AirTranslate Open Source Release Kit

This folder contains reproducible release materials for the Apache 2.0 open-source AirTranslate project.

## What This Adds

- A repeatable local app-bundle and ZIP build script.
- Screenshot and README assets for GitHub releases and project documentation.
- A privacy notice draft aligned with the current local-first app behavior.
- Version history for public source releases.

## Assumptions

- The app name remains `AirTranslate`.
- The bundle identifier is `dev.appcaster.AirTranslate`.
- The current release-candidate version is `1.5.0`.
- The project is published as Apache 2.0 open source.
- AirTranslate is an independent project and is not affiliated with Apple, OpenAI, or Google.
- The release bundle must never include user API keys, bearer tokens, signing private keys, provisioning profiles, or local `.env` files.

Override the defaults when needed:

```bash
BUNDLE_ID="com.example.AirTranslate" VERSION="1.5.0" BUILD_NUMBER="150"
```

## Local Release Build

This creates an ad-hoc signed app bundle and ZIP for local inspection or attaching to a GitHub release.

```bash
./Release/build_open_source_release.sh
```

To build a DMG for the pre-notarization GitHub Release install path:

```bash
./Release/build_open_source_release.sh dmg
```

To build both ZIP and DMG artifacts:

```bash
./Release/build_open_source_release.sh all
```

Outputs:

```text
Release/product/AirTranslate.app
Release/product/AirTranslate-<version>-<build>.zip
Release/product/AirTranslate-<version>.zip
Release/product/AirTranslate.dmg
Release/product/AirTranslate.dmg.sha256
Release/product/AirTranslate-<version>.dmg
Release/product/AirTranslate-<version>.dmg.sha256
```

`Release/product/` is generated output and should stay out of commits.

## Secret Safety Gate

Before committing or uploading a release candidate, run a secret scan over the source tree and current diff. The app may mention `OPENAI_API_KEY` as a Keychain account name, but it must not contain a real key value, bearer credential, signing private key, provisioning profile, or `.env` file.

Suggested local checks:

```bash
rg -n --hidden --glob '!.git/**' --glob '!.build/**' --glob '!Release/product/**' \
  -i 'bearer|private key|client secret|access token|refresh token|api key' .

git diff -- . ':(exclude).build/**' ':(exclude)Release/product/**' | \
  rg -n -i 'bearer|private key|client secret|access token|refresh token|api key'
```

## Public Release Checklist

- Confirm `swift build` passes.
- Confirm `swift test` passes.
- Confirm the release ZIP contains `LICENSE` and `NOTICE`.
- Confirm the release DMG opens and contains `AirTranslate.app` plus the Applications shortcut.
- Confirm `AirTranslate.dmg.sha256` matches the uploaded DMG.
- Confirm the release ZIP does not contain API keys, tokens, private keys, provisioning profiles, or `.env` files.
- Confirm OpenAI GPT mode still requires a user-provided key at runtime and does not bundle one.
- Confirm Gemini Live mode still requires a user-provided key at runtime and does not bundle one.
- Confirm `Release/product/` remains ignored.
- Publish the new GitHub Release without deleting previous release versions or tags.
