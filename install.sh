#!/usr/bin/env bash
set -euo pipefail

LABEL="net.memofun.claude-responses-adapter"
UPSTREAM_BASE_URL="${RESPONSES_UPSTREAM_BASE_URL:-https://ca.memofun.net}"
MODEL="${RESPONSES_DEFAULT_MODEL:-gpt-5.6-sol}"
PORT="${CLAUDE_RESPONSES_ADAPTER_PORT:-47827}"
API_KEY="${MEMOFUN_API_KEY:-}"
SERVICE_MODE="${RESPONSES_SERVICE_MODE:-auto}"
ACTIVE_SERVICE_MODE=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --api-key KEY       API key (otherwise prompted without echo)
  --model MODEL       Responses model (default: gpt-5.6-sol)
  --upstream URL      Upstream base URL (default: https://ca.memofun.net)
  --port PORT         Local adapter port (default: 47827)
  --service-mode MODE Linux service: auto, systemd, or nohup (default: auto)
  -h, --help          Show this help

Environment alternatives:
  MEMOFUN_API_KEY, RESPONSES_DEFAULT_MODEL,
  RESPONSES_UPSTREAM_BASE_URL, CLAUDE_RESPONSES_ADAPTER_PORT,
  RESPONSES_SERVICE_MODE
EOF
}

while (($#)); do
  case "$1" in
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --upstream)
      UPSTREAM_BASE_URL="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --service-mode)
      SERVICE_MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PLATFORM="${RESPONSES_INSTALL_PLATFORM:-$(uname -s)}"
case "$PLATFORM" in
  Darwin|Linux) ;;
  *)
    echo "Unsupported operating system: $PLATFORM (supported: macOS and Linux)." >&2
    exit 1
    ;;
esac
case "$SERVICE_MODE" in
  auto|systemd|nohup) ;;
  *)
    echo "Service mode must be one of: auto, systemd, nohup." >&2
    exit 1
    ;;
esac
if [[ "$PLATFORM" == "Darwin" && "$SERVICE_MODE" != "auto" ]]; then
  echo "--service-mode is only used on Linux; omit it on macOS." >&2
  exit 1
fi

NODE_BIN="$(command -v node || true)"
if [[ -z "$NODE_BIN" ]]; then
  if [[ "$PLATFORM" == "Darwin" ]]; then
    echo "Node.js 20+ is required. Install it first, for example: brew install node" >&2
  else
    echo "Node.js 20+ is required. Install it with your distribution package manager or NodeSource." >&2
  fi
  exit 1
fi
NODE_MAJOR="$($NODE_BIN -p 'Number(process.versions.node.split(".")[0])')"
if ((NODE_MAJOR < 20)); then
  echo "Node.js 20+ is required; found $($NODE_BIN --version)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ADAPTER_PATH="$CONFIG_DIR/responses-adapter.mjs"
SETTINGS_PATH="$CONFIG_DIR/settings.json"
BACKUP_SETTINGS_PATH="$CONFIG_DIR/settings_az.json"
LOG_DIR="$CONFIG_DIR/logs"

# Try to reuse credentials from the main settings.json, settings_mt.json, or settings_az.json.
if [[ -z "$API_KEY" ]]; then
  for _candidate in "$SETTINGS_PATH" "$CONFIG_DIR/settings_mt.json" "$BACKUP_SETTINGS_PATH"; do
    if [[ -f "$_candidate" ]]; then
      API_KEY="$(CLAUDE_SETTINGS_PATH="$_candidate" "$NODE_BIN" -e '
const fs = require("node:fs");
try {
  const settings = JSON.parse(fs.readFileSync(process.env.CLAUDE_SETTINGS_PATH, "utf8"));
  const baseUrl = settings?.env?.ANTHROPIC_BASE_URL || "";
  const token = settings?.env?.ANTHROPIC_AUTH_TOKEN || "";
  if (/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(baseUrl) && token) process.stdout.write(token);
} catch {}
')"
      if [[ -n "$API_KEY" ]]; then
        echo "Reusing the existing local-adapter credential from $_candidate."
        break
      fi
    fi
  done
fi

if [[ -z "$API_KEY" ]]; then
  if [[ ! -t 0 ]]; then
    echo "No API key supplied. Run interactively or set MEMOFUN_API_KEY." >&2
    exit 1
  fi
  printf 'API key: ' >&2
  IFS= read -r -s API_KEY
  printf '\n' >&2
