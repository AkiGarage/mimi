function settingsPageHtml(status) {
  const geminiConfigured = status.geminiApiKey?.configured ? "Configured" : "Missing";
  const openaiConfigured = status.openaiApiKey?.configured ? "Configured" : "Missing";
  const geminiSource = escapeHtml(status.geminiApiKey?.source || "missing");
  const openaiSource = escapeHtml(status.openaiApiKey?.source || "missing");
  const remainingMinutes = Math.max(0, Number(status.openaiBudget?.remainingSeconds || 0) / 60).toFixed(1);
  const usedUsd = Number(status.openaiBudget?.usedUsd || 0).toFixed(3);
  const geminiForm = status.geminiApiKey?.canReplace ? `<form data-provider="gemini">
        <label>
          New Gemini API key
          <input class="apiKey" type="password" autocomplete="off" autofocus>
        </label>
        <button type="submit">Save Gemini key</button>
      </form>` : "";
  const openaiForm = status.openaiApiKey?.canReplace ? `<form data-provider="openai">
        <label>
          Mimi-only OpenAI API key
          <input class="apiKey" type="password" autocomplete="off">
        </label>
        <button type="submit">Save OpenAI key</button>
      </form>` : "";
  const keyForms = [geminiForm, openaiForm].filter(Boolean).join("\n") || `<p>Direct key replacement is not available from this local helper. Open the packaged Mimi app, or double-click <code>apps/mac/setup/Mimi Setup.command</code> from Finder.</p>`;
  const script = keyForms.includes("data-provider=") ? `<script>
      const message = document.getElementById("message");
      for (const form of document.querySelectorAll("form[data-provider]")) {
        form.addEventListener("submit", async (event) => {
          event.preventDefault();
          const provider = form.dataset.provider;
          const apiKey = form.querySelector(".apiKey");
          const value = apiKey.value.trim();
          apiKey.value = "";
          if (!value) {
            message.textContent = "Paste an API key first.";
            return;
          }
          const response = await fetch("/settings/api-key", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ provider, apiKey: value }),
          });
          const result = await response.json().catch(() => ({}));
          if (!response.ok || !result.ok) {
            message.textContent = result.error || "Could not save the key.";
            return;
          }
          document.getElementById(provider + "Status").textContent = "Configured";
          message.textContent = "Saved to Mimi's macOS Keychain item.";
        });
      }
    </script>` : "";
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Mimi Settings</title>
    <style>
      body {
        margin: 0;
        background: #f4f8fb;
        color: #172033;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      main {
        max-width: 520px;
        margin: 48px auto;
        padding: 24px;
      }
      h1 { margin: 0 0 8px; font-size: 28px; }
      p { color: #526070; line-height: 1.45; }
      form {
        display: grid;
        gap: 12px;
        margin-top: 20px;
      }
      label { display: grid; gap: 6px; font-weight: 700; }
      input, button {
        min-height: 42px;
        border: 1px solid #c8d5e2;
        border-radius: 8px;
        font: inherit;
        padding: 0 12px;
      }
      button {
        border-color: #0a84ff;
        background: #0a84ff;
        color: #fff;
        font-weight: 760;
      }
      #message { min-height: 22px; font-weight: 700; }
    </style>
  </head>
  <body>
    <main>
      <h1>Mimi Settings</h1>
      <p>Gemini API key: <strong id="geminiStatus">${geminiConfigured}</strong> (${geminiSource}). Free and default.</p>
      <p>OpenAI API key: <strong id="openaiStatus">${openaiConfigured}</strong> (${openaiSource}). It is stored in a separate Mimi-only Keychain item; Mimi never reads <code>OPENAI_API_KEY</code>.</p>
      <p><strong>OpenAI hard safety cap:</strong> ${remainingMinutes} min remaining; estimated used $${usedUsd}. The lifetime cap is 28 minutes (about $0.952) and cannot be reset here.</p>
      ${keyForms}
      <p id="message"></p>
    </main>
    ${script}
  </body>
</html>`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[character]));
}

module.exports = {
  settingsPageHtml,
};
