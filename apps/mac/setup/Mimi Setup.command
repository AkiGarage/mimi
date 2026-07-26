#!/bin/zsh
# This .command intentionally stays in a conservative bash/zsh subset.
# macOS double-click follows the shebang; manual `zsh ...` and `bash ...`
# execution are both supported and covered by the setup validator.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
LOCAL_SERVER_DIR="$ROOT_DIR/apps/mac/local-server"
ENV_FILE="$LOCAL_SERVER_DIR/.env"
NATIVE_HOST_DIR="$ROOT_DIR/apps/mac/native-host"
EXTENSION_DIR="$ROOT_DIR/apps/mac/extension"
DIALOG_LOG="$ROOT_DIR/tmp/mimi-setup-dialog.log"
DIALOG_CANCELLED="__MIMI_DIALOG_CANCELLED__"
KEYCHAIN_SERVICE="Mimi Gemini API Key"
KEYCHAIN_ACCOUNT="default"
DEFAULT_TARGET_LANGUAGE="ja"
DEFAULT_MONTHLY_LIMIT_MINUTES=30
SETUP_IDLE_EXIT_SECONDS=600
STATUS_RETRY_SECONDS=30
USAGE_FILE="$ROOT_DIR/tmp/jp-dub-usage.json"
AI_STUDIO_HOME_URL="https://aistudio.google.com/"
AI_STUDIO_API_KEYS_URL="https://aistudio.google.com/api-keys"
CHROME_EXTENSIONS_URL="chrome://extensions/"
MONTHLY_LIMIT_MINUTES="$DEFAULT_MONTHLY_LIMIT_MINUTES"
MONTHLY_LIMIT_ENABLED=false
EXTENSION_WIZARD_COMPLETED=false
KEEP_LIMIT_BUTTON="現在の設定をそのまま使う"
RESET_USAGE_BUTTON="ローカル使用量をリセット"
SET_LIMIT_BUTTON="有料キー用の月間保護を設定"

print_header() {
  clear
  cat <<EOF
Mimi Setup
==========

このSetupでは次の準備をします:
  1. Mimi Chrome拡張機能をChromeに読み込む手順を確認します。
  2. Googleの翻訳準備用キーをmacOS Keychainに保存します。
  3. MimiとChrome拡張機能の接続設定を行います。
  4. Chrome連携ヘルパーを登録します。
  5. Gemini接続とローカルサーバー起動を確認します。

EOF
}

print_step() {
  printf '\n[%s]\n' "$1"
}

print_ok() {
  printf 'OK: %s\n' "$1"
}

mock_apple_dialog_logged() {
  local mode="$1"
  case "$mode" in
    alert|confirm|copyable)
      printf 'OK\n'
      ;;
    prompt-hidden)
      printf '%s\n' "${MIMI_SETUP_MOCK_PROMPT_HIDDEN:-mimi-test-api-key}"
      ;;
    prompt-text)
      printf '%s\n' "${MIMI_SETUP_MOCK_PROMPT_TEXT:-30}"
      ;;
    choice)
      printf '%s\n' "${MIMI_SETUP_MOCK_CHOICE:-$KEEP_LIMIT_BUTTON}"
      ;;
    *)
      return 2
      ;;
  esac
}

alert() {
  local output dialog_exit_status
  set +e
  output="$(apple_alert_dialog "Mimi Setup" "$1")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -eq 0 && "$output" != "$DIALOG_CANCELLED" ]]; then
    return 0
  fi
  return 1
}

prompt_hidden() {
  local output dialog_exit_status
  set +e
  output="$(apple_prompt_hidden_dialog "Mimi Setup" "$1")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -ne 0 ]]; then
    fail_setup "Mimi Setup入力ダイアログを表示できませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
  fi
  if [[ "$output" == "$DIALOG_CANCELLED" ]]; then
    return 1
  fi
  printf '%s\n' "$output"
  return 0
}

prompt_text() {
  local output dialog_exit_status
  set +e
  output="$(apple_prompt_text_dialog "Mimi Setup" "$1" "$2")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -ne 0 ]]; then
    fail_setup "Mimi Setup入力ダイアログを表示できませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
  fi
  if [[ "$output" == "$DIALOG_CANCELLED" ]]; then
    return 1
  fi
  printf '%s\n' "$output"
  return 0
}

choose_usage_recovery() {
  local output dialog_exit_status
  set +e
  output="$(apple_choice_dialog "Mimi Setup" "$1" "$KEEP_LIMIT_BUTTON" "$RESET_USAGE_BUTTON" "$SET_LIMIT_BUTTON")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -ne 0 ]]; then
    fail_setup "API利用設定の選択ダイアログを表示できませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
  fi
  if [[ "$output" == "$DIALOG_CANCELLED" ]]; then
    return 1
  fi
  case "$output" in
    "$KEEP_LIMIT_BUTTON"|"$RESET_USAGE_BUTTON"|"$SET_LIMIT_BUTTON")
      printf '%s\n' "$output"
      return 0
      ;;
  esac
  fail_setup "API利用設定の選択結果を読み取れませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
}

copyable_text_dialog() {
  local output dialog_exit_status
  set +e
  output="$(apple_copyable_text_dialog "Mimi Setup" "$1" "$2")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -ne 0 ]]; then
    printf 'COPY THIS VALUE: %s\n%s\n' "$1" "$2" >&2
    return 1
  fi
  return 0
}

confirm_wizard_step() {
  local output dialog_exit_status
  set +e
  output="$(apple_confirm_dialog "$1" "$2")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -ne 0 ]]; then
    fail_setup "Chrome拡張機能セットアップの案内ダイアログを表示できませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
  fi
  if [[ "$output" == "$DIALOG_CANCELLED" ]]; then
    fail_setup "Chrome拡張機能セットアップの確認がキャンセルされました。Setupを続けるにはもう一度実行してください。"
  fi
  if [[ "$output" != "OK" ]]; then
    fail_setup "Chrome拡張機能セットアップの確認結果を読み取れませんでした。${DIALOG_LOG#$ROOT_DIR/} を確認してからSetupをもう一度実行してください。"
  fi
}