fi

if [[ -z "$API_KEY" ]]; then
  echo "API key cannot be empty." >&2
  exit 1
fi
if [[ ! "$UPSTREAM_BASE_URL" =~ ^https:// ]]; then
  echo "Upstream URL must start with https://" >&2
  exit 1
fi
if [[ "$UPSTREAM_BASE_URL" == *$'\n'* || "$MODEL" == *$'\n'* ]]; then
  echo "Upstream URL and model must not contain newlines." >&2
  exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1024 || PORT > 65535)); then
  echo "Port must be an integer between 1024 and 65535." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR" "$LOG_DIR"
install -m 700 "$SCRIPT_DIR/responses-adapter.mjs" "$ADAPTER_PATH"

CLAUDE_SETTINGS_PATH="$SETTINGS_PATH" \
BACKUP_SETTINGS_PATH="$BACKUP_SETTINGS_PATH" \
ADAPTER_API_KEY="$API_KEY" \
ADAPTER_MODEL="$MODEL" \
ADAPTER_PORT="$PORT" \
"$NODE_BIN" -e '
const fs = require("node:fs");
const mainPath = process.env.CLAUDE_SETTINGS_PATH;
const backupPath = process.env.BACKUP_SETTINGS_PATH;

// Start from a copy of the main settings.json (if it exists) so that
// permissions, sandbox, and other user preferences are preserved.
let settings = {};
if (fs.existsSync(mainPath)) {
  try {
    settings = JSON.parse(fs.readFileSync(mainPath, "utf8"));
  } catch (error) {
    console.error(`Existing settings file is invalid JSON: ${error.message}`);
    process.exit(1);
  }
}

settings.env = {
  ...(settings.env || {}),
  ANTHROPIC_BASE_URL: `http://127.0.0.1:${process.env.ADAPTER_PORT}`,
  ANTHROPIC_AUTH_TOKEN: process.env.ADAPTER_API_KEY,
  ANTHROPIC_MODEL: process.env.ADAPTER_MODEL,
  ANTHROPIC_DEFAULT_OPUS_MODEL: process.env.ADAPTER_MODEL,
  ANTHROPIC_DEFAULT_SONNET_MODEL: process.env.ADAPTER_MODEL,
  ANTHROPIC_DEFAULT_HAIKU_MODEL: process.env.ADAPTER_MODEL,
  CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
  CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING: "1",
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  NO_PROXY: "127.0.0.1,localhost",
  no_proxy: "127.0.0.1,localhost",
};
for (const key of [
  "ANTHROPIC_API_KEY",
  "CLAUDE_CODE_USE_BEDROCK",
  "CLAUDE_CODE_USE_VERTEX",
  "CLAUDE_CODE_USE_FOUNDRY",
  "CLAUDE_CODE_USE_MANTLE",
]) delete settings.env[key];
settings.effortLevel = "max";
settings.model = process.env.ADAPTER_MODEL;

