#!/usr/bin/env bash
set -euo pipefail

PLIST_PATH="${HOME}/Library/LaunchAgents/io.gitmatic.runner.plist"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
    rm -f "$PLIST_PATH"
    echo "Removed launchd agent: $PLIST_PATH"
else
    echo "No launchd agent found at: $PLIST_PATH"
fi