run_apple_dialog_logged() {
  local mode="$1"
  shift
  local output stderr_file dialog_exit_status
  if [[ "${MIMI_SETUP_DIALOG_BACKEND:-applescript}" == "mock" ]]; then
    mock_apple_dialog_logged "$mode"
    return
  fi
  mkdir -p "$ROOT_DIR/tmp"
  stderr_file="$(/usr/bin/mktemp "$ROOT_DIR/tmp/mimi-setup-dialog-stderr.XXXXXX")"
  set +e
  output="$(/usr/bin/osascript "$@" 2>"$stderr_file")"
  dialog_exit_status=$?
  set -e
  if [[ "$dialog_exit_status" -eq 0 ]]; then
    /bin/rm -f "$stderr_file"
    printf '%s\n' "$output"
    return 0
  fi
  log_apple_dialog_failure "$mode" "$dialog_exit_status" "$stderr_file"
  /bin/rm -f "$stderr_file"
  return "$dialog_exit_status"
}

apple_alert_dialog() {
  local title="$1"
  local message="$2"
  run_apple_dialog_logged alert \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'try' \
    -e 'display alert dialogTitle message dialogMessage as informational buttons {"OK"} default button "OK"' \
    -e 'return button returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message"
}

apple_confirm_dialog() {
  local title="$1"
  local message="$2"
  run_apple_dialog_logged confirm \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'try' \
    -e 'display dialog dialogMessage with title dialogTitle buttons {"OK"} default button "OK"' \
    -e 'return button returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message"
}

apple_prompt_hidden_dialog() {
  local title="$1"
  local message="$2"
  run_apple_dialog_logged prompt-hidden \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'try' \
    -e 'display dialog dialogMessage default answer "" with title dialogTitle buttons {"キャンセル", "OK"} default button "OK" cancel button "キャンセル" with hidden answer' \
    -e 'return text returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message"
}

apple_prompt_text_dialog() {
  local title="$1"
  local message="$2"
  local default_text="$3"
  run_apple_dialog_logged prompt-text \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'set defaultText to item 3 of argv' \
    -e 'try' \
    -e 'display dialog dialogMessage default answer defaultText with title dialogTitle buttons {"キャンセル", "OK"} default button "OK" cancel button "キャンセル"' \
    -e 'return text returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message" "$default_text"
}

apple_choice_dialog() {
  local title="$1"
  local message="$2"
  local keep_button="$3"
  local reset_button="$4"
  local set_limit_button="$5"
  run_apple_dialog_logged choice \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'set keepButton to item 3 of argv' \
    -e 'set resetButton to item 4 of argv' \
    -e 'set setLimitButton to item 5 of argv' \
    -e 'try' \
    -e 'display dialog dialogMessage with title dialogTitle buttons {keepButton, resetButton, setLimitButton} default button keepButton' \
    -e 'return button returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message" "$keep_button" "$reset_button" "$set_limit_button"
}

apple_copyable_text_dialog() {
  local title="$1"
  local message="$2"
  local copy_text="$3"
  run_apple_dialog_logged copyable \
    -e 'on run argv' \
    -e 'set dialogTitle to item 1 of argv' \
    -e 'set dialogMessage to item 2 of argv' \
    -e 'set copyText to item 3 of argv' \
    -e 'try' \
    -e 'display dialog dialogMessage default answer copyText with title dialogTitle buttons {"OK"} default button "OK"' \
    -e 'return button returned of result' \
    -e 'on error number -128' \
    -e 'return "__MIMI_DIALOG_CANCELLED__"' \
    -e 'end try' \
    -e 'end run' \
    "$title" "$message" "$copy_text"
}

log_apple_dialog_failure() {
  local mode="$1"
  local dialog_exit_status="$2"
  local stderr_file="$3"
  mkdir -p "$ROOT_DIR/tmp"
  {
    printf '[%s] AppleScript setup dialog failed mode=%s exit_status=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$dialog_exit_status"
    if [[ -s "$stderr_file" ]]; then
      /usr/bin/sed -E 's/AIza[0-9A-Za-z_-]{20,}/[redacted]/g; s/([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=([^&[:space:]]+)/\1=[redacted]/g; s/[Bb]earer[[:space:]]+[0-9A-Za-z._~+\/=-]+/Bearer [redacted]/g' "$stderr_file" | /usr/bin/tail -n 30
    fi
  } >> "$DIALOG_LOG"
  printf 'DEBUG: AppleScript setup dialog failed (%s, exit_status %s). See %s\n' "$mode" "$dialog_exit_status" "${DIALOG_LOG#$ROOT_DIR/}" >&2
}

setup_dialog_logged() {
  local mode="$1"
  local title="$2"
  local message="$3"
  local default_text="$4"
  local buttons="$5"
  local output stderr_file helper_exit_status
  if [[ "${MIMI_SETUP_USE_JXA_DIALOG_HELPER:-0}" != "1" ]]; then
    printf 'JXA setup dialog helper is disabled for normal Setup. Set MIMI_SETUP_USE_JXA_DIALOG_HELPER=1 only for explicit helper experiments.\n' >&2
    return 2
  fi
  mkdir -p "$ROOT_DIR/tmp"
  stderr_file="$(/usr/bin/mktemp "$ROOT_DIR/tmp/mimi-setup-dialog-helper-stderr.XXXXXX")"
  set +e
  output="$(/usr/bin/osascript -l JavaScript "$ROOT_DIR/apps/mac/setup/setup-dialog-helper.js" "$mode" "$title" "$message" "$default_text" "$buttons" 2>"$stderr_file")"
  helper_exit_status=$?
  set -e
  if [[ "$helper_exit_status" -eq 0 ]]; then
    /bin/rm -f "$stderr_file"
    printf '%s\n' "$output"
    return 0
  fi
  log_dialog_helper_failure "$mode" "$title" "$helper_exit_status" "$stderr_file"
  /bin/rm -f "$stderr_file"
  return "$helper_exit_status"
}

