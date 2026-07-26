# Security

Please do not open a public issue for a suspected security vulnerability.
Report it privately to the repository owner through the contact method shown
on the repository profile, and include only the minimum reproducible detail.
Do not include API keys, credentials, private URLs, personal data, raw audio,
or transcripts.

Mimi is local-first software. The Chrome extension must not contain a Gemini
API key; the local Mac components keep credentials in the user's Keychain or
local development configuration. Before sharing diagnostics, redact keys,
tokens, URLs, transcripts, and personal content.

Supported security checks are documented in `CONTRIBUTING.md`. Security fixes
should preserve the BYOK boundary, loopback-only local server policy, native
messaging origin checks, and fail-closed usage limits.