// Write to the backup file instead of overwriting the main settings.json
fs.writeFileSync(backupPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
fs.chmodSync(backupPath, 0o600);
'

install_macos_service() {
  local launch_agents_dir="$HOME/Library/LaunchAgents"
  local plist_path="$launch_agents_dir/$LABEL.plist"
  local domain="gui/$(id -u)"
  local bootstrapped=0

  mkdir -p "$launch_agents_dir"
  PLIST_PATH_VALUE="$plist_path" \
  NODE_BIN_VALUE="$NODE_BIN" \
  ADAPTER_PATH_VALUE="$ADAPTER_PATH" \
  LOG_DIR_VALUE="$LOG_DIR" \
  UPSTREAM_VALUE="${UPSTREAM_BASE_URL%/}" \
  MODEL_VALUE="$MODEL" \
  PORT_VALUE="$PORT" \
  LABEL_VALUE="$LABEL" \
  "$NODE_BIN" -e '
const fs = require("node:fs");
const escapeXml = (value) => String(value)
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll("\"", "&quot;")
  .replaceAll("\x27", "&apos;");
const e = escapeXml;
const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${e(process.env.LABEL_VALUE)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${e(process.env.NODE_BIN_VALUE)}</string>
    <string>${e(process.env.ADAPTER_PATH_VALUE)}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_RESPONSES_ADAPTER_HOST</key>
    <string>127.0.0.1</string>
    <key>CLAUDE_RESPONSES_ADAPTER_PORT</key>
    <string>${e(process.env.PORT_VALUE)}</string>
    <key>RESPONSES_UPSTREAM_BASE_URL</key>
    <string>${e(process.env.UPSTREAM_VALUE)}</string>
    <key>RESPONSES_DEFAULT_MODEL</key>
    <string>${e(process.env.MODEL_VALUE)}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${e(`${process.env.LOG_DIR_VALUE}/responses-adapter.log`)}</string>
  <key>StandardErrorPath</key>
  <string>${e(`${process.env.LOG_DIR_VALUE}/responses-adapter.error.log`)}</string>
</dict>
</plist>
`;
fs.writeFileSync(process.env.PLIST_PATH_VALUE, plist, { mode: 0o600 });
fs.chmodSync(process.env.PLIST_PATH_VALUE, 0o600);
'

  chmod 600 "$plist_path"
  plutil -lint "$plist_path" >/dev/null

  if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$domain/$LABEL"
    for _ in {1..20}; do
      if ! launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi

  for _ in {1..10}; do
    if launchctl bootstrap "$domain" "$plist_path" 2>/dev/null; then
      bootstrapped=1
      break
    fi
    sleep 0.25
  done
  if ((bootstrapped == 0)); then
    launchctl bootstrap "$domain" "$plist_path"
  fi
  launchctl kickstart -k "$domain/$LABEL"
}

install_linux_systemd_service() {
  local systemd_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  local service_name="$LABEL.service"
  local service_path="$systemd_config_dir/$service_name"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  mkdir -p "$systemd_config_dir"
  SERVICE_PATH_VALUE="$service_path" \
  NODE_BIN_VALUE="$NODE_BIN" \
  ADAPTER_PATH_VALUE="$ADAPTER_PATH" \
  UPSTREAM_VALUE="${UPSTREAM_BASE_URL%/}" \
  MODEL_VALUE="$MODEL" \
  PORT_VALUE="$PORT" \
  "$NODE_BIN" -e '
const fs = require("node:fs");
const quote = (value) => `"${String(value).replaceAll("\\", "\\\\").replaceAll("\"", "\\\"")}"`;
const env = (name, value) => `Environment=${quote(`${name}=${value}`)}`;
const unit = `[Unit]
Description=Claude Code Responses API adapter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${quote(process.env.NODE_BIN_VALUE)} ${quote(process.env.ADAPTER_PATH_VALUE)}
${env("CLAUDE_RESPONSES_ADAPTER_HOST", "127.0.0.1")}
${env("CLAUDE_RESPONSES_ADAPTER_PORT", process.env.PORT_VALUE)}
${env("RESPONSES_UPSTREAM_BASE_URL", process.env.UPSTREAM_VALUE)}
${env("RESPONSES_DEFAULT_MODEL", process.env.MODEL_VALUE)}
Restart=always
RestartSec=2
UMask=0077

[Install]
WantedBy=default.target
`;
fs.writeFileSync(process.env.SERVICE_PATH_VALUE, unit, { mode: 0o600 });
fs.chmodSync(process.env.SERVICE_PATH_VALUE, 0o600);
'

  chmod 600 "$service_path"
  systemctl --user daemon-reload >/dev/null 2>&1 || return 1
  systemctl --user enable "$service_name" >/dev/null 2>&1 || return 1
  systemctl --user restart "$service_name" >/dev/null 2>&1 || return 1
  ACTIVE_SERVICE_MODE="systemd"
}