log_dialog_helper_failure() {
  local mode="$1"
  local title="$2"
  local helper_exit_status="$3"
  local stderr_file="$4"
  local helper_log="$ROOT_DIR/tmp/mimi-setup-dialog-helper.log"
  mkdir -p "$ROOT_DIR/tmp"
  {
    printf '[%s] setup-dialog-helper failed mode=%s title=%s exit_status=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$title" "$helper_exit_status"
    if [[ -s "$stderr_file" ]]; then
      /usr/bin/sed -E 's/AIza[0-9A-Za-z_-]{20,}/[redacted]/g; s/([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=([^&[:space:]]+)/\1=[redacted]/g; s/[Bb]earer[[:space:]]+[0-9A-Za-z._~+\/=-]+/Bearer [redacted]/g' "$stderr_file" | /usr/bin/tail -n 30
    fi
  } >> "$helper_log"
  printf 'DEBUG: setup dialog helper failed (%s, exit_status %s). See %s\n' "$mode" "$helper_exit_status" "${helper_log#$ROOT_DIR/}" >&2
}

fail_setup() {
  printf '\nFAILED: %s\n' "$1"
  alert "$1"
  exit 1
}

require_single_line() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    fail_setup "$label が空です。もう一度 setup を実行してください。"
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    fail_setup "$label に改行が含まれています。1行の値だけを貼り付けてください。"
  fi
}

validate_extension_origin() {
  if ! node - "$extension_origin" <<'NODE'
const origin = String(process.argv[2] || "");
if (!/^chrome-extension:\/\/[a-p]{32}\/?$/.test(origin)) process.exit(2);
NODE
  then
    fail_setup "MimiとChrome拡張機能の接続元を自動設定できませんでした。Chrome拡張の固定ID設定を確認してください。"
  fi
}

validate_limit_minutes() {
  node - "$MONTHLY_LIMIT_MINUTES" <<'NODE'
const value = Number(process.argv[2]);
if (!Number.isFinite(value) || value <= 0 || value > 10000) process.exit(2);
NODE
}

read_existing_monthly_limit_minutes() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi
  /usr/bin/awk '
    /^[[:space:]]*(export[[:space:]]+)?JP_DUB_MONTHLY_LIMIT_MINUTES[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*(export[[:space:]]+)?JP_DUB_MONTHLY_LIMIT_MINUTES[[:space:]]*=/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$ENV_FILE"
}

read_existing_monthly_limit_enabled() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi
  /usr/bin/awk '
    /^[[:space:]]*(export[[:space:]]+)?JP_DUB_MONTHLY_LIMIT_ENABLED[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*(export[[:space:]]+)?JP_DUB_MONTHLY_LIMIT_ENABLED[[:space:]]*=/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$ENV_FILE"
}

read_existing_free_tier_mode() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi
  /usr/bin/awk '
    /^[[:space:]]*(export[[:space:]]+)?JP_DUB_FREE_TIER_MODE[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*(export[[:space:]]+)?JP_DUB_FREE_TIER_MODE[[:space:]]*=/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$ENV_FILE"
}

load_existing_monthly_limit_minutes() {
  local configured_limit configured_enabled configured_free_tier
  configured_enabled="$(read_existing_monthly_limit_enabled || true)"
  configured_free_tier="$(read_existing_free_tier_mode || true)"
  configured_limit="$(read_existing_monthly_limit_minutes || true)"

  if [[ "$configured_enabled" == "1" || "$configured_enabled" == "true" || "$configured_enabled" == "TRUE" || "$configured_enabled" == "yes" || "$configured_enabled" == "YES" || "$configured_enabled" == "on" || "$configured_enabled" == "ON" ]]; then
    MONTHLY_LIMIT_ENABLED=true
  elif [[ "$configured_enabled" == "0" || "$configured_enabled" == "false" || "$configured_enabled" == "FALSE" || "$configured_enabled" == "no" || "$configured_enabled" == "NO" || "$configured_enabled" == "off" || "$configured_enabled" == "OFF" ]]; then
    MONTHLY_LIMIT_ENABLED=false
  elif [[ -n "$configured_limit" && "$configured_free_tier" != "1" && "$configured_free_tier" != "true" && "$configured_free_tier" != "TRUE" && "$configured_free_tier" != "yes" && "$configured_free_tier" != "YES" && "$configured_free_tier" != "on" && "$configured_free_tier" != "ON" ]]; then
    MONTHLY_LIMIT_ENABLED=true
  else
    MONTHLY_LIMIT_ENABLED=false
  fi

  if [[ -z "$configured_limit" ]]; then
    print_ok "月間API保護はオフです。必要な場合だけ${DEFAULT_MONTHLY_LIMIT_MINUTES}分/月から設定できます"
    return
  fi

  MONTHLY_LIMIT_MINUTES="$configured_limit"
  if ! validate_limit_minutes; then
    fail_setup "apps/mac/local-server/.env のJP_DUB_MONTHLY_LIMIT_MINUTESは正の数にしてください。"
  fi
  if [[ "$MONTHLY_LIMIT_ENABLED" == "true" ]]; then
    print_ok ".env の月間API保護を使います: ${MONTHLY_LIMIT_MINUTES}分/月"
  else
    print_ok "月間API保護はオフです。既存の時間設定は必要な場合だけ使います: ${MONTHLY_LIMIT_MINUTES}分/月"
  fi
}

