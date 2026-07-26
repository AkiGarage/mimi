const assert = require("node:assert/strict");
const test = require("node:test");
const {
  DEFAULT_OPENAI_KEYCHAIN_SERVICE,
  openAIApiKeyStatus,
  resolveOpenAIApiKey,
  saveOpenAIApiKey,
} = require("../src/secrets");

test("OpenAI key resolution ignores the general OPENAI_API_KEY environment variable", () => {
  const calls = [];
  const resolved = resolveOpenAIApiKey({
    env: { OPENAI_API_KEY: "must-not-be-used" },
    platform: "darwin",
    execFileSync: (_file, args) => {
      calls.push(args);
      return "mimi-keychain-key\n";
    },
  });
  assert.equal(resolved.value, "mimi-keychain-key");
  assert.equal(resolved.source, "keychain");
  assert.equal(resolved.keychainService, DEFAULT_OPENAI_KEYCHAIN_SERVICE);
  assert.equal(calls[0][2], DEFAULT_OPENAI_KEYCHAIN_SERVICE);
});

test("OpenAI key is saved to a separate Mimi Keychain service", () => {
  const calls = [];
  const status = saveOpenAIApiKey("mimi-openai-key", {
    env: {},
    platform: "darwin",
    helperPath: "/tmp/fake-mimi-helper",
    execFileSync: (file, args, options) => {
      calls.push({ file, args, input: options.input });
      if (file === "/usr/bin/security") return "mimi-openai-key\n";
      return "";
    },
  });
  assert.equal(calls[0].args[1], DEFAULT_OPENAI_KEYCHAIN_SERVICE);
  assert.equal(calls[0].input, "mimi-openai-key");
  assert.equal(status.configured, true);
  assert.equal(status.source, "keychain");
});

test("OpenAI key replacement ignores the general helper environment override", () => {
  const status = openAIApiKeyStatus({
    env: { JP_DUB_KEYCHAIN_HELPER: "/tmp/not-mimi" },
    platform: "linux",
  });
  assert.equal(status.canReplace, false);
});
