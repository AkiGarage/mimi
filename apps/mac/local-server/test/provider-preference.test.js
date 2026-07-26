const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  ProviderPreferenceStore,
  normalizeProviderPreference,
} = require("../src/providerPreference");

test("provider preference defaults to Gemini and persists an explicit OpenAI choice", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-provider-preference-"));
  const filePath = path.join(root, "provider.json");

  try {
    const store = new ProviderPreferenceStore({ filePath });
    assert.equal(store.get(), "gemini");
    assert.equal(store.set("openai"), "openai");
    assert.equal(new ProviderPreferenceStore({ filePath }).get(), "openai");

    const saved = JSON.parse(fs.readFileSync(filePath, "utf8"));
    assert.deepEqual(saved, { version: 1, provider: "openai" });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("provider preference rejects unknown providers without changing the saved choice", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-provider-preference-"));
  const filePath = path.join(root, "provider.json");

  try {
    const store = new ProviderPreferenceStore({ filePath });
    store.set("openai");
    assert.throws(() => store.set("unknown"), /unsupported_provider/);
    assert.equal(store.get(), "openai");
    assert.equal(new ProviderPreferenceStore({ filePath }).get(), "openai");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("provider preference fails safely to Gemini when storage is corrupt", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-provider-preference-"));
  const filePath = path.join(root, "provider.json");

  try {
    fs.writeFileSync(filePath, "{broken");
    assert.equal(new ProviderPreferenceStore({ filePath }).get(), "gemini");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("legacy xAI and Grok preferences migrate to Gemini on disk", () => {
  for (const legacyProvider of ["xai", "grok"]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-provider-preference-"));
    const filePath = path.join(root, "provider.json");

    try {
      fs.writeFileSync(filePath, JSON.stringify({ version: 1, provider: legacyProvider }));
      assert.equal(new ProviderPreferenceStore({ filePath }).get(), "gemini");
      assert.deepEqual(JSON.parse(fs.readFileSync(filePath, "utf8")), { version: 1, provider: "gemini" });
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test("provider preference normalization is strict", () => {
  assert.equal(normalizeProviderPreference(" Gemini "), "gemini");
  assert.equal(normalizeProviderPreference("OPENAI"), "openai");
  assert.equal(normalizeProviderPreference("xAI"), "");
  assert.equal(normalizeProviderPreference("grok"), "");
  assert.equal(normalizeProviderPreference(""), "");
});
