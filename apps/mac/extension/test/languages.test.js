const assert = require("node:assert/strict");
const test = require("node:test");

const { MIMI_TARGET_LANGUAGES } = require("../src/languages.js");

test("English target remains single Live Translate en target", () => {
  const english = MIMI_TARGET_LANGUAGES.find((language) => language.code === "en");
  const regionalEnglish = MIMI_TARGET_LANGUAGES.filter((language) => /^en[-_]/i.test(language.code));

  assert.equal(english.name, "English");
  assert.equal(english.flag, "🇺🇸");
  assert.deepEqual(regionalEnglish, []);
});
