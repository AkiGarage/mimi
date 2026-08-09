const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  OPENAI_AUDIO_USD_PER_MINUTE,
  OPENAI_SAFE_CAP_SECONDS,
  OPENAI_SAFE_CAP_USD,
  OpenAIBudgetGuard,
  defaultStoragePath,
} = require("../src/openaiBudgetGuard");

function withStorage(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-openai-budget-"));
  const storagePath = path.join(root, "lifetime.json");
  try {
    return run(storagePath);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("OpenAI budget stops at the exact 28-minute safe boundary", () => {
  withStorage((storagePath) => {
    const guard = new OpenAIBudgetGuard({ storagePath });

    assert.equal(OPENAI_SAFE_CAP_SECONDS, 1680);
    assert.equal(OPENAI_SAFE_CAP_USD, 0.952);
    assert.equal(OPENAI_AUDIO_USD_PER_MINUTE, 0.034);
    assert.equal(guard.canUse(OPENAI_SAFE_CAP_SECONDS), true);
    assert.equal(guard.reserve(OPENAI_SAFE_CAP_SECONDS), true);
    assert.equal(guard.canUse(1), false);

    const snapshot = guard.snapshot();
    assert.equal(snapshot.usedSeconds, 1680);
    assert.equal(snapshot.remainingSeconds, 0);
    assert.equal(snapshot.remainingUsd, 0);
    assert.equal(snapshot.limitUsd, 0.952);
    assert.equal(snapshot.measured.label, "measured");
    assert.equal(snapshot.estimated.label, "estimated");
    assert.equal(snapshot.cost.label, "estimated");
  });
});

test("sub-second audio chunks are accumulated without per-chunk rounding", () => {
  withStorage((storagePath) => {
    const guard = new OpenAIBudgetGuard({ storagePath });
    assert.equal(guard.reserve(0.1), true);
    assert.equal(JSON.parse(fs.readFileSync(storagePath, "utf8")).usedSeconds, 0.1);

    for (let index = 1; index < 10; index += 1) {
      assert.equal(guard.reserve(0.1), true);
    }

    assert.equal(guard.snapshot().usedSeconds, 1);
    assert.ok(Math.abs(JSON.parse(fs.readFileSync(storagePath, "utf8")).usedSeconds - 1) < 1e-9);

    const reloaded = new OpenAIBudgetGuard({ storagePath });
    assert.equal(reloaded.canUse(OPENAI_SAFE_CAP_SECONDS - 1), true);
    assert.equal(reloaded.canUse(OPENAI_SAFE_CAP_SECONDS - 0.9), false);
  });
});

test("lifetime usage survives a guard reload and reserves before send", () => {
  withStorage((storagePath) => {
    const first = new OpenAIBudgetGuard({ storagePath });
    assert.equal(first.reserve(12.4), true);
    assert.equal(first.snapshot().usedSeconds, 13);

    const reloaded = new OpenAIBudgetGuard({ storagePath });
    const snapshot = reloaded.snapshot();
    assert.equal(snapshot.period, "lifetime");
    assert.equal(snapshot.scope, "mimi-lifetime");
    assert.equal(snapshot.usedSeconds, 13);
    assert.equal(snapshot.remainingSeconds, 1667);
    assert.equal(reloaded.canUse(1667), true);
    assert.equal(reloaded.canUse(1668), false);
  });
});

test("corrupt or unavailable persistence fails closed", () => {
  withStorage((storagePath) => {
    fs.writeFileSync(storagePath, "{not-json\n", "utf8");
    const corrupt = new OpenAIBudgetGuard({ storagePath });
    assert.equal(corrupt.canUse(1), false);
    assert.equal(corrupt.reserve(1), false);
    assert.equal(corrupt.snapshot().persistence.available, false);
    assert.equal(corrupt.snapshot().persistence.reason, "storage_corrupt");
    assert.equal(corrupt.snapshot().remainingSeconds, 0);
  });

  const unavailable = new OpenAIBudgetGuard({ storagePath: null });
  assert.equal(unavailable.canUse(1), false);
  assert.equal(unavailable.reserve(1), false);
  assert.equal(unavailable.snapshot().persistence.reason, "storage_unavailable");
});

test("OpenAI storage is Mimi-specific and has no reset API", () => {
  const storagePath = defaultStoragePath({});
  assert.match(path.basename(storagePath), /^mimi-openai-lifetime-usage\.json$/);
  const guard = new OpenAIBudgetGuard({ storagePath: null });
  assert.equal(typeof guard.reset, "undefined");
  assert.equal(typeof guard.resetUsage, "undefined");
});
