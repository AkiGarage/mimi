<p align="center">
  <img src="apps/mac/MimiForMac/Packaging/MimiAppIcon.png" alt="Mimi app icon" width="240">
</p>

<h1 align="center">Mimi</h1>

<p align="center">
  Live translated audio for Mac and Chrome
</p>

Mimi is a local-first Mac project for listening to live translated audio. This
source candidate contains three separate products:

- **Mimi for Chrome** is the Chrome extension. It captures the current tab only
  after you press Start and plays the translated stream returned by the local
  Mac server.
- **Mimi Setup for Chrome** is the local setup/helper app and native host. It
  installs the helper, checks the loopback server, and keeps the Chrome/native
  messaging boundary explicit.
- **Mimi for Mac** is the native Swift app. It captures selected Mac audio and
  plays live translated audio as a development build.

The source release is intentionally conservative. V1 does not create
subtitles, download videos, export finished videos, provide offline playback,
or cache translated audio. Audio is handled as a live stream; Mimi does not
keep a transcript or raw audio archive.

## Release status

Mimi for Chrome **0.1.1** is publicly available from the
[Chrome Web Store](https://chromewebstore.google.com/detail/mimi/oknekoaclmnljnlpmffphpiflcdeibgg).
The repository contains the next **0.1.2 source candidate**; that extension
version has not yet been uploaded, reviewed, or published in the Store.

The Chrome helper **Mimi Setup for Chrome 0.1.2** is available as a
[Developer ID signed and Apple-notarized download](https://github.com/AkiGarage/mimi/releases/download/v0.1.2/Mimi-0.1.2-macOS-notarized.zip).
Its [SHA-256 checksum](https://github.com/AkiGarage/mimi/releases/download/v0.1.2/Mimi-0.1.2-macOS-notarized.zip.sha256)
is published alongside it. Download the ZIP, move `Mimi.app` to Applications,
open it once, then follow Mimi Setup to install the Chrome native helper and
store the selected provider key in macOS Keychain.

The separate **Mimi for Mac** product remains a source/developer build.
Listening, permissions, sleep/wake, VoiceOver, and long-duration hardware
acceptance remain limited live checks.

## Privacy and BYOK

Mimi uses BYOK (Bring Your Own Key). Gemini and OpenAI API keys are configured
on the Mac side; the Chrome extension never stores them. Normal setup stores a
configured key in macOS Keychain; `.env.example` documents names only, and a
real `.env` must stay local and uncommitted.

When listening, the extension sends current-tab audio to the local Mimi server,
which sends the live stream only to the provider you explicitly select:
Gemini Live Translate (Google) or GPT Realtime (OpenAI). The selected
provider's current terms, data handling and retention practices, usage limits,
and charges apply. Mimi does not sell audio, use advertising trackers, or
upload a local diagnostic bundle automatically. Do not place keys, transcripts,
private URLs, or personal data in issues, logs, screenshots, or pull requests.
See
[SECURITY.md](SECURITY.md) and [docs/product/privacy-policy.md](docs/product/privacy-policy.md).

Internal compatibility identifiers still contain historical `jp-dub` names in
native-host paths and runtime settings. They are protocol compatibility
strings, not a request to rename or expose a private repository.

## Build and test from a fresh clone

Use a recent Node.js LTS and the Swift toolchain provided by macOS. The
commands below do not run a real Gemini, Chrome, or Keychain flow:

```bash
# Local server
(cd apps/mac/local-server && npm ci --ignore-scripts && npm run check && npm test)

# Chrome extension and native host
(cd apps/mac/extension && npm run check && npm test)
(cd apps/mac/native-host && npm run check && npm test)

# Swift products
swift test --package-path apps/mac/MimiApp
swift test --package-path apps/mac/MimiForMac

# Non-destructive setup smoke
MIMI_SETUP_TEST_MODE=1 /bin/zsh "apps/mac/setup/Mimi Setup.command"

# Product identity and package checks
node --test scripts/test/mimi-product-identity.test.cjs
node --test scripts/test/package-chrome-extension.test.cjs

# Local packaging outputs (ignored by Git)
node scripts/package-chrome-extension.cjs --out="$PWD/tmp/chrome-package"
node scripts/package-mimi-app.cjs \\
  --node="$(command -v node)" \\
  --dist="$PWD/tmp/mimi-app-package"
```

The packaging command builds an unsigned developer app and uses the local
Node.js runtime; it does not fetch a runtime, sign with Developer ID, notarize,
upload to the Chrome Web Store, or open a dashboard.

## Scope and contribution

This repository keeps the Mac products separate from the iPhone work. Please
read [CONTRIBUTING.md](CONTRIBUTING.md) before editing and keep generated
outputs, credentials, raw audio, and private operational evidence out of Git.

日本語の概要と制限は [README.ja.md](README.ja.md) を参照してください。
