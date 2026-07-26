# Mimi privacy policy draft

Status: draft for source review. No public policy URL is asserted by this
repository. A release owner must review and publish an appropriate policy
before any store listing or public service promise.

## What Mimi does

Mimi provides live translated audio for a user-opened Chrome tab or selected
Mac audio source. Mimi for Chrome, Mimi Setup for Chrome, and Mimi for Mac are
separate local products. Mimi is not a subtitle generator, video downloader,
finished-video exporter, cloud storage service, or managed translation API.

## Data boundary

After the user starts listening, the Chrome extension can capture the current
tab audio and send it to the local Mimi server. The local server can send that
live audio to Gemini Live Translate using the user's own API key. The native Mac
app follows the same live-only goal for a selected audio source.

Mimi does not intentionally create subtitle files, transcript archives,
downloaded videos, finished dubbed videos, or translated-audio caches. General
diagnostics and WAV capture are disabled by default. Explicit diagnostics must
remain redacted and local.

## API key and local storage

The Gemini API key is configured on the Mac side and is not stored in the
Chrome extension. Normal setup uses macOS Keychain. A local development
`.env` may be used only on the developer's machine; `.env.example` contains no
secret values. The extension stores UI preferences such as language and volume
locally. The helper stores setup state and safety-limit counters locally.

Mimi does not sell audio or use it for advertising. Do not place API keys,
transcripts, private URLs, or personal content in issues, logs, screenshots, or
support messages.

## User controls and limitations

The user starts and stops translation from Mimi for Chrome or Mimi for Mac and
can uninstall the extension and helper. Gemini availability, model behavior,
limits, and retention are controlled by the user's Gemini account and Google's
current terms. The source candidate has not made a public Store or binary
distribution promise; hardware, permission, long-duration, and accessibility
acceptance remain limited.

## Contact

Use the repository's current private security/contact channel for questions.
Do not disclose credentials or personal content when reporting a problem.