start_linux_nohup_service() {
  local pid_path="$CONFIG_DIR/responses-adapter.pid"
  local stdout_path="$LOG_DIR/responses-adapter.log"
  local stderr_path="$LOG_DIR/responses-adapter.error.log"
  local old_pid=""
  local old_command=""
  local adapter_pid=""

  # Avoid a future port conflict if a user systemd service was previously active.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$LABEL.service" >/dev/null 2>&1 || true
  fi

  if [[ -f "$pid_path" ]]; then
    IFS= read -r old_pid < "$pid_path" || true
  fi
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    if [[ -r "/proc/$old_pid/cmdline" ]]; then
      old_command="$(tr '\0' ' ' < "/proc/$old_pid/cmdline")"
    else
      old_command="$(ps -p "$old_pid" -o command= 2>/dev/null || true)"
    fi
    if [[ "$old_command" == *"$ADAPTER_PATH"* ]]; then
      kill "$old_pid"
      for _ in {1..20}; do
        if ! kill -0 "$old_pid" 2>/dev/null; then
          break
        fi
        sleep 0.1
      done
      if kill -0 "$old_pid" 2>/dev/null; then
        echo "Existing adapter process $old_pid did not stop; refusing to start a duplicate." >&2
        return 1
      fi
    fi
  fi

  nohup env \
    CLAUDE_RESPONSES_ADAPTER_HOST=127.0.0.1 \
    CLAUDE_RESPONSES_ADAPTER_PORT="$PORT" \
    RESPONSES_UPSTREAM_BASE_URL="${UPSTREAM_BASE_URL%/}" \
    RESPONSES_DEFAULT_MODEL="$MODEL" \
    "$NODE_BIN" "$ADAPTER_PATH" \
    >>"$stdout_path" 2>>"$stderr_path" </dev/null &
  adapter_pid=$!
  printf '%s\n' "$adapter_pid" > "$pid_path"
  chmod 600 "$pid_path"
  sleep 0.5
  if ! kill -0 "$adapter_pid" 2>/dev/null; then
    echo "The unprivileged adapter process exited during startup." >&2
    tail -30 "$stderr_path" >&2 2>/dev/null || true
    return 1
  fi
  ACTIVE_SERVICE_MODE="nohup"
}

install_linux_service() {
  case "$SERVICE_MODE" in
    systemd)
      if ! install_linux_systemd_service; then
        echo "Unable to start the per-user systemd service." >&2
        echo "If an administrator permits lingering, they can run:" >&2
        echo "  sudo loginctl enable-linger $USER" >&2
        echo "Otherwise rerun without root using:" >&2
        echo "  ./install.sh --service-mode nohup" >&2
        exit 1
      fi
      ;;
    nohup)
      start_linux_nohup_service
      ;;
    auto)
      if ! install_linux_systemd_service; then
        echo "User systemd is unavailable; falling back to an unprivileged nohup process." >&2
        echo "This works without sudo, but the process may not survive logout or reboot." >&2
        start_linux_nohup_service
      fi
      ;;
  esac
}

node --check "$ADAPTER_PATH"

if [[ "$PLATFORM" == "Darwin" ]]; then
  install_macos_service
else
  install_linux_service
fi

HEALTH_URL="http://127.0.0.1:$PORT/health"
healthy=0
for _ in {1..20}; do
  if curl --noproxy '*' --silent --fail --max-time 2 "$HEALTH_URL" >/dev/null; then
    healthy=1
    break
  fi
  sleep 0.25
done

if ((healthy == 0)); then
  echo "Adapter failed its health check." >&2
  if [[ "$PLATFORM" == "Darwin" || "$ACTIVE_SERVICE_MODE" == "nohup" ]]; then
    echo "Error log:" >&2
    tail -30 "$LOG_DIR/responses-adapter.error.log" >&2 2>/dev/null || true
  else
    echo "Service log:" >&2
    journalctl --user -u "$LABEL.service" -n 30 --no-pager >&2 2>/dev/null || true
  fi
  exit 1
fi

unset API_KEY ADAPTER_API_KEY MEMOFUN_API_KEY
echo "Installed successfully."
echo "Platform: $PLATFORM"
echo "Adapter: $HEALTH_URL"
echo "Model:   $MODEL"
echo ""
echo "Settings written to: $BACKUP_SETTINGS_PATH"
echo "Your active settings.json was NOT modified."
echo ""
echo "Switch between configurations:"
echo "  cp ~/.claude/settings_mt.json ~/.claude/settings.json   # Meituan (sankuai)"
echo "  cp ~/.claude/settings_az.json ~/.claude/settings.json   # Responses adapter"
echo ""
echo "Test:    claude -p --max-turns 1 \"Reply with exactly OK.\""
if [[ "$PLATFORM" == "Darwin" ]]; then
  echo "Status:  launchctl print \"gui/$(id -u)/$LABEL\""
elif [[ "$ACTIVE_SERVICE_MODE" == "systemd" ]]; then
  echo "Service: systemd --user"
  echo "Status:  systemctl --user status $LABEL.service --no-pager"
else
  echo "Service: nohup fallback (no root required; may stop at logout/reboot)"
  echo "Status:  ps -p \"\$(cat $CONFIG_DIR/responses-adapter.pid)\" -o pid,etime,command"
  echo "Logs:    tail -50 $LOG_DIR/responses-adapter.error.log"
fi