open_chrome_url_foreground() {
  local url="$1"
  local label="$2"
  if /usr/bin/osascript - "$url" >/dev/null 2>&1 <<'OSA'
on run argv
  set targetUrl to item 1 of argv
  set targetUrlNoSlash to targetUrl
  if targetUrlNoSlash ends with "/" then
    set targetUrlNoSlash to text 1 thru -2 of targetUrlNoSlash
  end if

  tell application "Google Chrome"
    activate
    if (count of windows) = 0 then
      make new window
    end if
    set targetWindow to front window
    set matchedIndex to 0
    repeat with tabIndex from 1 to count of tabs of targetWindow
      set tabUrl to URL of tab tabIndex of targetWindow
      if tabUrl is targetUrl or tabUrl is targetUrlNoSlash or tabUrl starts with targetUrl then
        set matchedIndex to tabIndex
        exit repeat
      end if
    end repeat
    if matchedIndex is 0 then
      make new tab at end of tabs of targetWindow with properties {URL:targetUrl}
      set matchedIndex to count of tabs of targetWindow
    end if
    set active tab index of targetWindow to matchedIndex
    set index of targetWindow to 1
    activate
  end tell
end run
OSA
  then
    print_ok "$label をGoogle Chromeの前面タブにしました"
    return
  fi
  return 1
}

open_ai_studio_url() {
  local target_url="$1"
  local label="$2"
  if open_chrome_url_foreground "$target_url" "$label"; then
    return
  fi
  if /usr/bin/open -a "Google Chrome" "$target_url" >/dev/null 2>&1; then
    /usr/bin/osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1 || true
    printf '%sをGoogle Chromeで開きましたが、前面タブかどうかを確認できませんでした。\n' "$label"
    copyable_text_dialog "$label をChromeの前面タブにできませんでした。ChromeでこのURLのタブを開いてから、次に進んでください。" "$target_url"
    return
  fi
  if /usr/bin/open "$target_url" >/dev/null 2>&1; then
    printf '%sを既定ブラウザで開きましたが、前面タブかどうかを確認できませんでした。\n' "$label"
    copyable_text_dialog "$label をChromeの前面タブにできませんでした。ChromeでこのURLのタブを開いてから、次に進んでください。" "$target_url"
    return
  fi
  printf '%sを自動で開けませんでした。次のURLをChromeで開いてください:\n%s\n' "$label" "$target_url"
  copyable_text_dialog "$label を自動で開けませんでした。このURLをコピーしてChromeで開いてください。" "$target_url"
}

open_ai_studio_first_run() {
  open_ai_studio_url "$AI_STUDIO_HOME_URL" "Google AI Studio"
}

open_ai_studio_api_keys() {
  open_ai_studio_url "$AI_STUDIO_API_KEYS_URL" "Google AI Studio APIキーのページ"
}

open_chrome_extensions_page() {
  if open_chrome_url_foreground "$CHROME_EXTENSIONS_URL" "chrome://extensions/"; then
    return
  fi
  if /usr/bin/open -a "Google Chrome" "chrome://extensions/" >/dev/null 2>&1; then
    /usr/bin/osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1 || true
    print_ok "chrome://extensions/ をGoogle Chromeで開きました"
    return
  fi
  if /usr/bin/open "chrome://extensions/" >/dev/null 2>&1; then
    print_ok "chrome://extensions/ を既定ブラウザで開きました"
    return
  fi
  printf 'Chrome拡張機能ページを自動で開けませんでした。次のURLをChromeで開いてください:\n%s\n' "chrome://extensions/"
  copyable_text_dialog "Chrome拡張機能ページを自動で開けませんでした。このURLをコピーしてChromeで開いてください。" "chrome://extensions/"
}

prepare_extension_folder_path() {
  if printf '%s' "$EXTENSION_DIR" | /usr/bin/pbcopy; then
    print_ok "Mimi拡張機能フォルダのパスをクリップボードにコピーしました"
  else
    printf 'Mimi拡張機能フォルダのパスを自動でコピーできませんでした。次のパスをコピーしてください:\n%s\n' "$EXTENSION_DIR"
    copyable_text_dialog "Mimi拡張機能フォルダのパスを自動でクリップボードにコピーできませんでした。フォルダ選択画面で必要なので、このパスをコピーしてください。" "$EXTENSION_DIR"
  fi
}

run_extension_setup_wizard() {
  print_step "Chrome拡張機能セットアップ"
  cat <<EOF
Chrome拡張機能の準備
--------------------
現在のrepo開発版では、Mimi Setupがパッケージ化されていないChrome拡張機能を
自動でインストールすることはできません。
Chrome Web Store版が用意できるまでは、Chromeの日本語UIに合わせて
1ステップずつ手動で読み込みます。

EOF

  open_chrome_extensions_page
  confirm_wizard_step "Mimi Setup - Chrome拡張 1/10" "ステップ 1: Chromeの chrome://extensions/ を前面に開きました。Chromeの拡張機能ページが見えたらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 2/10" "ステップ 2: 右上の「デベロッパー モード」をオンにしてください。オンにできたらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 3/10" "ステップ 3: 「パッケージ化されていない拡張機能を読み込む」をクリックしてください。フォルダ選択画面が開いたらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 4/10" "ステップ 4: フォルダ選択画面で Cmd+Shift+G を押してください。「フォルダへ移動」の入力欄が出たらOKを押してください。"

  prepare_extension_folder_path
  local path_message
  path_message="ステップ 5: Mimi拡張機能フォルダのパスはクリップボードにコピー済みです。"$'\n\n'"「フォルダへ移動」の入力欄に貼り付けてください。"$'\n\n'"貼り付けできたらOKを押してください。"
  confirm_wizard_step "Mimi Setup - Chrome拡張 5/10" "$path_message"

  confirm_wizard_step "Mimi Setup - Chrome拡張 6/10" "ステップ 6: Enterを押してください。フォルダ選択画面がMimi拡張機能フォルダへ移動したらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 7/10" "ステップ 7: 右下の「選択」をクリックしてください。MimiがChromeの拡張機能一覧に表示されたらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 8/10" "ステップ 8: chrome://extensions/ のMimiカードを探してください。Mimiカード内の回転矢印アイコン、または「更新」を押してください。押したらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 9/10" "ステップ 9: Chrome右上のパズルピース型の拡張機能アイコンを押してください。Mimiの行を探し、ピンアイコンを押して青/固定状態にしてください。ツールバーにMimiアイコンが出たらOKを押してください。"

  confirm_wizard_step "Mimi Setup - Chrome拡張 10/10" "ステップ 10: Chrome拡張機能の準備は完了です。まだMimiは使えません。次にGoogleの翻訳準備用キーを設定します。OKを押してください。"

  EXTENSION_WIZARD_COMPLETED=true
  print_ok "Chrome拡張機能セットアップの完了を確認しました"
}

