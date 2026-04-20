#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'EOF'
Usage: install-launchd.sh --script PATH --config PATH [--log-file PATH] [--interval-seconds 900]

Installs a launchd user agent to run gitmatic periodically on macOS.
EOF
    exit 0
fi

SCRIPT_PATH=""
CONFIG_PATH=""
LOG_PATH="${HOME}/Library/Logs/gitmatic.log"
INTERVAL_SECONDS="900"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --script)
            SCRIPT_PATH="$2"
            shift 2
            ;;
        --config)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --log-file)
            LOG_PATH="$2"
            shift 2
            ;;
        --interval-seconds)
            INTERVAL_SECONDS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$SCRIPT_PATH" ] || [ -z "$CONFIG_PATH" ]; then
    echo "Error: --script and --config are required." >&2
    exit 1
fi

SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")"
CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
LOG_PATH="$(mkdir -p "$(dirname "$LOG_PATH")" && cd "$(dirname "$LOG_PATH")" && pwd)/$(basename "$LOG_PATH")"

PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/io.gitmatic.runner.plist"

mkdir -p "$PLIST_DIR"
mkdir -p "$(dirname "$LOG_PATH")"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.gitmatic.runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_PATH}</string>
    <string>--config</string>
    <string>${CONFIG_PATH}</string>
    <string>--log-file</string>
    <string>${LOG_PATH}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl load "$PLIST_PATH"

cat <<EOF
Installed launchd agent:
  plist: $PLIST_PATH
  interval: ${INTERVAL_SECONDS}s
  log: $LOG_PATH

What this means:
  - gitmatic will run for your macOS user account at login and then every ${INTERVAL_SECONDS} seconds
  - both launchd output and gitmatic's --log-file output go to: $LOG_PATH

Check status with:
  launchctl list | grep io.gitmatic.runner

Remove it later with:
  "$SCRIPT_DIR/uninstall-launchd.sh"
EOF
