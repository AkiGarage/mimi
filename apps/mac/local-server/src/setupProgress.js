const fs = require("fs");
const path = require("path");

class SetupProgressStore {
  constructor(storagePath = defaultStoragePath()) {
    this.storagePath = storagePath;
    this.state = readState(storagePath);
  }

  snapshot() {
    return {
      listeningStarted: this.state.listeningStarted === true,
      listeningStartedAt: this.state.listeningStartedAt || null,
    };
  }

  markListeningStarted(now = new Date()) {
    const nextState = {
      listeningStarted: true,
      listeningStartedAt: now.toISOString(),
    };
    writeState(this.storagePath, nextState);
    this.state = nextState;
    return this.snapshot();
  }
}

function defaultStoragePath() {
  if (process.env.JP_DUB_SETUP_PROGRESS_FILE) {
    return path.resolve(process.env.JP_DUB_SETUP_PROGRESS_FILE);
  }
  return path.resolve(__dirname, "..", "..", "..", "..", "tmp", "mimi-setup-progress.json");
}

function readState(storagePath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(storagePath, "utf8"));
    return {
      listeningStarted: parsed?.listeningStarted === true,
      listeningStartedAt: validTimestamp(parsed?.listeningStartedAt) ? parsed.listeningStartedAt : null,
    };
  } catch (error) {
    if (error?.code !== "ENOENT") {
      console.warn(`Mimi setup progress could not be read (${error?.code || "invalid_data"}).`);
    }
    return { listeningStarted: false, listeningStartedAt: null };
  }
}

function tryMarkListeningStarted(store, onError = () => {}) {
  try {
    store.markListeningStarted();
    return true;
  } catch (error) {
    onError(error);
    return false;
  }
}

function markListeningStartedFromAudio(session, audio, store, onError = () => {}) {
  if (!audio?.length || session.successfulListeningRecorded === true) return false;
  const marked = tryMarkListeningStarted(store, onError);
  if (marked) session.successfulListeningRecorded = true;
  return marked;
}

function writeState(storagePath, state) {
  fs.mkdirSync(path.dirname(storagePath), { recursive: true });
  fs.writeFileSync(storagePath, `${JSON.stringify({
    version: 1,
    listeningStarted: state.listeningStarted === true,
    listeningStartedAt: state.listeningStartedAt || null,
  }, null, 2)}\n`);
}

function validTimestamp(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value);
}

module.exports = {
  SetupProgressStore,
  defaultStoragePath,
  markListeningStartedFromAudio,
  tryMarkListeningStarted,
};