show_api_key_guidance() {
  cat <<EOF
Googleの翻訳準備
----------------
次は、Mimiで日本語音声を聞くためのGoogle側の準備です。
Google AI Studioで無料で使えるGemini APIキーから始められます。

  https://aistudio.google.com/
  https://aistudio.google.com/api-keys

SetupはまずAI Studioを開きます。
初めて開く場合は、Googleアカウントでログインします。利用規約の画面が出たら、必須の同意チェックを入れて「続行」を押してください。
そのあとAPIキーのページを開きます。最初から表示されているGemini APIキーがある場合は、その行のコピーボタンでコピーできます。
キーが見当たらない場合だけ、AI Studioの画面で無料で使えるキーを作ります。
コピーしたキーは、Mimi Setupの入力欄だけに貼り付けてください。キーを差し替える場合も、新しいキーをここに貼り付ければKeychain側だけを更新できます。
Googleのサービス改善への利用を許可したくない場合は、Google Cloudの有料APIを使う方法を選んでください。
chat、GitHub、screenshots、docs、.env、Chrome extensionには貼り付けないでください。
MimiはこのキーをmacOS Keychainに保存します。Chrome拡張には保存しません。

EOF

  alert "Google AI StudioをChrome前面に開きます。初めての場合はGoogleアカウントでログインし、利用規約の画面が出たら必須の同意チェックを入れて「続行」を押してください。そのあとAPIキーのページで、最初から表示されているGemini APIキーがあれば行のコピーボタンでコピーします。キーは次のMimi Setup入力欄だけに貼ってください。macOS Keychainに保存され、Chrome extension、.env、chat、GitHub、screenshotsには保存・共有しません。"
}

resolve_extension_origin() {
  node - "$ROOT_DIR" <<'NODE'
const path = require("path");
const root = process.argv[2];
const { resolveExtensionOriginDetails } = require(path.join(root, "apps/mac/shared/extensionOrigin.cjs"));
const details = resolveExtensionOriginDetails({
  env: process.env,
  manifestPath: path.join(root, "apps/mac/extension/manifest.json"),
});
if (!details.origin) process.exit(2);
process.stdout.write([details.origin, details.source, details.extensionId].join("\t"));
NODE
}

normalize_target_language() {
  node - "$target_language" "$ROOT_DIR" <<'NODE'
const path = require("path");
const target = process.argv[2];
const root = process.argv[3];
const { normalizeTargetLanguageCode } = require(path.join(root, "apps/mac/local-server/src/languages"));
const normalized = normalizeTargetLanguageCode(target, "");
if (!normalized) process.exit(2);
process.stdout.write(normalized);
NODE
}

read_usage_summary() {
  node - "$ROOT_DIR" "$MONTHLY_LIMIT_MINUTES" <<'NODE'
const path = require("path");
const root = process.argv[2];
const limitMinutes = Number(process.argv[3]);
const { readLocalUsageSummary } = require(path.join(root, "apps/mac/local-server/src/billingGuard"));
const summary = readLocalUsageSummary({
  storagePath: path.join(root, "tmp", "jp-dub-usage.json"),
  limitSeconds: Math.floor(limitMinutes * 60),
});
process.stdout.write([
  summary.state,
  format(summary.usedMinutes),
  format(summary.limitMinutes),
  format(summary.remainingMinutes),
  summary.storagePath,
].join("\t"));

function format(value) {
  return Number(value).toFixed(value >= 10 ? 0 : 1);
}
NODE
}

show_usage_summary() {
  local usage_info usage_state usage_used usage_limit usage_remaining usage_path
  usage_info="$(read_usage_summary)" || fail_setup "local usage fileを確認できませんでした。"
  IFS=$'\t' read -r usage_state usage_used usage_limit usage_remaining usage_path <<< "$usage_info"

  cat <<EOF
API利用の設定
-------------
使用量ファイル: tmp/jp-dub-usage.json
使用済み: $usage_used 分
月間API保護: $MONTHLY_LIMIT_ENABLED
有料キー用の時間設定: $usage_limit 分/月

無料のGemini APIキーなら、Mimi側で月の利用時間を気にせず使えます。
課金が有効なAPIキーを使う場合だけ、任意で時間の目安を入れておけます。
使い忘れ防止の自動停止は別の設定で、Chrome拡張の初期値は30分です。

EOF

  if [[ "$usage_state" == "missing" ]]; then
    printf 'まだローカル使用量ファイルはありません。翻訳を開始するとMimiが作成します。\n\n'
  fi

  local choice
  if ! choice="$(choose_usage_recovery "月間API保護: $MONTHLY_LIMIT_ENABLED。使用済み: $usage_used 分 / 有料キー用の時間設定: $usage_limit 分/月。無料キーなら通常は変更不要です。必要な操作を選んでください。")"; then
    fail_setup "API利用設定の選択がキャンセルされました。Setupを続けるにはもう一度実行してください。"
  fi
  case "$choice" in
    "$RESET_USAGE_BUTTON")
      reset_usage_counter
      ;;
    "$SET_LIMIT_BUTTON")
      MONTHLY_LIMIT_ENABLED=true
      if ! MONTHLY_LIMIT_MINUTES="$(prompt_text "課金が有効なAPIキー向けの月間保護を何分にするか入力してください。無料のGemini APIキーなら通常は変更不要です。" "$usage_limit")"; then
        fail_setup "ローカル上限の入力がキャンセルされました。Setupを続けるにはもう一度実行してください。"
      fi
      validate_limit_minutes || fail_setup "ローカル上限は正の数で入力してください。"
      print_ok "有料キー用の月間API保護を${MONTHLY_LIMIT_MINUTES}分/月にしました"
      ;;
    *)
      print_ok "現在のAPI利用設定をそのまま使います"
      ;;
  esac
}

