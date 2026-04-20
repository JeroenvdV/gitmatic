#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${HOME}/.local/share/gitmatic"
TARGET_SCRIPT="${TARGET_DIR}/gitmatic.sh"
TARGET_PYTHON="${TARGET_DIR}/gitmatic.py"
TARGET_CONFIG="${TARGET_DIR}/gitmatic.toml"

mkdir -p "$TARGET_DIR"
cp "$PROJECT_ROOT/gitmatic.sh" "$TARGET_SCRIPT"
cp "$PROJECT_ROOT/gitmatic.py" "$TARGET_PYTHON"
chmod +x "$TARGET_SCRIPT" "$TARGET_PYTHON"

if [ ! -f "$TARGET_CONFIG" ]; then
    cp "$PROJECT_ROOT/gitmatic.toml.example" "$TARGET_CONFIG"
fi

cat <<EOF
Installed gitmatic files:
  Launcher: $TARGET_SCRIPT
  Python app: $TARGET_PYTHON
  Config: $TARGET_CONFIG

Next:
  1) Edit the TOML config file and add the folders or repos you want to manage:
       open -e "$TARGET_CONFIG"
  2) Run gitmatic once manually to confirm the config works:
       "$TARGET_SCRIPT" --config "$TARGET_CONFIG" --verbose
  3) Optional: install macOS launchd scheduling (runs every 15 minutes by default):
       "$PROJECT_ROOT/scripts/install-launchd.sh" --script "$TARGET_SCRIPT" --config "$TARGET_CONFIG"

Notes:
  - This script does not enable scheduling automatically.
  - Configure [ssh_agent] in the TOML file if you want gitmatic to keep a dedicated ssh-agent alive between runs.
  - The launchd helper uses this default log file unless you override it:
      $HOME/Library/Logs/gitmatic.log
EOF
