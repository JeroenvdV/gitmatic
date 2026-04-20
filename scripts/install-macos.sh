#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${HOME}/.local/share/gitmatic"
TARGET_SCRIPT="${TARGET_DIR}/gitmatic.sh"
TARGET_CONFIG="${TARGET_DIR}/gitmatic.ini"

mkdir -p "$TARGET_DIR"
cp "$PROJECT_ROOT/gitmatic.sh" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"

if [ ! -f "$TARGET_CONFIG" ]; then
    cp "$PROJECT_ROOT/gitmatic.ini.example" "$TARGET_CONFIG"
fi

cat <<EOF
Installed gitmatic files:
  Script: $TARGET_SCRIPT
  Config: $TARGET_CONFIG

Next:
  1) Edit the config file and add the folders or repos you want to manage:
       open -e "$TARGET_CONFIG"
  2) Run gitmatic once manually to confirm the config works:
       "$TARGET_SCRIPT" --config "$TARGET_CONFIG" --verbose
  3) Optional: install macOS launchd scheduling (runs every 15 minutes by default):
       "$PROJECT_ROOT/scripts/install-launchd.sh" --script "$TARGET_SCRIPT" --config "$TARGET_CONFIG"

Notes:
  - This script does not enable scheduling automatically.
  - The launchd helper uses this default log file unless you override it:
      $HOME/Library/Logs/gitmatic.log
EOF