reset_usage_counter() {
  if [[ ! -f "$USAGE_FILE" ]]; then
    print_ok "リセットするローカル使用量ファイルはまだありません"
    return
  fi
  local backup_file="$USAGE_FILE.reset-backup.$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$USAGE_FILE" "$backup_file"
  print_ok "ローカル使用量をリセットしました。以前のファイルは ${backup_file#$ROOT_DIR/} に移動しました"
}

backup_existing_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return
  fi
  local backup_file="$ENV_FILE.backup.$(/bin/date +%Y%m%d-%H%M%S)"
  /usr/bin/awk '
    /^[[:space:]]*(export[[:space:]]+)?GEMINI_API_KEY[[:space:]]*=/ {
      print "# GEMINI_API_KEY removed from backup; Mimi stores the key in macOS Keychain."
      next
    }
    { print }
  ' "$ENV_FILE" > "$backup_file"
  chmod 600 "$backup_file"
}

save_api_key_to_keychain() {
  /usr/bin/security add-generic-password \
    -U \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" \
    -w "$setup_value" >/dev/null
}

write_local_env() {
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
JP_DUB_PORT=8787
JP_DUB_MODEL=gemini-3.5-live-translate-preview
JP_DUB_TARGET_LANGUAGE=$target_language
JP_DUB_FREE_TIER_MODE=true
JP_DUB_SHOW_USAGE_ESTIMATE=false
JP_DUB_MONTHLY_LIMIT_ENABLED=$MONTHLY_LIMIT_ENABLED
JP_DUB_MONTHLY_LIMIT_MINUTES=$MONTHLY_LIMIT_MINUTES
JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO=false
JP_DUB_RECONNECT_SECONDS=540
JP_DUB_DIAGNOSTICS=false
JP_DUB_CAPTURE_FIRST_INPUT_WAV=false
JP_DUB_CAPTURE_FIRST_OUTPUT_WAV=false
JP_DUB_CAPTURE_BROWSER_MIX_WAV=false
JP_DUB_ALLOWED_EXTENSION_ORIGIN=$extension_origin
EOF
  chmod 600 "$ENV_FILE"
}

check_server_status() {
  EXPECTED_EXTENSION_ORIGIN="$extension_origin" EXPECTED_EXTENSION_ID="$extension_id" MIMI_ROOT_DIR="$ROOT_DIR" STATUS_RETRY_SECONDS="$STATUS_RETRY_SECONDS" node - <<'NODE'
const fs = require("fs");
const http = require("http");
const path = require("path");

const retrySeconds = Number(process.env.STATUS_RETRY_SECONDS || 30);
const retryIntervalMs = 1000;
const deadline = Date.now() + retrySeconds * 1000;
let lastResult = "status was not checked";

pollStatus().catch((error) => {
  console.error(error.message);
  process.exit(1);
});

async function pollStatus() {
  while (Date.now() <= deadline) {
    const result = await fetchStatus();
    try {
      const status = validateStatusResult(result);
      console.log(`Mimiローカルサーバーの状態を確認しました: http://127.0.0.1:${process.env.JP_DUB_PORT || 8787}/status`);
      return status;
    } catch (error) {
      lastResult = describeStatusResult(result, error);
      await sleep(retryIntervalMs);
    }
  }

  console.error(`Setup could not confirm local server yet after ${retrySeconds} seconds. ローカルサーバーの準備完了をまだ確認できませんでした。`);
  console.error(`Last /status result: ${lastResult}`);
  printRedactedTail("local server log tail", path.join(rootDir(), "logs", "jp-dub-local-server.log"));
  printRedactedTail("diagnostics tail", path.join(rootDir(), "logs", "jp-dub-diagnostics.ndjson"));
  process.exit(1);
}

function fetchStatus() {
  const port = Number(process.env.JP_DUB_PORT || 8787);
  return new Promise((resolve, reject) => {
    const request = http.get(`http://127.0.0.1:${port}/status`, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          resolve({ ok: true, statusCode: response.statusCode, body, json: JSON.parse(body) });
        } catch {
          resolve({ ok: false, statusCode: response.statusCode, body, error: `status returned non-JSON HTTP ${response.statusCode}` });
        }
      });
    });
    request.on("error", (error) => resolve({ ok: false, error: error.message }));
    request.setTimeout(3000, () => request.destroy(new Error("status check timed out")));
  });
}

function validateStatusResult(result) {
  if (!result.ok) throw new Error(result.error || "状態確認に失敗しました");
  const status = result.json;
  if (status?.ok !== true || status.service !== "jp-dub-local-server") {
    throw new Error("ローカルサーバーがMimiの状態を返しませんでした");
  }
  if (status.mode !== "real") throw new Error("ローカルサーバーがreal modeではありません");
  if (!status.realModeReady) throw new Error("Gemini API keyの準備がまだ完了していません");
  if (!status.allowedExtensionOriginConfigured) throw new Error("Chrome拡張機能の接続設定がまだ完了していません");
  const expectedOrigin = normalizeOrigin(process.env.EXPECTED_EXTENSION_ORIGIN);
  const expectedId = String(process.env.EXPECTED_EXTENSION_ID || "").trim();
  const actualOrigin = normalizeOrigin(status.allowedExtensionOrigin);
  const actualId = String(status.allowedExtensionId || "").trim();
  if (actualOrigin !== expectedOrigin || actualId !== expectedId) {
    throw new Error(`ローカルサーバーが別のMimi拡張IDに設定されています (${actualId || "missing"})`);
  }
  return status;
}

function describeStatusResult(result, error) {
  const parts = [error.message];
  if (result.statusCode) parts.push(`HTTP ${result.statusCode}`);
  if (result.body) parts.push(`body=${redact(result.body).slice(0, 1000)}`);
  if (result.error && result.error !== error.message) parts.push(`error=${result.error}`);
  return parts.join("; ");
}

function printRedactedTail(label, filePath) {
  console.error(`--- ${label} ---`);
  try {
    const text = fs.readFileSync(filePath, "utf8");
    console.error(redact(text.slice(-4000)));
  } catch {
    console.error("missing");
  }
}

