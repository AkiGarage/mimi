const assert = require("node:assert/strict");
const test = require("node:test");
const { settingsPageHtml } = require("../src/settingsPage");

function status(overrides = {}) {
  return {
    geminiApiKey: { configured: true, source: "keychain", canReplace: false },
    openaiApiKey: { configured: true, source: "keychain", canReplace: false },
    openaiBudget: { remainingSeconds: 1200, usedUsd: 0.1 },
    ...overrides,
  };
}

test("settings key forms are gated by each provider's own canReplace status", () => {
  const html = settingsPageHtml(status({
    geminiApiKey: { configured: true, source: "keychain", canReplace: true },
    openaiApiKey: { configured: true, source: "keychain", canReplace: true },
  }));
  assert.match(html, /<form data-provider="gemini">/);
  assert.match(html, /<form data-provider="openai">/);
  assert.doesNotMatch(html, /<form data-provider="xai">/);

  const noKeyForms = settingsPageHtml(status({
    geminiApiKey: { configured: true, source: "keychain", canReplace: false },
    openaiApiKey: { configured: true, source: "keychain", canReplace: false },
  }));
  assert.doesNotMatch(noKeyForms, /<form data-provider="gemini">/);
  assert.doesNotMatch(noKeyForms, /<form data-provider="openai">/);
});

test("settings page describes the OpenAI cap and omits removed xAI controls", () => {
  const html = settingsPageHtml(status());
  assert.match(html, /OpenAI hard safety cap/);
  assert.doesNotMatch(html, /xAI|Grok|grok|data-provider="xai"/);
});
