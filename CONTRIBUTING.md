# Contributing

Mimi is a macOS-first research and development project. Contributions should
keep the three products distinct:

- Mimi for Chrome: the browser extension.
- Mimi Setup for Chrome: the local setup/helper app and native host.
- Mimi for Mac: the native listening app.

## Local checks

Use the Node.js and Swift versions already available on your Mac. From a
fresh clone:

```bash
cd apps/mac/local-server && npm ci --ignore-scripts && npm run check && npm test
cd ../extension && npm run check && npm test
cd ../native-host && npm run check && npm test
cd ../MimiApp && swift test
cd ../MimiForMac && swift test
```

The setup smoke test is intentionally non-destructive:

```bash
MIMI_SETUP_TEST_MODE=1 /bin/zsh "apps/mac/setup/Mimi Setup.command"
```

Do not run real setup, Keychain, Chrome, or Gemini flows in automated tests.
Never commit `.env`, API keys, certificates, generated bundles, audio,
diagnostics, or private evidence. Keep changes focused and explain any
platform-specific limitation in the pull request.