function rootDir() {
  return process.env.MIMI_ROOT_DIR || path.resolve(__dirname, "..", "..", "..", "..");
}

function redact(value) {
  return String(value)
    .replace(/AIza[0-9A-Za-z_-]{20,}/g, "[redacted]")
    .replace(/(key|token|secret|authorization|password)=([^&\s]+)/gi, "$1=[redacted]")
    .replace(/Bearer\s+[0-9A-Za-z._~+/=-]+/gi, "Bearer [redacted]");
}

function normalizeOrigin(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
NODE
}

collect_debug_bundle() {
  print_step "デバッグ情報を保存"
  local output command_exit_status
  set +e
  output="$(npm run collect:debug 2>&1)"
  command_exit_status=$?
  set -e
  if [[ "$command_exit_status" -eq 0 ]]; then
    printf '%s\n' "$output"
    print_ok "デバッグ情報を保存しました"
    return
  fi
  printf '%s\n' "$output"
  printf 'デバッグ情報を自動保存できませんでした。必要なら次を実行してください:\n  cd %s && npm run collect:debug\n' "$LOCAL_SERVER_DIR"
}

run_server_status_check() {
  local output check_exit_status
  print_step "ローカルサーバー状態確認"
  set +e
  output="$(check_server_status 2>&1)"
  check_exit_status=$?
  set -e
  if [[ "$check_exit_status" -ne 0 ]]; then
    printf '%s\n' "$output"
    collect_debug_bundle
    fail_setup "Setup could not confirm local server yet. Gemini接続テストとローカルサーバー起動は完了しましたが、${STATUS_RETRY_SECONDS}秒以内に /status の準備完了を確認できませんでした。Mimiはまだ準備完了とは表示しません。デバッグ情報を確認するか、少し待ってからSetupをもう一度実行してください。"
  fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  print_ok "ローカルサーバー状態確認"
}

run_checked() {
  local label="$1"
  shift
  local output command_exit_status
  print_step "$label"
  set +e
  output="$("$@" 2>&1)"
  command_exit_status=$?
  set -e
  if [[ "$command_exit_status" -ne 0 ]]; then
    printf '%s\n' "$output"
    fail_setup "$label に失敗しました。上のメッセージを確認してからSetupをもう一度実行してください。"
  fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  print_ok "$label"
}

run_shell_compatibility_smoke() {
  MIMI_SETUP_DIALOG_BACKEND=mock
  printf 'Mimi Setup shell compatibility smoke\n'

  confirm_wizard_step "Mimi Setup smoke confirm" "mock confirm dialog"
  alert "mock alert dialog" || fail_setup "mock alert dialog failed"

  local hidden_value text_value choice_value
  hidden_value="$(prompt_hidden "mock hidden prompt")" || fail_setup "mock hidden prompt failed"
  require_single_line "mock hidden prompt" "$hidden_value"

  MIMI_SETUP_MOCK_PROMPT_TEXT=45
  text_value="$(prompt_text "mock text prompt" "30")" || fail_setup "mock text prompt failed"
  if [[ "$text_value" != "45" ]]; then
    fail_setup "mock text prompt returned unexpected value: $text_value"
  fi

  MIMI_SETUP_MOCK_CHOICE="$KEEP_LIMIT_BUTTON"
  choice_value="$(choose_usage_recovery "mock local safety limit choice")" || fail_setup "mock keep choice failed"
  if [[ "$choice_value" != "$KEEP_LIMIT_BUTTON" ]]; then
    fail_setup "mock keep choice returned unexpected value: $choice_value"
  fi

  MIMI_SETUP_MOCK_CHOICE="$RESET_USAGE_BUTTON"
  choice_value="$(choose_usage_recovery "mock local safety limit choice")" || fail_setup "mock reset choice failed"
  if [[ "$choice_value" != "$RESET_USAGE_BUTTON" ]]; then
    fail_setup "mock reset choice returned unexpected value: $choice_value"
  fi

  MIMI_SETUP_MOCK_CHOICE="$SET_LIMIT_BUTTON"
  choice_value="$(choose_usage_recovery "mock local safety limit choice")" || fail_setup "mock set-limit choice failed"
  if [[ "$choice_value" != "$SET_LIMIT_BUTTON" ]]; then
    fail_setup "mock set-limit choice returned unexpected value: $choice_value"
  fi

  local smoke_usage_line smoke_state smoke_used smoke_limit smoke_remaining smoke_usage_path
  smoke_usage_line="missing"$'\t'"0"$'\t'"30"$'\t'"30"$'\t'"tmp/jp-dub-usage.json"
  IFS=$'\t' read -r smoke_state smoke_used smoke_limit smoke_remaining smoke_usage_path <<< "$smoke_usage_line"
  if [[ "$smoke_state" != "missing" || "$smoke_usage_path" != "tmp/jp-dub-usage.json" ]]; then
    fail_setup "mock tab-separated read failed"
  fi

  local output command_exit_status
  set +e
  output="$(sh -c 'printf smoke-error >&2; exit 7' 2>&1)"
  command_exit_status=$?
  set -e
  if [[ "$command_exit_status" -ne 7 || "$output" != "smoke-error" ]]; then
    fail_setup "mock command exit status capture failed"
  fi

  extension_origin="chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  validate_extension_origin

  local guidance_copy forbidden_pattern
  guidance_copy="$(show_api_key_guidance)" || fail_setup "mock setup guidance failed"
  forbidden_pattern="$(printf '\107\105\115\111\116\111\137\101\120\111\137\113\105\131\075')"
  assert_smoke_contains "$guidance_copy" "Mimiで日本語音声を聞くためのGoogle側の準備"
  assert_smoke_contains "$guidance_copy" "無料で使えるGemini APIキー"
  assert_smoke_contains "$guidance_copy" "利用規約の画面"
  assert_smoke_contains "$guidance_copy" "必須の同意チェック"
  assert_smoke_contains "$guidance_copy" "続行"
  assert_smoke_contains "$guidance_copy" "最初から表示されているGemini APIキー"
  assert_smoke_contains "$guidance_copy" "コピーボタン"
  assert_smoke_contains "$guidance_copy" "キーを差し替える場合"
  assert_smoke_contains "$guidance_copy" "Google Cloudの有料APIを使う方法"
  assert_smoke_contains "$guidance_copy" "macOS Keychain"
  assert_smoke_contains "$guidance_copy" "Chrome拡張には保存しません"
  assert_smoke_contains "$guidance_copy" ".env"
  assert_smoke_not_contains "$guidance_copy" "AIza"
  assert_smoke_not_contains "$guidance_copy" "$forbidden_pattern"

  printf 'PASS Mimi Setup shell compatibility smoke\n'
}

