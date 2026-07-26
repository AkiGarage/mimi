# Mimi Native Host

This host lets the Chrome extension start the local Mimi server on demand.
It does not run at login and does not process audio. It only handles server
control messages.

## One-Time Install

For the normal Mimi development extension, the installer derives the fixed
extension origin from `apps/mac/extension/manifest.json`. Then run:

```bash
npm run install
```

Developer override:

```bash
npm run install -- --extension-origin=chrome-extension://your-custom-extension-id
```

The installer writes a tiny wrapper with the absolute Node.js path, then writes
the Chrome native messaging manifest to:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.akigarage.jp_dub.json
```

The wrapper is written to:

```text
~/Library/Application Support/JP Dub/NativeHost/jp-dub-native-host
```

After install, reload Mimi in Chrome. For the current repo development build,
that means reloading the unpacked extension; for a future Web Store build,
reload the installed extension.

## Runtime Behavior

- Extension `Start` checks whether the local server is already running.
- If not running, Chrome starts this host for one message.
- Extension `Restart Server & Start` stops the current session, restarts the local server, and starts Mimi on the active tab.
- The host starts the local server with `JP_DUB_IDLE_EXIT_SECONDS=600`.
- The host exits immediately after replying.
- The local server exits after it has no active sessions for 600 seconds.