assert_smoke_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  fail_setup "setup guidance smoke missing expected copy: $needle"
}

assert_smoke_not_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) fail_setup "setup guidance smoke found forbidden copy: $needle" ;;
  esac
  return 0
}

if [[ "${MIMI_SETUP_TEST_MODE:-0}" == "1" ]]; then
  run_shell_compatibility_smoke
  exit 0
fi

print_header

if ! command -v node >/dev/null 2>&1; then
  alert "Node.js が見つかりません。今の開発版は先に nodejs.org から Node.js LTS をインストールしてください。Mimi.app版ではここを不要にする予定です。"
  exit 1
fi

load_existing_monthly_limit_minutes

origin_info="$(resolve_extension_origin)" || fail_setup "MimiとChrome拡張機能の接続元を自動設定できませんでした。"
IFS=$'\t' read -r extension_origin extension_origin_source extension_id <<< "$origin_info"
target_language="$DEFAULT_TARGET_LANGUAGE"

cat <<EOF
Chrome拡張機能
--------------
現在のrepo開発版では、Mimi Setupがパッケージ化されていないChrome拡張機能を
自動でインストールすることはできません。
まず chrome://extensions/ を開き、「デベロッパー モード」、
「パッケージ化されていない拡張機能を読み込む」、Cmd+Shift+G、
貼り付け、Enter、「選択」、「更新」、「固定」を1ステップずつ案内します。

MimiはChrome拡張機能の接続元を自動で設定します:
  $extension_origin

extension IDやextension originを手入力する必要はありません。
EOF

run_extension_setup_wizard
if [[ "$EXTENSION_WIZARD_COMPLETED" != "true" ]]; then
  fail_setup "Chrome拡張機能セットアップが完了しませんでした。Mimi Setupをもう一度実行し、先にChrome拡張機能の手順を最後まで進めてください。"
fi
printf 'STEP chrome wizard complete\n'

show_usage_summary
printf 'STEP local safety limit complete\n'
show_api_key_guidance
printf 'STEP opening AI Studio first-run page\n'
open_ai_studio_first_run
confirm_wizard_step "Mimi Setup - Googleの翻訳準備" "AI Studioを初めて開く場合は、Googleアカウントでログインし、利用規約の画面で必須の同意チェックを入れて「続行」を押してください。AI Studioの画面まで進めたらOKを押してください。"
printf 'STEP opening AI Studio API keys\n'
open_ai_studio_api_keys

printf 'STEP prompting Google translation key\n'
setup_value="$(prompt_hidden "APIキーのページで最初から表示されているGemini APIキーがあれば、その行のコピーボタンでコピーし、ここに貼り付けてください。キーが見当たらない場合だけAI Studioの画面で無料で使えるキーを作ります。差し替えの場合も新しいキーをここに貼り付けてください。Mimiはこの値をmacOS Keychainに保存します。Chrome extension、.env、chat、GitHub、screenshotsには保存・共有しないでください。")"

require_single_line "Google AI Studio API key" "$setup_value"
require_single_line "extension origin" "$extension_origin"
validate_extension_origin
target_language="$(normalize_target_language)" || fail_setup "未対応のlanguage codeです。Mimiの一覧にあるcodeを入力してください。"

print_step "ローカル設定を書き込み"
backup_existing_env
save_api_key_to_keychain || fail_setup "APIキーをmacOS Keychainに保存または差し替えできませんでした。Mimi Setupをもう一度開き、新しいキーを貼り付けて再試行してください。"
write_local_env
print_ok "API keyをKeychainに保存し、秘密情報ではないローカル設定を書き込みました"

cd "$NATIVE_HOST_DIR"
run_checked "Chrome連携ヘルパー登録" npm run install -- --extension-origin="$extension_origin"
run_checked "Chrome連携ヘルパー確認" npm run doctor

cd "$LOCAL_SERVER_DIR"
run_checked "Gemini接続テスト" npm run diagnose:real
run_checked "ローカルサーバー停止" npm run stop
run_checked "ローカルサーバー起動" env JP_DUB_RESTART_EXISTING=true JP_DUB_IDLE_EXIT_SECONDS="$SETUP_IDLE_EXIT_SECONDS" npm run start:detached
run_server_status_check

show_final_success() {
  local message
  message="Mimiの準備が完了しました"$'\n\n'
  message+="1. YouTubeまたはX Webで英語音声の動画を開く"$'\n'
  message+="2. 動画を再生する"$'\n'
  message+="3. Chrome右上のMimiアイコンを押す"$'\n'
  message+="4. Start（開始）を押す"$'\n'
  message+="5. 翻訳音声が聞こえれば成功"$'\n\n'
  message+="聞く言語: Chrome拡張で選択"$'\n'
  message+="月間API保護: $MONTHLY_LIMIT_ENABLED"$'\n'
  message+="有料キー用の時間設定: $MONTHLY_LIMIT_MINUTES 分/月"$'\n'
  message+="使い忘れ防止の自動停止: Chrome拡張で初期値30分"$'\n'
  message+="Chrome拡張設定元: $extension_origin_source"$'\n'
  message+="Chrome拡張ID: $extension_id"
  printf '\nMimi Setupが完了しました。\n\n'
  alert "$message"
}

show_final_success
